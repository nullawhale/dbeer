use super::{NativePlatform, Preferences, VERSION};
use crate::instance::DataDirectory;
use std::{
    fs::{self, File, OpenOptions},
    io::Read,
    path::Path,
    sync::{Arc, Mutex},
};

const FILE_NAME: &str = "shortcuts.json";
const MAX_BYTES: u64 = 16_384;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StoreError {
    Read,
    InvalidBindings,
    Write,
    Conflict,
    #[cfg(windows)]
    PublicationUnknown,
    Unavailable,
}
impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Read => "Shortcut preferences could not be loaded. Defaults are active; the existing file is preserved. Repair and reload or explicitly recover preferences before saving.",
            Self::InvalidBindings => "Stored shortcuts are invalid or conflict with reserved commands. Defaults are active; the existing file is preserved. Repair and reload or explicitly recover preferences before saving.",
            Self::Write => "Shortcut preferences could not be saved. Retry saving before closing.",
            Self::Conflict => "Shortcut preferences changed outside this window. Reload before saving; the existing file is preserved.",
            #[cfg(windows)]
            Self::PublicationUnknown => "Shortcut preference publication could not be verified. Keep this window open and inspect the saved file before retrying.",
            Self::Unavailable => "Shortcut preference storage is unavailable.",
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
    writable: bool,
    sequence: u64,
    published: u64,
}
struct Shared {
    owner: Arc<DataDirectory>,
    state: Mutex<State>,
    #[cfg(test)]
    fail_replace: std::sync::atomic::AtomicBool,
}
#[derive(Clone)]
pub struct ShortcutStore(Arc<Shared>);
pub struct SaveRequest {
    store: ShortcutStore,
    sequence: u64,
    preferences: Preferences,
    platform: NativePlatform,
}
impl ShortcutStore {
    /// One store per Workspace; clones share reservations and retain its owner.
    /// Reuse profiles/restoration's Arc; never acquire a second directory owner.
    pub fn new(owner: Arc<DataDirectory>) -> Self {
        Self(Arc::new(Shared {
            owner,
            state: Mutex::new(State {
                expected: None,
                writable: false,
                sequence: 0,
                published: 0,
            }),
            #[cfg(test)]
            fail_replace: std::sync::atomic::AtomicBool::new(false),
        }))
    }
    pub fn load(&self, platform: NativePlatform) -> Result<Preferences, StoreError> {
        let _owner = self
            .0
            .owner
            .mutation()
            .map_err(|_| StoreError::Unavailable)?;
        let mut state = self.0.state.lock().map_err(|_| StoreError::Unavailable)?;
        advance(&mut state)?;
        state.writable = false;
        let bytes = read_bytes(&self.0.owner.file(FILE_NAME))?;
        let preferences = bytes
            .as_deref()
            .map(|bytes| decode(bytes, platform))
            .transpose()?
            .unwrap_or_default();
        state.expected = bytes;
        state.writable = true;
        state.published = state.sequence;
        Ok(preferences)
    }
    /// Failure gives a truthful usable fallback, with publication still blocked.
    pub fn load_or_default(&self, platform: NativePlatform) -> LoadedPreferences {
        match self.load(platform) {
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
    /// Reserve synchronously at each accepted UI edit before spawning/debouncing.
    /// The lock orders reservations and publication; an older request cannot
    /// publish after a later reservation. Requests never contain SQL snapshots.
    pub fn reserve(
        &self,
        preferences: Preferences,
        platform: NativePlatform,
    ) -> Result<SaveRequest, StoreError> {
        preferences
            .validated_bindings(platform)
            .map_err(|_| StoreError::InvalidBindings)?;
        let mut state = self.0.state.lock().map_err(|_| StoreError::Unavailable)?;
        if !state.writable {
            return Err(StoreError::Read);
        }
        let sequence = advance(&mut state)?;
        Ok(SaveRequest {
            store: self.clone(),
            sequence,
            preferences,
            platform,
        })
    }
    /// False also covers failed load/save and a latest request still in flight.
    pub fn latest_saved(&self) -> bool {
        self.0
            .state
            .lock()
            .is_ok_and(|state| state.writable && state.sequence == state.published)
    }
    #[cfg(test)]
    pub(super) fn published_revision(&self) -> u64 {
        self.0.state.lock().unwrap().published
    }
    #[cfg(test)]
    pub(super) fn owner(&self) -> Arc<DataDirectory> {
        self.0.owner.clone()
    }
    #[cfg(test)]
    pub(super) fn fail_replacement(&self, fail: bool) {
        self.0
            .fail_replace
            .store(fail, std::sync::atomic::Ordering::SeqCst);
    }
    /// Normal-close hook: freeze Settings mutations first, capture the latest
    /// preference value, await this commit, and only close on Published or after
    /// an explicit user decision. Never call this with an old startup snapshot.
    #[cfg(test)]
    pub fn flush_latest(
        &self,
        preferences: Preferences,
        platform: NativePlatform,
    ) -> Result<SaveOutcome, StoreError> {
        self.reserve(preferences, platform)?.commit()
    }
    /// Explicit user recovery only: preserve exact bounded bytes privately in a
    /// nonoverwriting backup before atomic reset. Oversize/unreadable/unsafe files
    /// require external repair; they cannot be erased by this recovery action.
    pub fn recover_defaults(&self, platform: NativePlatform) -> Result<SaveOutcome, StoreError> {
        self.recover_defaults_with(platform, |_| {})
    }
    pub(super) fn recover_defaults_with(
        &self,
        platform: NativePlatform,
        before_publish: impl FnOnce(&crate::files::PreparedSave),
    ) -> Result<SaveOutcome, StoreError> {
        self.recover_defaults_using(platform, uuid::Uuid::new_v4, before_publish)
    }
    pub(super) fn recover_defaults_using(
        &self,
        platform: NativePlatform,
        mut backup_id: impl FnMut() -> uuid::Uuid,
        before_publish: impl FnOnce(&crate::files::PreparedSave),
    ) -> Result<SaveOutcome, StoreError> {
        let _owner = self
            .0
            .owner
            .mutation()
            .map_err(|_| StoreError::Unavailable)?;
        let mut state = self.0.state.lock().map_err(|_| StoreError::Unavailable)?;
        advance(&mut state)?;
        state.writable = false;
        let path = self.0.owner.file(FILE_NAME);
        let original = read_bytes(&path)?;
        if let Some(bytes) = original.as_ref() {
            loop {
                let backup = self
                    .0
                    .owner
                    .file(&format!("shortcuts-recovery-{}.json", backup_id()));
                match fs::symlink_metadata(&backup) {
                    Ok(_) => continue,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(_) => return Err(StoreError::Write),
                }
                let capture = crate::files::CapturedDestination::capture(&backup)
                    .map_err(|_| StoreError::Write)?;
                crate::files::PreparedSave::prepare_bytes_captured(
                    Arc::from(bytes.as_slice()),
                    &backup,
                    &capture,
                )
                .map_err(|_| StoreError::Write)?
                .publish()
                .map_err(|error| {
                    #[cfg(windows)]
                    if error == crate::files::FileError::Uncertain {
                        return StoreError::PublicationUnknown;
                    }
                    let _ = error;
                    StoreError::Write
                })?;
                sync_directory(backup.parent().ok_or(StoreError::Write)?)?;
                break;
            }
        }
        let preferences = Preferences::default();
        preferences
            .validated_bindings(platform)
            .map_err(|_| StoreError::InvalidBindings)?;
        let bytes = serde_json::to_vec_pretty(&preferences).map_err(|_| StoreError::Write)?;
        publish(&self.0, &path, &original, &bytes, before_publish)?;
        state.expected = Some(bytes);
        state.writable = true;
        state.published = state.sequence;
        Ok(SaveOutcome::Published)
    }
}
fn advance(state: &mut State) -> Result<u64, StoreError> {
    state.sequence = state
        .sequence
        .checked_add(1)
        .ok_or(StoreError::Unavailable)?;
    Ok(state.sequence)
}
impl SaveRequest {
    pub fn revision(&self) -> u64 {
        self.sequence
    }
    pub fn commit(self) -> Result<SaveOutcome, StoreError> {
        self.commit_with(|_| {})
    }
    pub(crate) fn commit_with(
        self,
        before_publish: impl FnOnce(&crate::files::PreparedSave),
    ) -> Result<SaveOutcome, StoreError> {
        let _owner = self
            .store
            .0
            .owner
            .mutation()
            .map_err(|_| StoreError::Unavailable)?;
        let mut state = self
            .store
            .0
            .state
            .lock()
            .map_err(|_| StoreError::Unavailable)?;
        if self.sequence != state.sequence {
            return Ok(SaveOutcome::Superseded);
        }
        if !state.writable {
            return Err(StoreError::Read);
        }
        self.preferences
            .validated_bindings(self.platform)
            .map_err(|_| StoreError::InvalidBindings)?;
        let bytes = serde_json::to_vec_pretty(&self.preferences).map_err(|_| StoreError::Write)?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err(StoreError::Write);
        }
        publish(
            &self.store.0,
            &self.store.0.owner.file(FILE_NAME),
            &state.expected,
            &bytes,
            before_publish,
        )?;
        state.expected = Some(bytes);
        state.published = self.sequence;
        Ok(SaveOutcome::Published)
    }
}
fn publish(
    shared: &Shared,
    path: &Path,
    expected: &Option<Vec<u8>>,
    bytes: &[u8],
    before_publish: impl FnOnce(&crate::files::PreparedSave),
) -> Result<(), StoreError> {
    if read_bytes(path)? != *expected {
        return Err(StoreError::Conflict);
    }
    let capture =
        crate::files::CapturedDestination::capture(path).map_err(|_| StoreError::Write)?;
    let source = std::str::from_utf8(bytes).map_err(|_| StoreError::Write)?;
    let prepared = crate::files::PreparedSave::prepare_captured(source.into(), path, &capture)
        .map_err(|_| StoreError::Write)?;
    before_publish(&prepared);
    // Keep the exact expected destination and reservation authority while the
    // common publisher verifies the anchored parent and staged identity/content.
    if read_bytes(path)? != *expected {
        return Err(StoreError::Conflict);
    }
    #[cfg(test)]
    if shared
        .fail_replace
        .load(std::sync::atomic::Ordering::SeqCst)
    {
        return Err(StoreError::Write);
    }
    #[cfg(not(test))]
    let _ = shared;
    prepared.publish().map_err(|error| {
        #[cfg(windows)]
        if error == crate::files::FileError::Uncertain {
            return StoreError::PublicationUnknown;
        }
        let _ = error;
        StoreError::Write
    })?;
    Ok(())
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
        Ok(metadata) if metadata.is_file() && metadata.len() <= MAX_BYTES => {}
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
    {
        File::open(path)
            .and_then(|file| file.sync_all())
            .map_err(|_| StoreError::Write)?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}
fn decode(bytes: &[u8], platform: NativePlatform) -> Result<Preferences, StoreError> {
    let preferences: Preferences = serde_json::from_slice(bytes).map_err(|_| StoreError::Read)?;
    if preferences.version != VERSION {
        return Err(StoreError::Read);
    }
    preferences
        .validated_bindings(platform)
        .map_err(|_| StoreError::InvalidBindings)?;
    Ok(preferences)
}
