use super::{Preferences, VERSION};
use crate::instance::DataDirectory;
use std::{
    fs::{self, OpenOptions},
    io::Read,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

const FILE_NAME: &str = "appearance.json";
const MAX_BYTES: u64 = 65_536;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StoreError {
    Read,
    Write,
    Conflict,
    #[cfg(windows)]
    PublicationUnknown,
}
impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            #[cfg(windows)]
            Self::PublicationUnknown => "Appearance settings publication could not be verified. Keep this window open and inspect the saved file before retrying.",
            Self::Read => "Appearance settings could not be loaded. Colors use an in-memory fallback; the existing file has been left unchanged.",
            Self::Write => "Appearance settings could not be saved. The preview remains active; retry saving before closing.",
            Self::Conflict => "Appearance settings changed outside this window. The existing file has been left unchanged; reload before saving.",
        })
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LoadedPreferences {
    pub preferences: Preferences,
    pub error: Option<StoreError>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SaveOutcome {
    Published,
    Superseded,
}
struct State {
    expected: Option<Vec<u8>>,
    loaded: bool,
}
struct Shared {
    owner: Arc<DataDirectory>,
    state: Mutex<State>,
    sequence: AtomicU64,
    #[cfg(test)]
    fail_replace: std::sync::atomic::AtomicBool,
}
#[derive(Clone)]
pub struct AppearanceStore(Arc<Shared>);
pub struct SaveRequest {
    store: AppearanceStore,
    sequence: u64,
    preferences: Preferences,
}
impl AppearanceStore {
    /// Keep exactly one store per Workspace; clones retain the data owner and
    /// share ordering/state. This never acquires a competing directory owner.
    pub fn new(owner: Arc<DataDirectory>) -> Self {
        Self(Arc::new(Shared {
            owner,
            state: Mutex::new(State {
                expected: None,
                loaded: false,
            }),
            sequence: AtomicU64::new(0),
            #[cfg(test)]
            fail_replace: std::sync::atomic::AtomicBool::new(false),
        }))
    }
    pub fn load(&self) -> Result<Preferences, StoreError> {
        let _owner = self.0.owner.mutation().map_err(|_| StoreError::Read)?;
        // An explicit reload also invalidates queued previews captured before
        // recovery; they cannot replace freshly loaded/repaired preferences.
        self.0.sequence.fetch_add(1, Ordering::SeqCst);
        let mut state = self.0.state.lock().map_err(|_| StoreError::Read)?;
        state.loaded = false;
        let original = read_bytes(&self.0.owner.file(FILE_NAME))?;
        let preferences = original
            .as_deref()
            .map(decode)
            .transpose()?
            .unwrap_or_default();
        state.expected = original;
        state.loaded = true;
        Ok(preferences)
    }
    /// Failure returns a usable in-memory default, but never makes it writable.
    /// A successful explicit load after external repair is needed to save again.
    pub fn load_or_default(&self) -> LoadedPreferences {
        match self.load() {
            Ok(preferences) => LoadedPreferences {
                preferences,
                error: None,
            },
            Err(error) => LoadedPreferences {
                preferences: Preferences::default(),
                error: Some(error),
            },
        }
    }
    /// Reserve synchronously at the setting change before spawning/debouncing.
    /// Reserve the latest full *appearance-only* DTO, never a SQL snapshot.
    pub fn reserve(&self, preferences: Preferences) -> SaveRequest {
        SaveRequest {
            store: self.clone(),
            sequence: self.0.sequence.fetch_add(1, Ordering::SeqCst) + 1,
            preferences,
        }
    }
    #[cfg(test)]
    pub(crate) fn fail_replacement(&self, fail: bool) {
        self.0.fail_replace.store(fail, Ordering::SeqCst);
    }
}
impl SaveRequest {
    /// Retains the same DataDirectory owner through publication and cleanup.
    pub fn commit(self) -> Result<SaveOutcome, StoreError> {
        self.commit_with(|_| {})
    }
    fn commit_with(
        self,
        before_publish: impl FnOnce(&crate::files::PreparedSave),
    ) -> Result<SaveOutcome, StoreError> {
        let _owner = self
            .store
            .0
            .owner
            .mutation()
            .map_err(|_| StoreError::Write)?;
        if self.sequence != self.store.0.sequence.load(Ordering::SeqCst) {
            return Ok(SaveOutcome::Superseded);
        }
        let mut state = self.store.0.state.lock().map_err(|_| StoreError::Write)?;
        if !state.loaded {
            return Err(StoreError::Read);
        }
        self.preferences.validate().map_err(|_| StoreError::Write)?;
        let path = self.store.0.owner.file(FILE_NAME);
        if read_bytes(&path)? != state.expected {
            return Err(StoreError::Conflict);
        }
        let bytes = serde_json::to_vec_pretty(&self.preferences).map_err(|_| StoreError::Write)?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err(StoreError::Write);
        }
        let capture =
            crate::files::CapturedDestination::capture(&path).map_err(|_| StoreError::Write)?;
        let source = std::str::from_utf8(&bytes).map_err(|_| StoreError::Write)?;
        let prepared = crate::files::PreparedSave::prepare_captured(source.into(), &path, &capture)
            .map_err(|_| StoreError::Write)?;
        before_publish(&prepared);
        // Recheck both external source and reserved order immediately before
        // atomic replacement. No destination deletion fallback on Windows.
        if read_bytes(&path)? != state.expected {
            return Err(StoreError::Conflict);
        }
        if self.sequence != self.store.0.sequence.load(Ordering::SeqCst) {
            return Ok(SaveOutcome::Superseded);
        }
        #[cfg(test)]
        if self.store.0.fail_replace.load(Ordering::SeqCst) {
            return Err(StoreError::Write);
        }
        prepared.publish().map_err(|error| {
            #[cfg(windows)]
            if error == crate::files::FileError::Uncertain {
                return StoreError::PublicationUnknown;
            }
            let _ = error;
            StoreError::Write
        })?;
        state.expected = Some(bytes);
        sync_directory(path.parent().ok_or(StoreError::Write)?)?;
        Ok(SaveOutcome::Published)
    }
}
fn options() -> OpenOptions {
    #[allow(unused_mut)]
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    options
}
fn read_bytes(path: &Path) -> Result<Option<Vec<u8>>, StoreError> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Ok(metadata) if metadata.is_file() => {}
        _ => return Err(StoreError::Read),
    }
    let file = options()
        .read(true)
        .open(path)
        .map_err(|_| StoreError::Read)?;
    let metadata = file.metadata().map_err(|_| StoreError::Read)?;
    if !metadata.is_file() || metadata.len() > MAX_BYTES {
        return Err(StoreError::Read);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(StoreError::Read);
        }
    }
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| StoreError::Read)?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err(StoreError::Read);
    }
    Ok(Some(bytes))
}
fn sync_directory(path: &Path) -> Result<(), StoreError> {
    #[cfg(unix)]
    fs::File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|_| StoreError::Write)?;
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}
fn decode(bytes: &[u8]) -> Result<Preferences, StoreError> {
    let preferences: Preferences = serde_json::from_slice(bytes).map_err(|_| StoreError::Read)?;
    if preferences.version != VERSION {
        return Err(StoreError::Read);
    }
    preferences.validate()?;
    Ok(preferences)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    struct Fixture {
        root: PathBuf,
        store: AppearanceStore,
    }
    impl Fixture {
        fn new() -> Self {
            let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../build/gpui/appearance-tests")
                .join(uuid::Uuid::new_v4().to_string());
            let owner = DataDirectory::acquire(&root).unwrap();
            Self {
                root,
                store: AppearanceStore::new(owner),
            }
        }
        fn path(&self) -> PathBuf {
            self.root.join(FILE_NAME)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            _ = fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn absent_and_restart_preserve_independent_choices_and_unknown_ids() {
        let fixture = Fixture::new();
        assert_eq!(fixture.store.load().unwrap(), Preferences::default());
        let preferences: Preferences =
            serde_json::from_str(include_str!("../../fixtures/appearance/preferences.json"))
                .unwrap();
        fixture.store.reserve(preferences.clone()).commit().unwrap();
        let restart = AppearanceStore::new(fixture.store.0.owner.clone());
        assert_eq!(restart.load().unwrap(), preferences);
        assert_eq!(
            fs::read_dir(&fixture.root)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
                .count(),
            0
        );
    }
    #[test]
    fn corrupt_future_unknown_duplicate_and_oversize_files_are_preserved_and_not_saved() {
        for bytes in [
            b"{corrupt".to_vec(),
            br#"{"version":2,"appearanceTheme":"system","applicationColorTheme":"native","editorColorTheme":"automatic"}"#.to_vec(),
            br#"{"version":1,"appearanceTheme":"system","applicationColorTheme":"native","editorColorTheme":"automatic","sessions":[]}"#.to_vec(),
            br#"{"version":1,"version":1,"appearanceTheme":"system","applicationColorTheme":"native","editorColorTheme":"automatic"}"#.to_vec(),
            vec![b' '; MAX_BYTES as usize + 1],
        ] {
            let fixture = Fixture::new();
            fs::write(fixture.path(), &bytes).unwrap();
            let loaded = fixture.store.load_or_default();
            assert_eq!(loaded.preferences, Preferences::default());
            assert_eq!(loaded.error, Some(StoreError::Read));
            assert_eq!(fixture.store.reserve(loaded.preferences).commit(), Err(StoreError::Read));
            assert_eq!(fs::read(fixture.path()).unwrap(), bytes);
        }
    }
    #[test]
    fn external_conflict_failed_replace_and_retry_keep_original_bytes() {
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        fixture
            .store
            .reserve(Preferences::default())
            .commit()
            .unwrap();
        let original = fs::read(fixture.path()).unwrap();
        let next = Preferences {
            editor_color_theme: "native-dark".into(),
            ..Preferences::default()
        };
        fixture.store.fail_replacement(true);
        assert_eq!(
            fixture.store.reserve(next.clone()).commit(),
            Err(StoreError::Write)
        );
        assert_eq!(fs::read(fixture.path()).unwrap(), original);
        fixture.store.fail_replacement(false);
        fixture.store.reserve(next.clone()).commit().unwrap();
        let request = fixture.store.reserve(Preferences::default());
        fs::write(fixture.path(), b"external recovery bytes").unwrap();
        assert_eq!(request.commit(), Err(StoreError::Conflict));
        assert_eq!(
            fs::read(fixture.path()).unwrap(),
            b"external recovery bytes"
        );
        assert!(fixture.store.load().is_err());
        fs::write(fixture.path(), serde_json::to_vec(&next).unwrap()).unwrap();
        assert_eq!(fixture.store.load().unwrap(), next);
        fixture.store.reserve(next).commit().unwrap();
    }
    #[test]
    fn queued_old_choices_cannot_overwrite_latest_or_an_unrelated_file() {
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        let sql_snapshot = b"unrelated source-only workspace bytes";
        fs::write(fixture.root.join("workspace.json"), sql_snapshot).unwrap();
        let old = fixture.store.reserve(Preferences::default());
        let latest = Preferences {
            appearance_theme: "dark".into(),
            editor_color_theme: "native-light".into(),
            ..Preferences::default()
        };
        let new = fixture.store.clone().reserve(latest.clone());
        assert_eq!(new.commit(), Ok(SaveOutcome::Published));
        assert_eq!(old.commit(), Ok(SaveOutcome::Superseded));
        assert_eq!(fixture.store.load().unwrap(), latest);
        assert_eq!(
            fs::read(fixture.root.join("workspace.json")).unwrap(),
            sql_snapshot
        );
    }
    #[test]
    fn explicit_reload_invalidates_queued_pre_recovery_choices() {
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        let old = fixture.store.reserve(Preferences::default());
        let external = Preferences {
            appearance_theme: "dark".into(),
            ..Preferences::default()
        };
        fs::write(fixture.path(), serde_json::to_vec(&external).unwrap()).unwrap();
        assert_eq!(fixture.store.load().unwrap(), external);
        assert_eq!(old.commit(), Ok(SaveOutcome::Superseded));
        assert_eq!(fixture.store.load().unwrap(), external);
    }
    #[test]
    fn concurrently_committed_reservations_publish_latest_and_retain_owner() {
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        let latest = Preferences {
            application_color_theme: "named-future".into(),
            ..Preferences::default()
        };
        let old = fixture.store.reserve(Preferences::default());
        let new = fixture.store.reserve(latest.clone());
        std::thread::scope(|scope| {
            let first = scope.spawn(|| old.commit());
            let second = scope.spawn(|| new.commit());
            assert_eq!(first.join().unwrap(), Ok(SaveOutcome::Superseded));
            assert_eq!(second.join().unwrap(), Ok(SaveOutcome::Published));
        });
        assert_eq!(fixture.store.load().unwrap(), latest);
        let request = fixture.store.reserve(latest);
        assert!(DataDirectory::acquire(&fixture.root).is_err());
        request.commit().unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn private_files_and_symlink_refusal_preserve_target() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        fixture
            .store
            .reserve(Preferences::default())
            .commit()
            .unwrap();
        assert_eq!(
            fs::metadata(fixture.path()).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(&fixture.root).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let original = fs::read(fixture.path()).unwrap();
        let target = fixture.root.join("preserved.json");
        fs::rename(fixture.path(), &target).unwrap();
        symlink(&target, fixture.path()).unwrap();
        assert!(fixture.store.load().is_err());
        assert_eq!(fs::read(target).unwrap(), original);
    }
    #[cfg(windows)]
    #[test]
    fn locked_destination_is_not_deleted_to_force_replacement() {
        use std::os::windows::fs::OpenOptionsExt;
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        fixture
            .store
            .reserve(Preferences::default())
            .commit()
            .unwrap();
        let original = fs::read(fixture.path()).unwrap();
        let locked = OpenOptions::new()
            .read(true)
            .share_mode(1)
            .open(fixture.path())
            .unwrap();
        let next = Preferences {
            appearance_theme: "dark".into(),
            ..Preferences::default()
        };
        assert_eq!(
            fixture.store.reserve(next.clone()).commit(),
            Err(StoreError::Write)
        );
        assert_eq!(fs::read(fixture.path()).unwrap(), original);
        drop(locked);
        fixture.store.reserve(next).commit().unwrap();
    }
    #[test]
    fn appearance_refuses_to_publish_or_delete_a_foreign_temporary() {
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        fixture
            .store
            .reserve(Preferences::default())
            .commit()
            .unwrap();
        let original = fs::read(fixture.path()).unwrap();
        let foreign = std::cell::RefCell::new(None);
        let result = fixture
            .store
            .reserve(Preferences::default())
            .commit_with(|prepared| {
                let temporary = prepared.temporary_path().to_owned();
                fs::rename(&temporary, fixture.root.join("detached-owned.tmp")).unwrap();
                fs::write(&temporary, b"foreign synthetic file").unwrap();
                *foreign.borrow_mut() = Some(temporary);
            });
        assert_eq!(result, Err(StoreError::Write));
        assert_eq!(fs::read(fixture.path()).unwrap(), original);
        assert_eq!(
            fs::read(foreign.into_inner().unwrap()).unwrap(),
            b"foreign synthetic file"
        );
    }
}
