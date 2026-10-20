//! Explicit source-only DTOs. No live document/session/result is serializable.
use crate::instance::DataDirectory;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};

pub const VERSION: u32 = 1;
pub const HISTORY_LIMIT: usize = 1_000;
pub const RETENTION_MS: f64 = 30. * 24. * 60. * 60. * 1_000.;
// File reads are bounded by the captured regular-file length, not an editor
// source cutoff. History retains the shared count and age policy.
const MAX_DOCUMENTS: usize = 1_024;
pub fn new_uuid() -> String {
    uuid::Uuid::new_v4().to_string()
}
pub fn now_ms() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
        * 1_000.
}
fn uuid_valid(id: &str) -> bool {
    uuid::Uuid::parse_str(id).is_ok_and(|v| v.hyphenated().to_string().eq_ignore_ascii_case(id))
}
fn profile_valid(id: &str) -> bool {
    !id.is_empty() && id.len() <= 4096 && !id.contains(':') && !id.chars().any(char::is_control)
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct StoredDocument {
    pub id: String,
    pub title: String,
    pub text: String,
    #[serde(rename = "profileID", default, skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
}
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct HistoryEntry {
    pub id: String,
    pub date: f64,
    #[serde(
        rename = "documentID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub document_id: Option<String>,
    #[serde(rename = "profileID", default, skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
    pub sql: String,
    pub outcome: String,
}
fn enabled_default() -> bool {
    true
}
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Snapshot {
    #[serde(default)]
    pub version: u32,
    pub documents: Vec<StoredDocument>,
    #[serde(
        rename = "selectedDocumentID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub selected_document_id: Option<String>,
    #[serde(default)]
    pub history: Vec<HistoryEntry>,
    #[serde(default = "enabled_default")]
    pub history_enabled: bool,
}
impl Default for Snapshot {
    fn default() -> Self {
        Self {
            version: VERSION,
            documents: Vec::new(),
            selected_document_id: None,
            history: Vec::new(),
            history_enabled: true,
        }
    }
}
impl Snapshot {
    pub fn record(&mut self, entry: HistoryEntry, now: f64) {
        if self.history_enabled {
            self.history.push(entry);
            self.trim(now);
        }
    }
    pub fn trim(&mut self, now: f64) {
        self.history
            .retain(|entry| entry.date >= now - RETENTION_MS);
        // Stable ascending sort + newest suffix matches Swift's offset tie break.
        self.history.sort_by(|a, b| a.date.total_cmp(&b.date));
        if self.history.len() > HISTORY_LIMIT {
            self.history.drain(..self.history.len() - HISTORY_LIMIT);
        }
    }
    fn validate(&self) -> Result<(), StoreError> {
        let mut docs = HashSet::new();
        let mut history = HashSet::new();
        if self.version > VERSION
            || self.documents.len() > MAX_DOCUMENTS
            || self.history.len() > 100_000
            || self.documents.iter().any(|d| {
                !uuid_valid(&d.id)
                    || !docs.insert(d.id.to_lowercase())
                    || d.title.trim().is_empty()
                    || d.title.len() > 16_384
                    || d.profile_id.as_ref().is_some_and(|id| !profile_valid(id))
            })
            || self
                .selected_document_id
                .as_ref()
                .is_some_and(|id| !uuid_valid(id))
            || self.history.iter().any(|e| {
                !uuid_valid(&e.id)
                    || !history.insert(e.id.to_lowercase())
                    || !e.date.is_finite()
                    || e.outcome.len() > 4096
                    || e.document_id.as_ref().is_some_and(|id| !uuid_valid(id))
                    || e.profile_id.as_ref().is_some_and(|id| !profile_valid(id))
            })
        {
            return Err(StoreError::Read);
        }
        Ok(())
    }
}
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
            Self::PublicationUnknown => "SQL workspace publication could not be verified. Keep this window open and inspect the saved file before retrying.",
        Self::Read => "SQL drafts and history could not be read. The existing file has been left unchanged.",
        Self::Write => "SQL drafts and history could not be saved. Keep this window open and retry.",
        Self::Conflict => "The saved SQL workspace changed outside this window. Its file has been left unchanged. Keep this window open to recover your SQL.",
    })
    }
}
fn options() -> OpenOptions {
    let mut o = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        o.custom_flags(0x00200000);
    }
    o
}
fn read_bytes(path: &Path) -> Result<Option<Vec<u8>>, StoreError> {
    match fs::symlink_metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Ok(m) if m.is_file() => {}
        _ => return Err(StoreError::Read),
    }
    let f = options()
        .read(true)
        .open(path)
        .map_err(|_| StoreError::Read)?;
    let m = f.metadata().map_err(|_| StoreError::Read)?;
    if !m.is_file() {
        return Err(StoreError::Read);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if m.file_attributes() & 0x400 != 0 {
            return Err(StoreError::Read);
        }
    }
    let length = usize::try_from(m.len()).map_err(|_| StoreError::Read)?;
    let capacity = length.checked_add(1).ok_or(StoreError::Read)?;
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(capacity)
        .map_err(|_| StoreError::Read)?;
    let after_handle = f.try_clone().map_err(|_| StoreError::Read)?;
    f.take(m.len().checked_add(1).ok_or(StoreError::Read)?)
        .read_to_end(&mut bytes)
        .map_err(|_| StoreError::Read)?;
    let after = after_handle.metadata().map_err(|_| StoreError::Read)?;
    if bytes.len() != length || after.len() != m.len() || after.modified().ok() != m.modified().ok()
    {
        return Err(StoreError::Read);
    }
    Ok(Some(bytes))
}
fn sync_directory(path: &Path) -> Result<(), StoreError> {
    #[cfg(unix)]
    {
        fs::File::open(path)
            .and_then(|file| file.sync_all())
            .map_err(|_| StoreError::Write)?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}
fn decode(bytes: &[u8]) -> Result<Snapshot, StoreError> {
    let mut snapshot: Snapshot = serde_json::from_slice(bytes).map_err(|_| StoreError::Read)?;
    snapshot.validate()?;
    // Canonical UUID case avoids case-sensitive selection/deduplication differences.
    for d in &mut snapshot.documents {
        d.id.make_ascii_lowercase();
    }
    if let Some(id) = &mut snapshot.selected_document_id {
        id.make_ascii_lowercase();
    }
    Ok(snapshot)
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
pub struct WorkspaceStore(Arc<Shared>);
pub struct SaveRequest {
    store: WorkspaceStore,
    sequence: u64,
    snapshot: Snapshot,
}
impl WorkspaceStore {
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
    #[cfg(test)]
    pub(super) fn fail_replacement(&self, fail: bool) {
        self.0.fail_replace.store(fail, Ordering::SeqCst);
    }
    pub fn load(&self) -> Result<Snapshot, StoreError> {
        let _owner = self.0.owner.mutation().map_err(|_| StoreError::Read)?;
        let mut state = self.0.state.lock().map_err(|_| StoreError::Read)?;
        state.loaded = false;
        let path = self.0.owner.file("workspace.json");
        let original = read_bytes(&path)?;
        let mut snapshot = original
            .as_deref()
            .map(decode)
            .transpose()?
            .unwrap_or_default();
        snapshot.trim(now_ms());
        if snapshot.version < VERSION {
            // Backup bytes use the common private, retained-handle publisher.
            // Existing names are never authorized for replacement.
            let bytes = original.as_ref().ok_or(StoreError::Read)?;
            let mut backup = path.with_extension(format!("json.v{}.backup", snapshot.version));
            loop {
                match fs::symlink_metadata(&backup) {
                    Ok(_) => {
                        backup = path.with_extension(format!(
                            "json.v{}-{}.backup",
                            snapshot.version,
                            new_uuid()
                        ));
                        continue;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
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
                break;
            }
            sync_directory(path.parent().ok_or(StoreError::Write)?)?;
            snapshot.version = VERSION;
            state.expected = original;
            state.loaded = true;
            if let Err(e) = self.write_locked(&snapshot, &mut state, |_| {}) {
                state.loaded = false;
                return Err(e);
            }
        } else {
            state.expected = original;
            state.loaded = true;
        }
        Ok(snapshot)
    }
    // Reserve on UI thread before the debounce; old queued writers can never win.
    pub fn reserve(&self, snapshot: Snapshot) -> SaveRequest {
        SaveRequest {
            store: self.clone(),
            sequence: self.0.sequence.fetch_add(1, Ordering::SeqCst) + 1,
            snapshot,
        }
    }
    fn write_locked(
        &self,
        snapshot: &Snapshot,
        state: &mut State,
        before_publish: impl FnOnce(&crate::files::PreparedSave),
    ) -> Result<(), StoreError> {
        snapshot.validate()?;
        let path = self.0.owner.file("workspace.json");
        if read_bytes(&path)? != state.expected {
            return Err(StoreError::Conflict);
        }
        // Serialize with checked growth; valid current sources have no arbitrary
        // per-document or aggregate cutoff. The temporary publisher compares in
        // fixed-size chunks, so verification adds no second file-sized buffer.
        struct Buffer(Vec<u8>);
        impl Write for Buffer {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                self.0
                    .try_reserve(bytes.len())
                    .map_err(std::io::Error::other)?;
                self.0.extend_from_slice(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let mut buffer = Buffer(Vec::new());
        serde_json::to_writer_pretty(&mut buffer, snapshot).map_err(|_| StoreError::Write)?;
        let bytes = buffer.0;
        let capture =
            crate::files::CapturedDestination::capture(&path).map_err(|_| StoreError::Write)?;
        let source = std::str::from_utf8(&bytes).map_err(|_| StoreError::Write)?;
        let prepared = crate::files::PreparedSave::prepare_captured(source.into(), &path, &capture)
            .map_err(|_| StoreError::Write)?;
        before_publish(&prepared);
        // Do not overwrite external/corrupt/future files, even between prepare/publish.
        if read_bytes(&path)? != state.expected {
            return Err(StoreError::Conflict);
        }
        #[cfg(test)]
        if self.0.fail_replace.load(Ordering::SeqCst) {
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
        sync_directory(path.parent().ok_or(StoreError::Write)?)
    }
}
impl SaveRequest {
    pub fn commit(self) -> Result<(), StoreError> {
        self.commit_with(|_| {})
    }
    fn commit_with(
        mut self,
        before_publish: impl FnOnce(&crate::files::PreparedSave),
    ) -> Result<(), StoreError> {
        let _owner = self
            .store
            .0
            .owner
            .mutation()
            .map_err(|_| StoreError::Write)?;
        if self.sequence != self.store.0.sequence.load(Ordering::SeqCst) {
            return Ok(());
        }
        let mut state = self.store.0.state.lock().map_err(|_| StoreError::Write)?;
        if !state.loaded {
            return Err(StoreError::Read);
        }
        self.snapshot.version = VERSION;
        self.snapshot.trim(now_ms());
        self.store
            .write_locked(&self.snapshot, &mut state, before_publish)
    }
}

pub fn failure_outcome(category: &str, unknown: bool) -> &'static str {
    if unknown {
        return "Unknown outcome";
    }
    match category {
        "cancelled" => "Query cancelled",
        "timeout" => "Query timed out",
        "connection" | "transport" => "Connection lost",
        "export" => "Export failed",
        _ => "Query failed",
    }
}

#[cfg(test)]
#[path = "restoration_tests.rs"]
mod tests;
