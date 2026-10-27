use super::{Error, ImportPreview, Theme, builtin_themes, valid_import};
use crate::instance::DataDirectory;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs::{self, OpenOptions},
    io::Read,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

const FILE_NAME: &str = "themes.json";
const MAX_BYTES: usize = 16_777_216;
const MAX_THEMES: usize = 64;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Library {
    version: u32,
    themes: Vec<Theme>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct LoadedLibrary {
    pub themes: Vec<Theme>,
    pub error: Option<Error>,
    pub recovery_available: bool,
}
#[derive(Clone, Debug, PartialEq)]
pub enum CommitOutcome {
    /// Preferences::remove_theme_selection is called by UI only after Removed.
    Imported(Theme),
    Removed(String),
    Unchanged,
    Superseded,
}
enum Status {
    Unloaded,
    Ready(Vec<Theme>),
    Recoverable,
}
struct State {
    expected: Option<Vec<u8>>,
    status: Status,
}
struct Shared {
    owner: Arc<DataDirectory>,
    state: Mutex<State>,
    sequence: AtomicU64,
    #[cfg(test)]
    fail_replace: std::sync::atomic::AtomicBool,
}
#[derive(Clone)]
pub struct LibraryStore(Arc<Shared>);
enum Mutation {
    Import(ImportPreview),
    Remove(String),
    RecoverImport(ImportPreview),
}
/// Reserve synchronously before dispatch. Carries normalized values and same data owner only.
pub struct MutationRequest {
    store: LibraryStore,
    sequence: u64,
    mutation: Mutation,
}
impl LibraryStore {
    /// One store per Workspace, using ProfileStore::data_owner; clone for background workers.
    pub fn new(owner: Arc<DataDirectory>) -> Self {
        Self(Arc::new(Shared {
            owner,
            state: Mutex::new(State {
                expected: None,
                status: Status::Unloaded,
            }),
            sequence: AtomicU64::new(0),
            #[cfg(test)]
            fail_replace: std::sync::atomic::AtomicBool::new(false),
        }))
    }
    /// Reads only normalized imports. Original source files are never reopened.
    pub fn load(&self) -> Result<Vec<Theme>, Error> {
        let _owner = self.0.owner.mutation().map_err(|_| Error::LibraryRead)?;
        self.0.sequence.fetch_add(1, Ordering::SeqCst);
        let mut state = self.0.state.lock().map_err(|_| Error::LibraryRead)?;
        state.status = Status::Unloaded;
        state.expected = None;
        let original = read_bytes(&self.0.owner.file(FILE_NAME))?;
        state.expected = original;
        let imports = match state.expected.as_deref().map(decode).transpose() {
            Ok(imports) => imports.unwrap_or_default(),
            Err(error) => {
                state.status = Status::Recoverable;
                return Err(error);
            }
        };
        let mut all = builtin_themes()?;
        all.extend(imports.clone());
        state.status = Status::Ready(imports);
        Ok(all)
    }
    pub fn load_or_builtins(&self) -> Result<LoadedLibrary, Error> {
        match self.load() {
            Ok(themes) => Ok(LoadedLibrary {
                themes,
                error: None,
                recovery_available: false,
            }),
            Err(error) => Ok(LoadedLibrary {
                themes: builtin_themes()?,
                error: Some(error),
                recovery_available: self
                    .0
                    .state
                    .lock()
                    .map_err(|_| Error::LibraryRead)
                    .is_ok_and(|state| matches!(state.status, Status::Recoverable)),
            }),
        }
    }
    pub fn reserve_import(&self, preview: ImportPreview) -> MutationRequest {
        self.reserve(Mutation::Import(preview))
    }
    pub fn reserve_remove(&self, id: &str) -> MutationRequest {
        self.reserve(Mutation::Remove(id.into()))
    }
    /// Explicitly authorized recovery only: saves exact corrupt/future bytes first.
    /// Unreadable, oversized, symlink and reparse files cannot be replaced through recovery.
    pub fn reserve_recovery_import(&self, preview: ImportPreview) -> MutationRequest {
        self.reserve(Mutation::RecoverImport(preview))
    }
    fn reserve(&self, mutation: Mutation) -> MutationRequest {
        MutationRequest {
            store: self.clone(),
            sequence: self.0.sequence.fetch_add(1, Ordering::SeqCst) + 1,
            mutation,
        }
    }
}
impl MutationRequest {
    pub fn commit(self) -> Result<CommitOutcome, Error> {
        self.commit_with(|_| {})
    }
    pub(crate) fn commit_with(
        self,
        before_publish: impl FnOnce(&crate::files::PreparedSave),
    ) -> Result<CommitOutcome, Error> {
        let _owner = self
            .store
            .0
            .owner
            .mutation()
            .map_err(|_| Error::LibraryWrite)?;
        if !self.current() {
            return Ok(CommitOutcome::Superseded);
        }
        let mut state = self.store.0.state.lock().map_err(|_| Error::LibraryWrite)?;
        let recover = matches!(self.mutation, Mutation::RecoverImport(_));
        let mut themes = match (&state.status, recover) {
            (Status::Ready(themes), false) => themes.clone(),
            (Status::Recoverable, true) => Vec::new(),
            (Status::Recoverable, false) => return Err(Error::RecoveryRequired),
            _ => return Err(Error::LibraryRead),
        };
        let outcome = match &self.mutation {
            Mutation::Import(preview) | Mutation::RecoverImport(preview) => {
                if !valid_import(&preview.theme)
                    || themes.iter().any(|theme| theme.id == preview.theme.id)
                {
                    return Err(Error::InvalidIdentity);
                }
                if themes.len() >= MAX_THEMES {
                    return Err(Error::LibraryFull);
                }
                themes.push(preview.theme.clone());
                CommitOutcome::Imported(preview.theme.clone())
            }
            Mutation::Remove(id) => {
                if !super::imported_id(id) {
                    return Err(Error::InvalidIdentity);
                }
                let old_len = themes.len();
                themes.retain(|theme| theme.id != *id);
                if old_len == themes.len() {
                    CommitOutcome::Unchanged
                } else {
                    CommitOutcome::Removed(id.clone())
                }
            }
        };
        let path = self.store.0.owner.file(FILE_NAME);
        if read_bytes(&path)? != state.expected {
            return Err(Error::Conflict);
        }
        if outcome == CommitOutcome::Unchanged {
            return Ok(outcome);
        }
        let bytes = serde_json::to_vec_pretty(&Library {
            version: 1,
            themes: themes.clone(),
        })
        .map_err(|_| Error::LibraryWrite)?;
        if bytes.len() > MAX_BYTES {
            return Err(Error::LibraryWrite);
        }
        // Validate bytes using the same strict normalized import reader before staging.
        decode(&bytes).map_err(|_| Error::LibraryWrite)?;
        let capture =
            crate::files::CapturedDestination::capture(&path).map_err(publication_error)?;
        let source = std::str::from_utf8(&bytes).map_err(|_| Error::LibraryWrite)?;
        let prepared = crate::files::PreparedSave::prepare_captured(source.into(), &path, &capture)
            .map_err(publication_error)?;
        if recover {
            let original = state.expected.as_ref().ok_or(Error::LibraryRead)?;
            let backup = self
                .store
                .0
                .owner
                .file(&format!("themes-recovery-{}.json", uuid::Uuid::new_v4()));
            let capture =
                crate::files::CapturedDestination::capture(&backup).map_err(publication_error)?;
            // The raw-byte API refuses existing captures, including identical bytes.
            crate::files::PreparedSave::prepare_bytes_captured(
                Arc::from(original.as_slice()),
                &backup,
                &capture,
            )
            .map_err(publication_error)?
            .publish()
            .map_err(publication_error)?;
            // Keep a recovery copy even if a later replacement fails or is superseded.
            sync_directory(path.parent().ok_or(Error::LibraryWrite)?)
                .map_err(|_| Error::LibraryWrite)?;
        }
        if read_bytes(&path)? != state.expected {
            return Err(Error::Conflict);
        }
        if !self.current() {
            return Ok(CommitOutcome::Superseded);
        }
        before_publish(&prepared);
        if !self.current() {
            return Ok(CommitOutcome::Superseded);
        }
        #[cfg(test)]
        if self.store.0.fail_replace.load(Ordering::SeqCst) {
            return Err(Error::LibraryWrite);
        }
        if let Err(error) = prepared.publish() {
            #[cfg(windows)]
            if error == crate::files::FileError::Uncertain {
                state.status = Status::Unloaded;
            }
            return Err(publication_error(error));
        }
        state.expected = Some(bytes);
        state.status = Status::Ready(themes);
        if sync_directory(path.parent().ok_or(Error::LibraryWrite)?).is_err() {
            // Publication already occurred: do not describe the original as unchanged.
            state.status = Status::Unloaded;
            return Err(Error::PublishedUnverified);
        }
        Ok(outcome)
    }
    fn current(&self) -> bool {
        self.sequence == self.store.0.sequence.load(Ordering::SeqCst)
    }
}
fn publication_error(error: crate::files::FileError) -> Error {
    match error {
        crate::files::FileError::Changed => Error::Conflict,
        #[cfg(windows)]
        crate::files::FileError::Uncertain => Error::PublicationUnknown,
        _ => Error::LibraryWrite,
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
        options.custom_flags(0x00200000);
    }
    options
}
fn ordinary(metadata: &fs::Metadata) -> bool {
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return false;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return false;
        }
    }
    true
}
fn read_bytes(path: &Path) -> Result<Option<Vec<u8>>, Error> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Ok(metadata) if ordinary(&metadata) && metadata.len() <= MAX_BYTES as u64 => {}
        _ => return Err(Error::LibraryRead),
    }
    let file = options()
        .read(true)
        .open(path)
        .map_err(|_| Error::LibraryRead)?;
    let metadata = file.metadata().map_err(|_| Error::LibraryRead)?;
    if !ordinary(&metadata) || metadata.len() > MAX_BYTES as u64 {
        return Err(Error::LibraryRead);
    }
    let mut bytes = Vec::new();
    file.take(MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::LibraryRead)?;
    if bytes.len() > MAX_BYTES {
        return Err(Error::LibraryRead);
    }
    Ok(Some(bytes))
}
fn sync_directory(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        fs::File::open(path)?.sync_all()
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}
fn decode(bytes: &[u8]) -> Result<Vec<Theme>, Error> {
    // Reject duplicate keys throughout nested maps; serde's ordinary map reader
    // would otherwise silently replace a duplicate normalized color/metadata key.
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    let unique = Unique::deserialize(&mut deserializer).map_err(|_| Error::LibraryRead)?;
    deserializer.end().map_err(|_| Error::LibraryRead)?;
    let library: Library = serde_json::from_value(unique.0).map_err(|_| Error::LibraryRead)?;
    let mut ids = HashSet::new();
    if library.version != 1
        || library.themes.len() > MAX_THEMES
        || !library
            .themes
            .iter()
            .all(|theme| valid_import(theme) && ids.insert(theme.id.clone()))
    {
        return Err(Error::LibraryRead);
    }
    Ok(library.themes)
}
struct Unique(serde_json::Value);
impl<'de> Deserialize<'de> for Unique {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Visitor;
        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = Unique;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("unique normalized theme fields")
            }
            fn visit_map<M: serde::de::MapAccess<'de>>(
                self,
                mut access: M,
            ) -> Result<Unique, M::Error> {
                let mut map = serde_json::Map::new();
                while let Some((key, value)) = access.next_entry::<String, Unique>()? {
                    if map.insert(key, value.0).is_some() {
                        return Err(serde::de::Error::custom("duplicate field"));
                    }
                }
                Ok(Unique(serde_json::Value::Object(map)))
            }
            fn visit_seq<S: serde::de::SeqAccess<'de>>(
                self,
                mut access: S,
            ) -> Result<Unique, S::Error> {
                let mut values = Vec::new();
                while let Some(value) = access.next_element::<Unique>()? {
                    values.push(value.0);
                }
                Ok(Unique(serde_json::Value::Array(values)))
            }
            fn visit_str<E: serde::de::Error>(self, value: &str) -> Result<Unique, E> {
                Ok(Unique(value.into()))
            }
            fn visit_string<E: serde::de::Error>(self, value: String) -> Result<Unique, E> {
                Ok(Unique(value.into()))
            }
            fn visit_bool<E: serde::de::Error>(self, value: bool) -> Result<Unique, E> {
                Ok(Unique(value.into()))
            }
            fn visit_u64<E: serde::de::Error>(self, value: u64) -> Result<Unique, E> {
                Ok(Unique(value.into()))
            }
            fn visit_i64<E: serde::de::Error>(self, value: i64) -> Result<Unique, E> {
                Ok(Unique(value.into()))
            }
            fn visit_f64<E: serde::de::Error>(self, value: f64) -> Result<Unique, E> {
                Ok(Unique(
                    serde_json::Number::from_f64(value)
                        .map(serde_json::Value::Number)
                        .ok_or_else(|| E::custom("invalid channel"))?,
                ))
            }
            fn visit_unit<E: serde::de::Error>(self) -> Result<Unique, E> {
                Ok(Unique(serde_json::Value::Null))
            }
        }
        deserializer.deserialize_any(Visitor)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    struct Fixture {
        root: PathBuf,
        store: LibraryStore,
    }
    impl Fixture {
        fn new() -> Self {
            let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../build/gpui/task27-store-tests")
                .join(uuid::Uuid::new_v4().to_string());
            fs::create_dir_all(&root).unwrap();
            let root = fs::canonicalize(root).unwrap();
            Self {
                store: LibraryStore::new(DataDirectory::acquire(&root).unwrap()),
                root,
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
    fn preview() -> ImportPreview {
        ImportPreview {
            theme: super::super::parse_bytes(
                br##"{"colors":{"editor.background":"#12345678"}}"##,
                "Custom",
                &format!("imported-{}", uuid::Uuid::new_v4()),
            )
            .unwrap(),
        }
    }
    #[test]
    fn normalized_restart_removal_and_missing_source_are_independent() {
        let fixture = Fixture::new();
        assert_eq!(fixture.store.load().unwrap().len(), 8);
        let file = fixture.root.join("source.json");
        fs::write(&file, br##"{"colors":{"editor.background":"#fff8"},"tokenColors":[{"scope":"keyword","settings":{"fontStyle":""}}]}"##).unwrap();
        let imported = super::super::preview_import(&file).unwrap();
        let expected = imported.theme.clone();
        fixture.store.reserve_import(imported).commit().unwrap();
        fs::remove_file(file).unwrap();
        let restart = LibraryStore::new(fixture.store.0.owner.clone());
        assert_eq!(restart.load().unwrap().last(), Some(&expected));
        assert_eq!(
            restart.reserve_remove(&expected.id).commit(),
            Ok(CommitOutcome::Removed(expected.id.clone()))
        );
        assert_eq!(restart.load().unwrap().len(), 8);
        assert_eq!(
            restart.reserve_remove("native-light").commit(),
            Err(Error::InvalidIdentity)
        );
    }
    #[test]
    fn corrupt_future_duplicates_and_explicit_recovery_preserve_exact_bytes() {
        for bytes in [
            b"{broken\r\n".to_vec(),
            vec![0xff, 0, b'{', b'\r', b'\n'],
            br#"{"version":2,"themes":[]}"#.to_vec(),
            br#"{"version":1,"version":1,"themes":[]}"#.to_vec(),
            br#"{"version":1,"themes":[],"sessions":[]}"#.to_vec(),
        ] {
            let fixture = Fixture::new();
            fs::write(fixture.path(), &bytes).unwrap();
            let loaded = fixture.store.load_or_builtins().unwrap();
            assert!(loaded.recovery_available);
            assert_eq!(loaded.themes.len(), 8);
            assert_eq!(
                fixture.store.reserve_import(preview()).commit(),
                Err(Error::RecoveryRequired)
            );
            assert_eq!(fs::read(fixture.path()).unwrap(), bytes);
            fixture
                .store
                .reserve_recovery_import(preview())
                .commit()
                .unwrap();
            let backups: Vec<_> = fs::read_dir(&fixture.root)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .starts_with("themes-recovery-")
                })
                .collect();
            assert_eq!(backups.len(), 1);
            assert_eq!(fs::read(backups[0].path()).unwrap(), bytes);
            assert_eq!(fixture.store.load().unwrap().len(), 9);
        }
    }
    #[test]
    fn latest_reservation_reload_and_external_conflict_never_overwrite_newer_bytes() {
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        let old = fixture.store.reserve_import(preview());
        let new = fixture.store.reserve_import(preview());
        new.commit().unwrap();
        assert_eq!(old.commit(), Ok(CommitOutcome::Superseded));
        let stale = fixture.store.reserve_import(preview());
        fixture.store.load().unwrap();
        assert_eq!(stale.commit(), Ok(CommitOutcome::Superseded));
        let stale = fixture.store.reserve_import(preview());
        let external = br#"{"version":2,"themes":[]}"#;
        fs::write(fixture.path(), external).unwrap();
        assert_eq!(stale.commit(), Err(Error::Conflict));
        assert_eq!(fs::read(fixture.path()).unwrap(), external);
    }
    #[test]
    fn failed_replace_keeps_original_and_private_temporary_is_cleaned() {
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        fixture.store.reserve_import(preview()).commit().unwrap();
        let bytes = fs::read(fixture.path()).unwrap();
        fixture.store.0.fail_replace.store(true, Ordering::SeqCst);
        assert_eq!(
            fixture.store.reserve_import(preview()).commit(),
            Err(Error::LibraryWrite)
        );
        assert_eq!(fs::read(fixture.path()).unwrap(), bytes);
        assert!(
            !fs::read_dir(&fixture.root)
                .unwrap()
                .filter_map(Result::ok)
                .any(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
        );
        fixture.store.0.fail_replace.store(false, Ordering::SeqCst);
        fixture.store.reserve_import(preview()).commit().unwrap();
    }
    #[test]
    fn normalized_bounds_reserved_duplicate_and_invalid_channels_are_refused() {
        let theme = preview().theme;
        for id in [
            "system",
            "light",
            "dark",
            "native",
            "automatic",
            "native-light",
            "imported-not-a-uuid",
        ] {
            let mut invalid = theme.clone();
            invalid.id = id.into();
            assert!(
                decode(
                    &serde_json::to_vec(&Library {
                        version: 1,
                        themes: vec![invalid]
                    })
                    .unwrap()
                )
                .is_err()
            );
        }
        assert!(
            decode(
                &serde_json::to_vec(&Library {
                    version: 1,
                    themes: vec![theme.clone(), theme.clone()]
                })
                .unwrap()
            )
            .is_err()
        );
        let mut invalid = theme.clone();
        invalid.colors.get_mut("editor.background").unwrap().alpha = 2.;
        assert!(
            decode(
                &serde_json::to_vec(&Library {
                    version: 1,
                    themes: vec![invalid]
                })
                .unwrap()
            )
            .is_err()
        );
        let fixture = Fixture::new();
        fs::write(fixture.path(), vec![b' '; MAX_BYTES + 1]).unwrap();
        assert!(!fixture.store.load_or_builtins().unwrap().recovery_available);
        assert_eq!(
            fixture.store.reserve_recovery_import(preview()).commit(),
            Err(Error::LibraryRead)
        );
    }
    #[test]
    fn full_library_and_nested_duplicate_normalized_fields_are_refused() {
        let fixture = Fixture::new();
        let themes: Vec<_> = (0..64).map(|_| preview().theme).collect();
        fs::write(
            fixture.path(),
            serde_json::to_vec(&Library {
                version: 1,
                themes: themes.clone(),
            })
            .unwrap(),
        )
        .unwrap();
        assert_eq!(fixture.store.load().unwrap().len(), 72);
        assert_eq!(
            fixture.store.reserve_import(preview()).commit(),
            Err(Error::LibraryFull)
        );
        fixture
            .store
            .reserve_remove(&themes[0].id)
            .commit()
            .unwrap();
        fixture.store.reserve_import(preview()).commit().unwrap();
        assert_eq!(fixture.store.load().unwrap().len(), 72);
        let bytes = serde_json::to_string(&Library {
            version: 1,
            themes: vec![preview().theme],
        })
        .unwrap();
        let invalid = bytes.replace("\"red\":", "\"red\":0.5,\"red\":");
        assert!(decode(invalid.as_bytes()).is_err());
    }
    #[test]
    fn concurrent_requests_share_the_same_owner_and_last_reservation() {
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        let first = fixture.store.reserve_import(preview());
        let expected = preview();
        let id = expected.theme.id.clone();
        let latest = fixture.store.clone().reserve_import(expected);
        assert!(DataDirectory::acquire(&fixture.root).is_err());
        std::thread::scope(|scope| {
            let first = scope.spawn(|| first.commit());
            let latest = scope.spawn(|| latest.commit());
            assert_eq!(first.join().unwrap(), Ok(CommitOutcome::Superseded));
            assert!(matches!(
                latest.join().unwrap(),
                Ok(CommitOutcome::Imported(_))
            ));
        });
        assert_eq!(fixture.store.load().unwrap().last().unwrap().id, id);
    }
    #[test]
    fn actual_first_import_refuses_destination_appeared_after_final_expected_check() {
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        let imported = preview();
        let request = fixture.store.reserve_import(imported);
        let mut foreign_binding = None;
        let result = request.commit_with(|_| {
            fs::write(fixture.path(), b"foreign synthetic library\r\n").unwrap();
            foreign_binding = Some(crate::files::open(&fixture.path()).unwrap().binding);
        });
        assert_eq!(result, Err(Error::Conflict));
        assert_eq!(
            fs::read(fixture.path()).unwrap(),
            b"foreign synthetic library\r\n"
        );
        assert!(crate::files::open(&fixture.path()).unwrap().binding == foreign_binding.unwrap());
        let state = fixture.store.0.state.lock().unwrap();
        assert!(state.expected.is_none());
        assert!(matches!(&state.status, Status::Ready(themes) if themes.is_empty()));
    }
    #[test]
    fn actual_import_reservation_after_staging_supersedes_without_publication() {
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        let mut latest = None;
        assert_eq!(
            fixture.store.reserve_import(preview()).commit_with(|_| {
                latest = Some(fixture.store.reserve_import(preview()));
            }),
            Ok(CommitOutcome::Superseded)
        );
        assert!(!fixture.path().exists());
        assert!(fixture.store.0.state.lock().unwrap().expected.is_none());
        assert!(matches!(
            latest.unwrap().commit(),
            Ok(CommitOutcome::Imported(_))
        ));
        assert_eq!(fixture.store.load().unwrap().len(), 9);
    }
    #[test]
    fn actual_recovery_backup_failure_preserves_corrupt_original_and_foreign_stage() {
        use crate::files::test_support::{Stage, with_preparation_hook};
        let fixture = Fixture::new();
        let original = [0xff, 0, b'{', b'\r', b'\n'];
        fs::write(fixture.path(), original).unwrap();
        assert!(fixture.store.load_or_builtins().unwrap().recovery_available);
        let temporary = Arc::new(Mutex::new(PathBuf::new()));
        let output = temporary.clone();
        let moved = fixture.root.join("moved-owned-backup.bin");
        let result = with_preparation_hook(
            move |stage, target, path, _| {
                if stage == Stage::BeforeSync
                    && target
                        .file_name()
                        .unwrap()
                        .to_string_lossy()
                        .starts_with("themes-recovery-")
                {
                    *output.lock().unwrap() = path.to_owned();
                    fs::rename(path, &moved).unwrap();
                    fs::write(path, b"foreign failed backup stage").unwrap();
                    return Err(std::io::Error::other("synthetic recovery sync failure"));
                }
                Ok(())
            },
            || fixture.store.reserve_recovery_import(preview()).commit(),
        );
        assert_eq!(result, Err(Error::LibraryWrite));
        assert_eq!(fs::read(fixture.path()).unwrap(), original);
        assert_eq!(
            fs::read(&*temporary.lock().unwrap()).unwrap(),
            b"foreign failed backup stage"
        );
        let state = fixture.store.0.state.lock().unwrap();
        assert_eq!(state.expected.as_deref(), Some(original.as_slice()));
        assert!(matches!(state.status, Status::Recoverable));
    }
    #[test]
    fn actual_import_removal_and_recovery_refuse_foreign_or_modified_staging() {
        for mutation in ["import", "remove", "recover"] {
            for foreign in [false, true] {
                let fixture = Fixture::new();
                let request = if mutation == "recover" {
                    fs::write(fixture.path(), [0xff, 0, b'{', b'\r', b'\n']).unwrap();
                    assert!(fixture.store.load_or_builtins().unwrap().recovery_available);
                    fixture.store.reserve_recovery_import(preview())
                } else {
                    fixture.store.load().unwrap();
                    let first = preview();
                    let id = first.theme.id.clone();
                    fixture.store.reserve_import(first).commit().unwrap();
                    if mutation == "remove" {
                        fixture.store.reserve_remove(&id)
                    } else {
                        fixture.store.reserve_import(preview())
                    }
                };
                let original = fs::read(fixture.path()).unwrap();
                let mut staged = PathBuf::new();
                let moved = fixture.root.join("moved-owned-stage.bin");
                let result = request.commit_with(|prepared| {
                    staged = prepared.temporary_path().to_owned();
                    if foreign {
                        fs::rename(&staged, &moved).unwrap();
                    }
                    fs::write(&staged, b"foreign or modified synthetic staging").unwrap();
                });
                assert_eq!(result, Err(Error::Conflict));
                assert_eq!(fs::read(fixture.path()).unwrap(), original);
                let state = fixture.store.0.state.lock().unwrap();
                assert_eq!(state.expected.as_deref(), Some(original.as_slice()));
                if mutation == "recover" {
                    assert!(matches!(state.status, Status::Recoverable));
                    let backups: Vec<_> = fs::read_dir(&fixture.root)
                        .unwrap()
                        .filter_map(Result::ok)
                        .filter(|entry| {
                            entry
                                .file_name()
                                .to_string_lossy()
                                .starts_with("themes-recovery-")
                        })
                        .collect();
                    assert_eq!(backups.len(), 1);
                    assert_eq!(fs::read(backups[0].path()).unwrap(), original);
                } else {
                    assert!(matches!(&state.status, Status::Ready(themes) if themes.len() == 1));
                }
                drop(state);
                if foreign {
                    assert_eq!(
                        fs::read(&staged).unwrap(),
                        b"foreign or modified synthetic staging"
                    );
                    assert!(moved.exists());
                } else {
                    assert!(!staged.exists());
                }
                // A fresh explicit retry follows the same owner and persists normalized values.
                let retry = if mutation == "recover" {
                    fixture.store.reserve_recovery_import(preview())
                } else if mutation == "remove" {
                    let id = fixture.store.load().unwrap().last().unwrap().id.clone();
                    fixture.store.reserve_remove(&id)
                } else {
                    fixture.store.reserve_import(preview())
                };
                assert!(matches!(
                    retry.commit(),
                    Ok(CommitOutcome::Imported(_) | CommitOutcome::Removed(_))
                ));
                let expected = fixture.store.load().unwrap();
                let restart = LibraryStore::new(fixture.store.0.owner.clone());
                assert_eq!(restart.load().unwrap(), expected);
                if foreign {
                    assert_eq!(
                        fs::read(staged).unwrap(),
                        b"foreign or modified synthetic staging"
                    );
                }
            }
        }
    }
    #[test]
    fn actual_import_removal_and_recovery_refuse_changed_destination_after_staging() {
        for mutation in ["import", "remove", "recover"] {
            for replacement in [false, true] {
                let fixture = Fixture::new();
                let request = if mutation == "recover" {
                    fs::write(fixture.path(), b"{corrupt\r\n").unwrap();
                    fixture.store.load_or_builtins().unwrap();
                    fixture.store.reserve_recovery_import(preview())
                } else {
                    fixture.store.load().unwrap();
                    let imported = preview();
                    let id = imported.theme.id.clone();
                    fixture.store.reserve_import(imported).commit().unwrap();
                    if mutation == "remove" {
                        fixture.store.reserve_remove(&id)
                    } else {
                        fixture.store.reserve_import(preview())
                    }
                };
                let expected = fs::read(fixture.path()).unwrap();
                let mut foreign_binding = None;
                assert_eq!(
                    request.commit_with(|_| {
                        if replacement {
                            fs::rename(fixture.path(), fixture.root.join("original-library.bin"))
                                .unwrap();
                        }
                        fs::write(fixture.path(), b"foreign changed destination").unwrap();
                        foreign_binding =
                            Some(crate::files::open(&fixture.path()).unwrap().binding);
                    }),
                    Err(Error::Conflict)
                );
                assert_eq!(
                    fs::read(fixture.path()).unwrap(),
                    b"foreign changed destination"
                );
                assert!(
                    crate::files::open(&fixture.path()).unwrap().binding
                        == foreign_binding.unwrap()
                );
                assert_eq!(
                    fixture.store.0.state.lock().unwrap().expected.as_deref(),
                    Some(expected.as_slice())
                );
            }
        }
    }
    #[cfg(unix)]
    #[test]
    fn actual_first_import_refuses_replaced_captured_parent() {
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        let anchored = fixture.root.with_extension("retained-parent");
        let result = fixture.store.reserve_import(preview()).commit_with(|_| {
            fs::rename(&fixture.root, &anchored).unwrap();
            fs::create_dir(&fixture.root).unwrap();
            fs::write(fixture.path(), b"foreign parent library").unwrap();
        });
        assert_eq!(result, Err(Error::Conflict));
        assert_eq!(fs::read(fixture.path()).unwrap(), b"foreign parent library");
        assert!(!anchored.join(FILE_NAME).exists());
        assert!(
            !fs::read_dir(&anchored)
                .unwrap()
                .filter_map(Result::ok)
                .any(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
        );
        fs::remove_dir_all(anchored).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn private_modes_and_symlink_refusal_preserve_target() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        fixture.store.reserve_import(preview()).commit().unwrap();
        assert_eq!(
            fs::metadata(fixture.path()).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let target = fixture.root.join("preserved.json");
        fs::rename(fixture.path(), &target).unwrap();
        let original = fs::read(&target).unwrap();
        symlink(&target, fixture.path()).unwrap();
        assert!(fixture.store.load().is_err());
        assert_eq!(fs::read(target).unwrap(), original);
    }
    #[cfg(windows)]
    #[test]
    fn actual_import_removal_and_recovery_are_private_before_first_byte() {
        use crate::files::test_support::{Stage, windows, with_preparation_hook};
        use std::io::Write;
        let fixture = Fixture::new();
        windows::set_broad_inheritance(&fixture.root);
        let count = Arc::new(Mutex::new((0, 0)));
        let output = count.clone();
        with_preparation_hook(
            move |stage, target, _, file| {
                if stage != Stage::BeforeWrite {
                    return Ok(());
                }
                assert_eq!(file.metadata().unwrap().len(), 0);
                let descriptor = windows::descriptor(file);
                assert!(descriptor.starts_with("D:P(A;;FA;;;"));
                assert_eq!(descriptor.matches("(A;").count(), 1);
                assert!(!descriptor.contains(";;;WD)"));
                let mut count = output.lock().unwrap();
                if target.file_name().unwrap() == FILE_NAME {
                    count.0 += 1;
                } else {
                    assert!(
                        target
                            .file_name()
                            .unwrap()
                            .to_string_lossy()
                            .starts_with("themes-recovery-")
                    );
                    count.1 += 1;
                }
                Ok(())
            },
            || {
                fixture.store.load().unwrap();
                let imported = preview();
                let id = imported.theme.id.clone();
                fixture.store.reserve_import(imported).commit().unwrap();
                fixture.store.reserve_remove(&id).commit().unwrap();
                fs::remove_file(fixture.path()).unwrap();
                let original = [0xff, 0, b'{', b'\r', b'\n'];
                windows::create_private(&fixture.path())
                    .unwrap()
                    .write_all(&original)
                    .unwrap();
                assert!(fixture.store.load_or_builtins().unwrap().recovery_available);
                fixture
                    .store
                    .reserve_recovery_import(preview())
                    .commit()
                    .unwrap();
                let backup = fs::read_dir(&fixture.root)
                    .unwrap()
                    .filter_map(Result::ok)
                    .find(|entry| {
                        entry
                            .file_name()
                            .to_string_lossy()
                            .starts_with("themes-recovery-")
                    })
                    .unwrap();
                assert_eq!(fs::read(backup.path()).unwrap(), original);
                assert!(
                    windows::descriptor(&fs::File::open(backup.path()).unwrap())
                        .starts_with("D:P(A;;FA;;;")
                );
            },
        );
        assert_eq!(*count.lock().unwrap(), (3, 1));
    }
    #[cfg(windows)]
    #[test]
    fn unknown_publication_error_requires_inspection_without_claiming_no_write() {
        assert_eq!(
            publication_error(crate::files::FileError::Uncertain),
            Error::PublicationUnknown
        );
        let message = Error::PublicationUnknown.to_string();
        assert!(message.contains("inspect") && message.contains("reload"));
    }
    #[cfg(windows)]
    #[test]
    fn sharing_denial_does_not_delete_original() {
        use std::os::windows::fs::OpenOptionsExt;
        let fixture = Fixture::new();
        fixture.store.load().unwrap();
        fixture.store.reserve_import(preview()).commit().unwrap();
        let bytes = fs::read(fixture.path()).unwrap();
        let lock = OpenOptions::new()
            .read(true)
            .share_mode(1)
            .open(fixture.path())
            .unwrap();
        assert_eq!(
            fixture.store.reserve_import(preview()).commit(),
            Err(Error::LibraryWrite)
        );
        assert_eq!(fs::read(fixture.path()).unwrap(), bytes);
        drop(lock);
    }
}
