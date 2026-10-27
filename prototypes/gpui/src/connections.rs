//! Prototype-only connection profiles. Passwords never enter the JSON library.

use gpui_kit::base::Disableable;
use gpui_kit::component::{
    ActiveTheme, WindowExt,
    button::{Button, ButtonVariants},
    checkbox::Checkbox,
    input::{Input, InputState},
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::*;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const LIBRARY_VERSION: u32 = 2;
const MAX_LIBRARY_BYTES: u64 = 4 * 1024 * 1024;
const CREDENTIAL_SERVICE: &str = crate::product_identity::CREDENTIAL_SERVICE;
static NEXT_ID: AtomicU64 = AtomicU64::new(1);

#[cfg(target_os = "macos")]
const CREDENTIAL_HINT: &str =
    "Passwords are stored in macOS Keychain. Saved connections start disconnected.";
#[cfg(target_os = "windows")]
const CREDENTIAL_HINT: &str =
    "Passwords are stored in Windows Credential Manager. Saved connections start disconnected.";
#[cfg(target_os = "linux")]
const CREDENTIAL_HINT: &str = "Passwords are stored in your desktop Secret Service keyring. Saved connections start disconnected.";
#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
const CREDENTIAL_HINT: &str = "A supported system credential store is required to save passwords. Saved connections start disconnected.";

fn credential_error(writing: bool) -> &'static str {
    #[cfg(target_os = "macos")]
    {
        if writing {
            "The password could not be saved in macOS Keychain."
        } else {
            "The password could not be read from macOS Keychain."
        }
    }
    #[cfg(target_os = "windows")]
    {
        if writing {
            "The password could not be saved in Windows Credential Manager. Check access to your Windows credential store."
        } else {
            "The password could not be read from Windows Credential Manager. Check access to your Windows credential store."
        }
    }
    #[cfg(target_os = "linux")]
    {
        if writing {
            "The password could not be saved in Secret Service. Check that a desktop keyring is installed, unlocked, and available over the session D-Bus."
        } else {
            "The password could not be read from Secret Service. Check that a desktop keyring is installed, unlocked, and available over the session D-Bus."
        }
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    {
        let _ = writing;
        "A supported system credential store is unavailable on this platform."
    }
}

fn default_profile_path(
    environment: impl FnMut(&str) -> Option<OsString>,
) -> Result<PathBuf, ProfileError> {
    let platform = crate::product_identity::Platform::current().ok_or(ProfileError::Read)?;
    crate::product_identity::compatible_library_path(platform, environment)
        .map_err(|_| ProfileError::Read)
}

fn default_readonly() -> bool {
    true
}

fn default_environment() -> String {
    "development".into()
}

fn unique_id() -> String {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!(
        "gpui-{timestamp:x}-{:x}-{:x}",
        std::process::id(),
        NEXT_ID.fetch_add(1, Ordering::Relaxed)
    )
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConnectionProfile {
    pub id: String,
    pub name: String,
    pub engine: String,
    pub host: String,
    pub port: u16,
    pub database: String,
    pub user: String,
    pub ssl_mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssl_root_cert: Option<String>,
    #[serde(default = "default_readonly")]
    pub readonly: bool,
    #[serde(default = "default_environment")]
    pub environment: String,
}

impl Default for ConnectionProfile {
    fn default() -> Self {
        Self::new()
    }
}

impl ConnectionProfile {
    pub fn new() -> Self {
        Self {
            id: unique_id(),
            name: "Local PostgreSQL".into(),
            engine: "postgresql".into(),
            host: "localhost".into(),
            port: 5432,
            database: "postgres".into(),
            user: "postgres".into(),
            ssl_mode: "verify-full".into(),
            ssl_root_cert: None,
            readonly: false,
            environment: "unspecified".into(),
        }
    }

    pub fn display_engine(&self) -> &'static str {
        if self.engine == "mysql" {
            "MySQL"
        } else {
            "PostgreSQL"
        }
    }

    pub fn ssl_modes(&self) -> &'static [&'static str] {
        if self.engine == "mysql" {
            &["disable", "require", "verify-ca", "verify-full"]
        } else {
            &[
                "disable",
                "allow",
                "prefer",
                "require",
                "verify-ca",
                "verify-full",
            ]
        }
    }

    pub fn validate(&self) -> Result<(), ProfileError> {
        if self.id.is_empty()
            || self.id.len() > 128
            || !self
                .id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-')
            || !matches!(self.engine.as_str(), "postgresql" | "mysql")
            || self.port == 0
            || [&self.name, &self.host, &self.database, &self.user]
                .iter()
                .any(|value| value.trim().is_empty() || value.len() > 4096 || value.contains('\0'))
            || !self.ssl_modes().contains(&self.ssl_mode.as_str())
            || !["development", "staging", "production", "unspecified"]
                .contains(&self.environment.as_str())
            || self.ssl_root_cert.as_ref().is_some_and(|path| {
                !Path::new(path).is_absolute() || path.len() > 4096 || path.contains('\0')
            })
        {
            return Err(ProfileError::Invalid);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProfileError {
    Invalid,
    Read,
    Write,
    Ownership,
    CredentialRead,
    CredentialWrite,
    CredentialDelete,
    CredentialRollback,
    Conflict,
    #[cfg(windows)]
    PublicationUnknown,
}

impl std::fmt::Display for ProfileError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Ownership => {
                "Another DBeer instance owns the data directory, or ownership is unavailable."
            }
            Self::Invalid => "Check the connection fields, port, and absolute CA certificate path.",
            Self::Read => {
                "Saved connections could not be read. The existing file was left unchanged."
            }
            Self::Write => "The connection profile could not be saved.",
            Self::CredentialRead => credential_error(false),
            Self::CredentialWrite => credential_error(true),
            Self::CredentialDelete => "The saved password could not be removed from the system credential store. Check that the store is unlocked and available.",
            Self::CredentialRollback => "The profile change failed and the previous password could not be restored in the system credential store. The profile metadata was not saved. Review the saved password before connecting or retrying.",
            #[cfg(windows)]
            Self::PublicationUnknown => "Profile publication could not be verified. Inspect the saved profile and password before connecting again.",
            Self::Conflict => "The saved profile changed while this operation was pending. Reopen it before saving again.",
        })
    }
}

impl std::error::Error for ProfileError {}

/// Version 2 is GPUI-owned metadata only. It never opens the Swift library.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProfileLibrary {
    version: u32,
    pub connections: Vec<ConnectionProfile>,
    pub selected_profile_id: Option<String>,
}
impl Default for ProfileLibrary {
    fn default() -> Self {
        Self {
            version: LIBRARY_VERSION,
            connections: Vec::new(),
            selected_profile_id: None,
        }
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PrototypeLibrary {
    version: u32,
    connections: Vec<ConnectionProfile>,
}

trait CredentialStore: Send + Sync {
    fn read(&self, id: &str) -> Result<Option<String>, ProfileError>;
    fn save(&self, id: &str, password: &str) -> Result<(), ProfileError>;
    fn delete(&self, id: &str) -> Result<(), ProfileError>;
}
struct SystemCredentials;
impl CredentialStore for SystemCredentials {
    fn read(&self, id: &str) -> Result<Option<String>, ProfileError> {
        keychain::read(id)
    }
    fn save(&self, id: &str, password: &str) -> Result<(), ProfileError> {
        keychain::save(id, password)
    }
    fn delete(&self, id: &str) -> Result<(), ProfileError> {
        keychain::delete(id)
    }
}
trait LibraryReplacement: Send + Sync {
    fn replace(&self, prepared: crate::files::PreparedSave) -> Result<(), ProfileError>;
}
struct AtomicReplacement;
impl LibraryReplacement for AtomicReplacement {
    fn replace(&self, prepared: crate::files::PreparedSave) -> Result<(), ProfileError> {
        prepared.publish().map(|_| ()).map_err(|error| {
            #[cfg(windows)]
            if error == crate::files::FileError::Uncertain {
                return ProfileError::PublicationUnknown;
            }
            let _ = error;
            ProfileError::Write
        })
    }
}

#[derive(Clone)]
pub struct ProfileStore {
    path: PathBuf,
    ownership: Arc<crate::instance::DataDirectory>,
    credentials: Arc<dyn CredentialStore>,
    replacement: Arc<dyn LibraryReplacement>,
}

impl ProfileStore {
    pub fn default_path() -> Result<PathBuf, ProfileError> {
        default_profile_path(|name| std::env::var_os(name))
    }
    pub fn acquire(path: PathBuf) -> Result<Self, ProfileError> {
        let root = path.parent().ok_or(ProfileError::Ownership)?;
        let ownership =
            crate::instance::DataDirectory::acquire(root).map_err(|_| ProfileError::Ownership)?;
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or(ProfileError::Ownership)?;
        Ok(Self::with_owner(ownership, name))
    }
    fn with_owner(ownership: Arc<crate::instance::DataDirectory>, name: &str) -> Self {
        Self {
            path: ownership.file(name),
            ownership,
            credentials: Arc::new(SystemCredentials),
            replacement: Arc::new(AtomicReplacement),
        }
    }
    #[cfg(test)]
    pub fn owned(ownership: Arc<crate::instance::DataDirectory>) -> Self {
        Self::with_owner(ownership, "connections.json")
    }
    #[cfg(test)]
    fn new(path: PathBuf) -> Self {
        Self::acquire(path).expect("Isolated profile store ownership")
    }

    pub(super) fn data_owner(&self) -> Arc<crate::instance::DataDirectory> {
        self.ownership.clone()
    }

    pub fn load_library(&self) -> Result<ProfileLibrary, ProfileError> {
        let _mutation = self
            .ownership
            .mutation()
            .map_err(|_| ProfileError::Ownership)?;
        self.load_locked()
    }
    #[cfg(test)]
    pub fn load(&self) -> Result<Vec<ConnectionProfile>, ProfileError> {
        Ok(self.load_library()?.connections)
    }
    fn load_locked(&self) -> Result<ProfileLibrary, ProfileError> {
        let Some(bytes) = read_library_bytes(&self.path)? else {
            return Ok(ProfileLibrary::default());
        };
        #[derive(Deserialize)]
        struct Header {
            version: u32,
        }
        let header: Header = serde_json::from_slice(&bytes).map_err(|_| ProfileError::Read)?;
        match header.version {
            1 => {
                // Bind the exact validated input and its parent before backup
                // work. Never adopt a later primary as migration authority.
                let opened = crate::files::open(&self.path).map_err(|_| ProfileError::Conflict)?;
                if opened.source.as_bytes() != bytes {
                    return Err(ProfileError::Conflict);
                }
                let capture = crate::files::CapturedDestination::capture_for_binding(
                    &self.path,
                    &opened.binding,
                )
                .map_err(|_| ProfileError::Conflict)?;
                let old: PrototypeLibrary =
                    serde_json::from_str(&opened.source).map_err(|_| ProfileError::Read)?;
                if old.version != 1 {
                    return Err(ProfileError::Read);
                }
                validate_profiles(&old.connections).map_err(|_| ProfileError::Read)?;
                let selected_profile_id = old.connections.first().map(|p| p.id.clone());
                let library = ProfileLibrary {
                    version: LIBRARY_VERSION,
                    connections: old.connections,
                    selected_profile_id,
                };
                // Only validated v1 metadata is backed up. Keep every exact byte,
                // including whitespace; a pre-existing backup is never replaced.
                self.backup_legacy(&bytes)?;
                self.prepare_library_captured(&library, Some(bytes), &capture)?
                    .commit()?;
                Ok(library)
            }
            LIBRARY_VERSION => {
                let library: ProfileLibrary =
                    serde_json::from_slice(&bytes).map_err(|_| ProfileError::Read)?;
                // Legacy policy defaults are migration rules, never recovery for
                // malformed current metadata. Explicit policy is required in v2.
                let json: serde_json::Value =
                    serde_json::from_slice(&bytes).map_err(|_| ProfileError::Read)?;
                if json["connections"].as_array().is_none_or(|profiles| {
                    profiles
                        .iter()
                        .any(|p| p.get("readonly").is_none() || p.get("environment").is_none())
                }) {
                    return Err(ProfileError::Read);
                }
                validate_library(&library).map_err(|_| ProfileError::Read)?;
                Ok(library)
            }
            _ => Err(ProfileError::Read),
        }
    }
    fn backup_legacy(&self, bytes: &[u8]) -> Result<(), ProfileError> {
        let mut path = self.path.with_extension("json.v1.backup");
        loop {
            match fs::symlink_metadata(&path) {
                Ok(_) => {
                    path = self
                        .path
                        .with_extension(format!("json.v1-{}.backup", unique_id()));
                    continue;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(_) => return Err(ProfileError::Write),
            }
            let capture = crate::files::CapturedDestination::capture(&path)
                .map_err(|_| ProfileError::Write)?;
            crate::files::PreparedSave::prepare_bytes_captured(Arc::from(bytes), &path, &capture)
                .map_err(|_| ProfileError::Write)?
                .publish()
                .map_err(|error| {
                    #[cfg(windows)]
                    if error == crate::files::FileError::Uncertain {
                        return ProfileError::PublicationUnknown;
                    }
                    let _ = error;
                    ProfileError::Write
                })?;
            // A completed backup remains evidence even if directory durability
            // fails. The primary migration must not start in that case.
            #[cfg(unix)]
            fs::File::open(path.parent().ok_or(ProfileError::Write)?)
                .and_then(|file| file.sync_all())
                .map_err(|_| ProfileError::Write)?;
            return Ok(());
        }
    }
    #[cfg(test)]
    pub fn save(&self, profiles: &[ConnectionProfile]) -> Result<(), ProfileError> {
        let _mutation = self
            .ownership
            .mutation()
            .map_err(|_| ProfileError::Ownership)?;
        let mut library = self.load_locked()?;
        library.connections = profiles.to_vec();
        if !library
            .connections
            .iter()
            .any(|p| Some(&p.id) == library.selected_profile_id.as_ref())
        {
            library.selected_profile_id = None;
        }
        self.prepare_library(&library)?.commit()
    }
    #[cfg(test)]
    fn prepare(&self, profiles: &[ConnectionProfile]) -> Result<PreparedLibrary, ProfileError> {
        let _mutation = self
            .ownership
            .mutation()
            .map_err(|_| ProfileError::Ownership)?;
        let mut library = self.load_locked()?;
        library.connections = profiles.to_vec();
        self.prepare_library(&library)
    }
    fn prepare_library(&self, library: &ProfileLibrary) -> Result<PreparedLibrary, ProfileError> {
        let original = read_library_bytes(&self.path)?;
        let capture = crate::files::CapturedDestination::capture(&self.path)
            .map_err(|_| ProfileError::Write)?;
        self.prepare_library_captured(library, original, &capture)
    }
    fn prepare_library_captured(
        &self,
        library: &ProfileLibrary,
        original: Option<Vec<u8>>,
        capture: &crate::files::CapturedDestination,
    ) -> Result<PreparedLibrary, ProfileError> {
        validate_library(library)?;
        let mut bytes = serde_json::to_vec_pretty(library).map_err(|_| ProfileError::Write)?;
        bytes.push(b'\n');
        if bytes.len() as u64 > MAX_LIBRARY_BYTES {
            return Err(ProfileError::Write);
        }
        let source = String::from_utf8(bytes).map_err(|_| ProfileError::Write)?;
        let prepared = PreparedLibrary {
            prepared: crate::files::PreparedSave::prepare_captured(
                source.into(),
                &self.path,
                capture,
            )
            .map_err(|_| ProfileError::Write)?,
            destination: self.path.clone(),
            original,
            replacement: self.replacement.clone(),
            _ownership: self.ownership.clone(),
        };
        Ok(prepared)
    }
    #[cfg(test)]
    fn upsert(
        &self,
        profile: &ConnectionProfile,
        password: Option<&str>,
    ) -> Result<(), ProfileError> {
        self.update(profile, password, None, false)
    }
    pub(super) fn save_profile(
        &self,
        profile: &ConnectionProfile,
        password: Option<&str>,
        expected: Option<&ConnectionProfile>,
    ) -> Result<(), ProfileError> {
        self.update(profile, password, expected, true)
    }
    fn update(
        &self,
        profile: &ConnectionProfile,
        password: Option<&str>,
        expected: Option<&ConnectionProfile>,
        check_expected: bool,
    ) -> Result<(), ProfileError> {
        let _mutation = self
            .ownership
            .mutation()
            .map_err(|_| ProfileError::Ownership)?;
        let mut library = self.load_locked()?;
        let existing = library.connections.iter().position(|p| p.id == profile.id);
        if check_expected && existing.map(|i| &library.connections[i]) != expected {
            return Err(ProfileError::Conflict);
        }
        match existing {
            Some(i) => library.connections[i] = profile.clone(),
            None => library.connections.push(profile.clone()),
        }
        let prepared = self.prepare_library(&library)?;
        if let Some(password) = password {
            self.change_credential(&profile.id, Some(password), prepared)?;
        } else {
            prepared.commit()?;
        }
        Ok(())
    }
    // Used by Task 6's guarded delete lifecycle; no workspace/session side effects.
    #[allow(dead_code)]
    pub fn delete(&self, expected: &ConnectionProfile) -> Result<ProfileLibrary, ProfileError> {
        let _mutation = self
            .ownership
            .mutation()
            .map_err(|_| ProfileError::Ownership)?;
        let mut library = self.load_locked()?;
        let index = library
            .connections
            .iter()
            .position(|p| p.id == expected.id)
            .ok_or(ProfileError::Conflict)?;
        if &library.connections[index] != expected {
            return Err(ProfileError::Conflict);
        }
        library.connections.remove(index);
        if library.selected_profile_id.as_deref() == Some(&expected.id) {
            library.selected_profile_id = library.connections.first().map(|p| p.id.clone());
        }
        let prepared = self.prepare_library(&library)?;
        self.change_credential(&expected.id, None, prepared)?;
        Ok(library)
    }
    fn change_credential(
        &self,
        id: &str,
        password: Option<&str>,
        prepared: PreparedLibrary,
    ) -> Result<(), ProfileError> {
        let previous = self.credentials.read(id)?;
        let change = match password {
            Some(value) => self.credentials.save(id, value),
            None => self.credentials.delete(id),
        };
        // Some native stores can report failure after mutation. Restore on both
        // credential-operation failure and metadata-replacement failure.
        if let Err(error) = change.and_then(|_| prepared.commit()) {
            let rollback = match previous {
                Some(value) => self.credentials.save(id, &value),
                None => self.credentials.delete(id),
            };
            return if rollback.is_err() {
                Err(ProfileError::CredentialRollback)
            } else {
                Err(error)
            };
        }
        Ok(())
    }
    /// Append one reviewed batch atomically. Merge newly added profiles and
    /// selection, but refuse changes/removal of any original reviewed profile.
    /// Imported identities are allocated here; credentials are never accessed.
    pub(super) fn import_profiles(
        &self,
        expected: &[ConnectionProfile],
        reviewed: &[crate::transfer::ImportedProfile],
    ) -> Result<Vec<ConnectionProfile>, ProfileError> {
        let _mutation = self
            .ownership
            .mutation()
            .map_err(|_| ProfileError::Ownership)?;
        let mut library = self.load_locked()?;
        if expected.iter().any(|p| !library.connections.contains(p)) {
            return Err(ProfileError::Conflict);
        }
        let selected: Vec<_> = reviewed.iter().filter(|p| p.selected).collect();
        if selected.is_empty()
            || selected.len() > crate::transfer::MAX_PROFILES
            || selected.iter().any(|p| p.requires_ca())
        {
            return Err(ProfileError::Invalid);
        }
        let mut imported = Vec::new();
        for item in selected {
            let mut profile = item.profile.clone();
            // No transferred or preview identity can address an existing item.
            loop {
                profile.id = unique_id();
                if !library.connections.iter().any(|p| p.id == profile.id) {
                    break;
                }
            }
            profile.validate()?;
            imported.push(profile.clone());
            library.connections.push(profile);
        }
        // Transfer field bounds remain stricter than the private library.
        crate::transfer::encode(&imported).map_err(|_| ProfileError::Invalid)?;
        let prepared = self.prepare_library(&library)?;
        // Recheck readability immediately before publication. Never fall back
        // to system roots if a reviewed CA disappears while preparing the file.
        if reviewed.iter().any(|p| p.selected && p.requires_ca()) {
            return Err(ProfileError::Invalid);
        }
        prepared.commit()?;
        Ok(imported)
    }
    pub fn selection(&self, id: Option<&crate::model::ProfileId>) -> SelectionRequest {
        SelectionRequest {
            store: self.clone(),
            id: id.map(|id| id.0.clone()),
            sequence: self.ownership.next_selection(),
        }
    }
}

/// Reserved on the UI thread before dispatch. Late workers load current data,
/// never write captured libraries, and cannot overwrite a more recent selection.
pub struct SelectionRequest {
    store: ProfileStore,
    id: Option<String>,
    sequence: u64,
}
impl SelectionRequest {
    pub fn commit(self) -> Result<(), ProfileError> {
        let _mutation = self
            .store
            .ownership
            .mutation()
            .map_err(|_| ProfileError::Ownership)?;
        if !self.store.ownership.selection_is_current(self.sequence) {
            return Ok(());
        }
        let mut library = self.store.load_locked()?;
        if self
            .id
            .as_ref()
            .is_some_and(|id| !library.connections.iter().any(|p| &p.id == id))
        {
            return Err(ProfileError::Conflict);
        }
        if library.selected_profile_id == self.id {
            return Ok(());
        }
        library.selected_profile_id = self.id;
        self.store.prepare_library(&library)?.commit()
    }
}

fn validate_profiles(profiles: &[ConnectionProfile]) -> Result<(), ProfileError> {
    let mut ids = HashSet::new();
    for profile in profiles {
        profile.validate()?;
        if !ids.insert(profile.id.as_str()) {
            return Err(ProfileError::Invalid);
        }
    }
    Ok(())
}
fn validate_library(library: &ProfileLibrary) -> Result<(), ProfileError> {
    validate_profiles(&library.connections)?;
    if library.version != LIBRARY_VERSION
        || library
            .selected_profile_id
            .as_ref()
            .is_some_and(|id| !library.connections.iter().any(|p| &p.id == id))
    {
        return Err(ProfileError::Invalid);
    }
    Ok(())
}
fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
        #[cfg(target_os = "macos")]
        options.custom_flags(0x100); // O_NOFOLLOW
        #[cfg(target_os = "linux")]
        options.custom_flags(0x20000); // O_NOFOLLOW
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000);
    } // FILE_FLAG_OPEN_REPARSE_POINT
    options
}
fn read_library_bytes(path: &Path) -> Result<Option<Vec<u8>>, ProfileError> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Ok(metadata) if metadata.file_type().is_file() => {}
        _ => return Err(ProfileError::Read),
    }
    let file = private_options()
        .read(true)
        .open(path)
        .map_err(|_| ProfileError::Read)?;
    let metadata = file.metadata().map_err(|_| ProfileError::Read)?;
    if !metadata.is_file() || metadata.len() > MAX_LIBRARY_BYTES {
        return Err(ProfileError::Read);
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(ProfileError::Read);
        }
    }
    let mut bytes = Vec::new();
    file.take(MAX_LIBRARY_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ProfileError::Read)?;
    if bytes.len() as u64 > MAX_LIBRARY_BYTES {
        return Err(ProfileError::Read);
    }
    Ok(Some(bytes))
}
struct PreparedLibrary {
    prepared: crate::files::PreparedSave,
    destination: PathBuf,
    original: Option<Vec<u8>>,
    replacement: Arc<dyn LibraryReplacement>,
    _ownership: Arc<crate::instance::DataDirectory>,
}
impl PreparedLibrary {
    fn commit(self) -> Result<(), ProfileError> {
        if read_library_bytes(&self.destination)? != self.original {
            return Err(ProfileError::Conflict);
        }
        self.replacement.replace(self.prepared)
    }
}
pub fn read_password(id: &str) -> Result<String, ProfileError> {
    Ok(keychain::read(id)?.unwrap_or_default())
}

#[cfg(all(
    feature = "native-smoke",
    any(target_os = "windows", target_os = "linux")
))]
pub(super) fn feasibility_read_password(id: &str) -> Result<Option<String>, ProfileError> {
    if !crate::feasibility::valid_account(id) {
        return Err(ProfileError::Invalid);
    }
    keychain::probe_read_for_service("dev.dbeer.gpui-prototype.feasibility-v1", id)
}
#[cfg(all(
    feature = "native-smoke",
    any(target_os = "windows", target_os = "linux")
))]
pub(super) fn feasibility_save_password(id: &str, password: &str) -> Result<(), ProfileError> {
    if !crate::feasibility::valid_account(id) {
        return Err(ProfileError::Invalid);
    }
    if password.is_empty() {
        keychain::delete_for_service("dev.dbeer.gpui-prototype.feasibility-v1", id)
    } else {
        keychain::save_for_service("dev.dbeer.gpui-prototype.feasibility-v1", id, password)
    }
}

#[derive(Clone)]
pub struct ProfileSaveRequested {
    pub profile: ConnectionProfile,
    pub expected: Option<ConnectionProfile>,
    pub password: Option<Arc<crate::startup::Secret>>,
    pub connect: bool,
}

/// A form mounted inside the shared GPUI dialog; saving never connects by itself.
pub struct ConnectionEditor {
    profile: ConnectionProfile,
    original: Option<ConnectionProfile>,
    name: Entity<InputState>,
    host: Entity<InputState>,
    port: Entity<InputState>,
    database: Entity<InputState>,
    user: Entity<InputState>,
    password: Entity<InputState>,
    ca: Entity<InputState>,
    replace_password: bool,
    existing: bool,
    saving: bool,
    active: bool,
    chooser: Option<Task<()>>,
    error: Option<SharedString>,
}

impl EventEmitter<ProfileSaveRequested> for ConnectionEditor {}

impl ConnectionEditor {
    pub fn new(
        profile: Option<ConnectionProfile>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let existing = profile.is_some();
        let original = profile.clone();
        let profile = profile.unwrap_or_default();
        let name = cx.new(|cx| {
            InputState::new(window, cx)
                .default_value(profile.name.clone())
                .placeholder("Connection name")
        });
        let host = cx.new(|cx| InputState::new(window, cx).default_value(profile.host.clone()));
        let port = cx.new(|cx| InputState::new(window, cx).default_value(profile.port.to_string()));
        let database =
            cx.new(|cx| InputState::new(window, cx).default_value(profile.database.clone()));
        let user = cx.new(|cx| InputState::new(window, cx).default_value(profile.user.clone()));
        let password = cx.new(|cx| {
            InputState::new(window, cx)
                .masked(true)
                .placeholder(if existing {
                    "Stored in system credential store"
                } else {
                    "Password"
                })
        });
        let ca = cx.new(|cx| {
            InputState::new(window, cx)
                .default_value(profile.ssl_root_cert.clone().unwrap_or_default())
                .placeholder("Optional absolute path to a CA certificate")
        });
        Self {
            profile,
            original,
            name,
            host,
            port,
            database,
            user,
            password,
            ca,
            replace_password: !existing,
            existing,
            saving: false,
            active: true,
            chooser: None,
            error: None,
        }
    }

    pub fn focus(&self, window: &mut Window, cx: &mut App) {
        self.name.update(cx, |input, cx| input.focus(window, cx));
    }

    pub(super) fn from_startup(
        profile: ConnectionProfile,
        expected: Option<ConnectionProfile>,
        password: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut editor = Self::new(Some(profile), window, cx);
        editor.existing = expected.is_some();
        editor.original = expected;
        editor.replace_password = true;
        editor
            .password
            .update(cx, |input, cx| input.set_value(password, window, cx));
        editor
    }

    fn switch_engine(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let was_mysql = self.profile.engine == "mysql";
        self.profile.engine = if was_mysql { "postgresql" } else { "mysql" }.into();
        let old_port = if was_mysql { "3306" } else { "5432" };
        let new_port = if was_mysql { "5432" } else { "3306" };
        let old_database = if was_mysql { "mysql" } else { "postgres" };
        let new_database = if was_mysql { "postgres" } else { "mysql" };
        let old_user = if was_mysql { "root" } else { "postgres" };
        let new_user = if was_mysql { "postgres" } else { "root" };
        for (input, old, new) in [
            (&self.port, old_port, new_port),
            (&self.database, old_database, new_database),
            (&self.user, old_user, new_user),
        ] {
            if input.read(cx).value().as_ref() == old {
                input.update(cx, |input, cx| input.set_value(new, window, cx));
            }
        }
        if !self
            .profile
            .ssl_modes()
            .contains(&self.profile.ssl_mode.as_str())
        {
            self.profile.ssl_mode = "verify-full".into();
        }
        let old_name = if was_mysql {
            "Local MySQL"
        } else {
            "Local PostgreSQL"
        };
        if self.name.read(cx).value().as_ref() == old_name {
            let new_name = format!("Local {}", self.profile.display_engine());
            self.name
                .update(cx, |input, cx| input.set_value(new_name, window, cx));
        }
        cx.notify();
    }

    fn save(&mut self, connect: bool, _: &mut Window, cx: &mut Context<Self>) {
        if !self.active || self.saving || self.chooser.is_some() {
            return;
        }
        let port = self.port.read(cx).value().trim().parse::<u16>();
        let Ok(port) = port else {
            self.error = Some("Port must be a number from 1 to 65535.".into());
            cx.notify();
            return;
        };
        let mut profile = self.profile.clone();
        profile.name = self.name.read(cx).value().trim().to_string();
        profile.host = self.host.read(cx).value().trim().to_string();
        profile.port = port;
        profile.database = self.database.read(cx).value().trim().to_string();
        profile.user = self.user.read(cx).value().trim().to_string();
        let ca = self.ca.read(cx).value().trim().to_string();
        profile.ssl_root_cert = if ca.is_empty() { None } else { Some(ca) };
        if let Err(error) = profile.validate() {
            self.error = Some(error.to_string().into());
            cx.notify();
            return;
        }
        let password = self.replace_password.then(|| {
            Arc::new(crate::startup::Secret::new(
                self.password.read(cx).value().to_string(),
            ))
        });
        self.error = None;
        self.saving = true;
        cx.emit(ProfileSaveRequested {
            profile,
            expected: self.original.clone(),
            password,
            connect,
        });
        cx.notify();
    }

    pub(super) fn is_active(&self) -> bool {
        self.active
    }

    pub(super) fn activate(&mut self) {
        self.active = true;
    }
    pub(super) fn deactivate(&mut self) {
        self.active = false;
    }
    pub(super) fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.active || self.saving || self.chooser.is_some() {
            return;
        }
        self.clear_password(window, cx);
        self.active = false;
        window.close_dialog(cx);
        cx.notify();
    }

    pub(super) fn finish_save(&mut self, error: Option<String>, cx: &mut Context<Self>) {
        self.active = error.is_some();
        self.saving = false;
        self.error = error.map(Into::into);
        cx.notify();
    }

    pub(super) fn clear_password(&self, window: &mut Window, cx: &mut App) {
        self.password
            .update(cx, |input, cx| input.set_value("", window, cx));
    }

    fn choose_ca(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.active || self.saving || self.chooser.is_some() {
            return;
        }
        let selected = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Choose a CA certificate".into()),
        });
        self.chooser = Some(cx.spawn_in(window, async move |this, cx| {
            let result = selected.await;
            _ = this.update_in(cx, |this, window, cx| {
                this.chooser = None;
                if !this.active || this.saving {
                    return;
                }
                match result {
                    Ok(Ok(Some(paths))) if paths.len() == 1 => {
                        if let Some(path) = paths[0].to_str().filter(|_| paths[0].is_absolute()) {
                            let path = path.to_owned();
                            this.ca
                                .update(cx, |input, cx| input.set_value(path, window, cx));
                        } else {
                            this.error = Some(
                                "Choose an absolute certificate path with a valid Unicode name."
                                    .into(),
                            );
                        }
                    }
                    Ok(Ok(None)) => {}
                    _ => {
                        this.error = Some("The CA certificate chooser could not be opened.".into())
                    }
                }
                cx.notify();
            });
        }));
    }

    fn field(
        label: &'static str,
        id: &'static str,
        state: &Entity<InputState>,
    ) -> impl IntoElement {
        div()
            .flex()
            .flex_col()
            .gap_1()
            .flex_1()
            .child(div().text_sm().child(label))
            .child(
                Input::new(state)
                    .id(id)
                    .accessibility_id(id)
                    .aria_label(label)
                    .w_full(),
            )
    }
}

impl Render for ConnectionEditor {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let busy = self.saving || self.chooser.is_some();
        div()
            .id("connection-editor")
            .flex()
            .flex_col()
            .w_full()
            .gap_3()
            .child(Self::field("Name", "connection-name", &self.name))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(div().w(px(80.)).child("Database"))
                    .child(
                        Button::new("connection-engine")
                            .label(self.profile.display_engine())
                            .disabled(busy)
                            .on_click(
                                cx.listener(|this, _, window, cx| this.switch_engine(window, cx)),
                            ),
                    ),
            )
            .child(
                div()
                    .flex()
                    .gap_3()
                    .child(Self::field("Host", "connection-host", &self.host))
                    .child(div().w(px(100.)).child(Self::field(
                        "Port",
                        "connection-port",
                        &self.port,
                    ))),
            )
            .child(
                div()
                    .flex()
                    .gap_3()
                    .child(Self::field(
                        "Database name",
                        "connection-database",
                        &self.database,
                    ))
                    .child(Self::field("User", "connection-user", &self.user)),
            )
            .when(self.existing, |element| {
                element.child(
                    Checkbox::new("replace-connection-password")
                        .label("Replace stored password")
                        .checked(self.replace_password)
                        .disabled(busy)
                        .on_change(cx.listener(|this, checked, _, cx| {
                            this.replace_password = *checked;
                            cx.notify();
                        })),
                )
            })
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(div().text_sm().child("Password"))
                    .child(
                        Input::new(&self.password)
                            .id("connection-password")
                            .accessibility_id("dbeer-connection-password")
                            .aria_label("Connection password")
                            .disabled(busy || !self.replace_password)
                            .w_full(),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(div().w(px(80.)).child("TLS mode"))
                    .child(
                        Button::new("connection-tls-mode")
                            .label(self.profile.ssl_mode.clone())
                            .disabled(busy)
                            .on_click(cx.listener(|this, _, _, cx| {
                                let modes = this.profile.ssl_modes();
                                let index = modes
                                    .iter()
                                    .position(|mode| *mode == this.profile.ssl_mode)
                                    .unwrap_or(0);
                                this.profile.ssl_mode = modes[(index + 1) % modes.len()].into();
                                cx.notify();
                            })),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_end()
                    .gap_2()
                    .child(Self::field(
                        "CA certificate",
                        "connection-ca-certificate",
                        &self.ca,
                    ))
                    .child(
                        Button::new("connection-choose-ca")
                            .label("Choose...")
                            .disabled(busy)
                            .on_click(
                                cx.listener(|this, _, window, cx| this.choose_ca(window, cx)),
                            ),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .child(
                        Checkbox::new("connection-readonly")
                            .label("Read only")
                            .checked(self.profile.readonly)
                            .disabled(busy)
                            .on_change(cx.listener(|this, readonly, _, cx| {
                                this.profile.readonly = *readonly;
                                cx.notify();
                            })),
                    )
                    .child(div().flex_1())
                    .child(div().text_sm().child("Environment"))
                    .child(
                        Button::new("connection-environment")
                            .label(self.profile.environment.clone())
                            .disabled(busy)
                            .on_click(cx.listener(|this, _, _, cx| {
                                let environments =
                                    ["development", "staging", "production", "unspecified"];
                                let index = environments
                                    .iter()
                                    .position(|value| *value == this.profile.environment)
                                    .unwrap_or(0);
                                this.profile.environment =
                                    environments[(index + 1) % environments.len()].into();
                                cx.notify();
                            })),
                    ),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child(CREDENTIAL_HINT),
            )
            .when_some(self.error.clone(), |element, error| {
                element.child(div().text_sm().text_color(cx.theme().danger).child(error))
            })
            .child(
                div()
                    .flex()
                    .justify_end()
                    .gap_2()
                    .pt_2()
                    .child(
                        Button::new("connection-cancel")
                            .label("Cancel")
                            .ghost()
                            .disabled(busy)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.cancel(window, cx);
                            })),
                    )
                    .child(
                        Button::new("connection-save")
                            .label(if busy { "Saving..." } else { "Save" })
                            .disabled(busy)
                            .on_click(
                                cx.listener(|this, _, window, cx| this.save(false, window, cx)),
                            ),
                    )
                    .child(
                        Button::new("connection-save-connect")
                            .label("Save & Connect")
                            .primary()
                            .disabled(busy)
                            .on_click(
                                cx.listener(|this, _, window, cx| this.save(true, window, cx)),
                            ),
                    ),
            )
    }
}

#[cfg(target_os = "macos")]
mod keychain {
    use super::ProfileError;
    use std::ffi::c_void;
    use std::ptr;

    type CFTypeRef = *const c_void;
    type CFMutableDictionaryRef = *mut c_void;
    const SERVICE: &str = super::CREDENTIAL_SERVICE;
    const ITEM_NOT_FOUND: i32 = -25300;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFBooleanTrue: CFTypeRef;
        fn CFRelease(object: CFTypeRef);
        fn CFStringCreateWithBytes(
            allocator: CFTypeRef,
            bytes: *const u8,
            length: isize,
            encoding: u32,
            external: u8,
        ) -> CFTypeRef;
        fn CFDataCreate(allocator: CFTypeRef, bytes: *const u8, length: isize) -> CFTypeRef;
        fn CFDataGetLength(data: CFTypeRef) -> isize;
        fn CFDataGetBytePtr(data: CFTypeRef) -> *const u8;
        fn CFArrayCreate(
            allocator: CFTypeRef,
            values: *const CFTypeRef,
            count: isize,
            callbacks: *const c_void,
        ) -> CFTypeRef;
        fn CFDictionaryCreateMutable(
            allocator: CFTypeRef,
            capacity: isize,
            keys: *const c_void,
            values: *const c_void,
        ) -> CFMutableDictionaryRef;
        fn CFDictionarySetValue(
            dictionary: CFMutableDictionaryRef,
            key: CFTypeRef,
            value: CFTypeRef,
        );
    }

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        static kSecClass: CFTypeRef;
        static kSecClassGenericPassword: CFTypeRef;
        static kSecAttrService: CFTypeRef;
        static kSecAttrAccount: CFTypeRef;
        static kSecReturnData: CFTypeRef;
        static kSecMatchLimit: CFTypeRef;
        static kSecMatchLimitOne: CFTypeRef;
        static kSecValueData: CFTypeRef;
        static kSecAttrAccessible: CFTypeRef;
        static kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CFTypeRef;
        static kSecMatchSearchList: CFTypeRef;
        static kSecUseKeychain: CFTypeRef;
        fn SecItemCopyMatching(query: CFTypeRef, result: *mut CFTypeRef) -> i32;
        fn SecItemUpdate(query: CFTypeRef, attributes: CFTypeRef) -> i32;
        fn SecItemAdd(attributes: CFTypeRef, result: *mut CFTypeRef) -> i32;
        fn SecItemDelete(query: CFTypeRef) -> i32;
        #[cfg(test)]
        fn SecKeychainCreate(
            path: *const std::ffi::c_char,
            password_length: u32,
            password: *const c_void,
            prompt_user: u8,
            initial_access: CFTypeRef,
            keychain: *mut CFTypeRef,
        ) -> i32;
        #[cfg(test)]
        fn SecKeychainDelete(keychain: CFTypeRef) -> i32;
    }

    struct OwnedCF(CFTypeRef);

    impl Drop for OwnedCF {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // All values passed here follow Core Foundation's Create/Copy rule.
                unsafe { CFRelease(self.0) };
            }
        }
    }

    impl OwnedCF {
        fn string(value: &str) -> Result<Self, ProfileError> {
            let value = unsafe {
                CFStringCreateWithBytes(
                    ptr::null(),
                    value.as_ptr(),
                    value.len() as isize,
                    0x08000100,
                    0,
                )
            };
            if value.is_null() {
                Err(ProfileError::CredentialWrite)
            } else {
                Ok(Self(value))
            }
        }

        fn dictionary() -> Result<Self, ProfileError> {
            // No retain callbacks: keys are framework constants and all owned values
            // outlive the synchronous Security call that consumes this dictionary.
            let value =
                unsafe { CFDictionaryCreateMutable(ptr::null(), 0, ptr::null(), ptr::null()) };
            if value.is_null() {
                Err(ProfileError::CredentialWrite)
            } else {
                Ok(Self(value))
            }
        }

        fn set(&self, key: CFTypeRef, value: CFTypeRef) {
            unsafe { CFDictionarySetValue(self.0.cast_mut(), key, value) };
        }
    }

    fn query(
        id: &str,
        keychain: Option<CFTypeRef>,
        adding: bool,
    ) -> Result<(OwnedCF, OwnedCF, OwnedCF, Option<OwnedCF>), ProfileError> {
        let query = OwnedCF::dictionary()?;
        let service = OwnedCF::string(SERVICE)?;
        let account = OwnedCF::string(id)?;
        unsafe {
            query.set(kSecClass, kSecClassGenericPassword);
            query.set(kSecAttrService, service.0);
            query.set(kSecAttrAccount, account.0);
        }
        let search_list = if let Some(keychain) = keychain {
            if adding {
                unsafe { query.set(kSecUseKeychain, keychain) };
                None
            } else {
                let list =
                    OwnedCF(unsafe { CFArrayCreate(ptr::null(), &keychain, 1, ptr::null()) });
                if list.0.is_null() {
                    return Err(ProfileError::CredentialWrite);
                }
                unsafe { query.set(kSecMatchSearchList, list.0) };
                Some(list)
            }
        } else {
            None
        };
        Ok((query, service, account, search_list))
    }

    pub(super) fn read(id: &str) -> Result<Option<String>, ProfileError> {
        read_from(id, None)
    }

    fn read_from(id: &str, keychain: Option<CFTypeRef>) -> Result<Option<String>, ProfileError> {
        let (query, _service, _account, _search_list) =
            query(id, keychain, false).map_err(|_| ProfileError::CredentialRead)?;
        unsafe {
            query.set(kSecReturnData, kCFBooleanTrue);
            query.set(kSecMatchLimit, kSecMatchLimitOne);
        }
        let mut result = ptr::null();
        let status = unsafe { SecItemCopyMatching(query.0, &mut result) };
        let result = OwnedCF(result);
        if status == ITEM_NOT_FOUND {
            return Ok(None);
        }
        if status != 0 || result.0.is_null() {
            return Err(ProfileError::CredentialRead);
        }
        let length = unsafe { CFDataGetLength(result.0) };
        if length < 0 {
            return Err(ProfileError::CredentialRead);
        }
        if length == 0 {
            return Ok(Some(String::new()));
        }
        let bytes = unsafe { CFDataGetBytePtr(result.0) };
        if bytes.is_null() {
            return Err(ProfileError::CredentialRead);
        }
        let data = unsafe { std::slice::from_raw_parts(bytes, length as usize) };
        String::from_utf8(data.to_vec())
            .map(Some)
            .map_err(|_| ProfileError::CredentialRead)
    }

    pub(super) fn save(id: &str, password: &str) -> Result<(), ProfileError> {
        save_to(id, password, None)
    }

    fn save_to(id: &str, password: &str, keychain: Option<CFTypeRef>) -> Result<(), ProfileError> {
        let (search, _service, _account, _search_list) = query(id, keychain, false)?;
        if password.is_empty() {
            // Preserve a stored empty value distinctly from absence. Recreate it
            // because older Keychains can retain data on a zero-length update.
            let status = unsafe { SecItemDelete(search.0) };
            if status != 0 && status != ITEM_NOT_FOUND {
                return Err(ProfileError::CredentialWrite);
            }
        }
        let attributes = OwnedCF::dictionary()?;
        let data = OwnedCF(unsafe {
            CFDataCreate(ptr::null(), password.as_ptr(), password.len() as isize)
        });
        if data.0.is_null() {
            return Err(ProfileError::CredentialWrite);
        }
        unsafe { attributes.set(kSecValueData, data.0) };
        let mut status = unsafe { SecItemUpdate(search.0, attributes.0) };
        if status == ITEM_NOT_FOUND {
            let (item, _service, _account, _search_list) = query(id, keychain, true)?;
            unsafe {
                item.set(kSecValueData, data.0);
                item.set(
                    kSecAttrAccessible,
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                );
                status = SecItemAdd(item.0, ptr::null_mut());
            }
        }
        if status == 0 {
            Ok(())
        } else {
            Err(ProfileError::CredentialWrite)
        }
    }

    pub(super) fn delete(id: &str) -> Result<(), ProfileError> {
        delete_from(id, None)
    }
    fn delete_from(id: &str, keychain: Option<CFTypeRef>) -> Result<(), ProfileError> {
        let (query, _service, _account, _list) =
            query(id, keychain, false).map_err(|_| ProfileError::CredentialDelete)?;
        match unsafe { SecItemDelete(query.0) } {
            0 | ITEM_NOT_FOUND => Ok(()),
            _ => Err(ProfileError::CredentialDelete),
        }
    }

    #[cfg(test)]
    mod tests {
        use super::{
            CFTypeRef, ITEM_NOT_FOUND, OwnedCF, SecItemDelete, SecKeychainCreate,
            SecKeychainDelete, delete_from, query, read_from, save_to,
        };
        use std::{ffi::CString, fs, path::PathBuf, ptr};

        struct DisposableKeychain {
            handle: OwnedCF,
            directory: PathBuf,
        }

        impl Drop for DisposableKeychain {
            fn drop(&mut self) {
                // This handle always belongs to this test, never the default keychain.
                unsafe { SecKeychainDelete(self.handle.0) };
                _ = fs::remove_dir_all(&self.directory);
            }
        }

        #[test]
        #[ignore = "Requires macOS Keychain access outside the filesystem sandbox; creates only a disposable keychain."]
        fn disposable_keychain_password_roundtrip() {
            let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../build/gpui/keychain-tests")
                .join(crate::connections::unique_id());
            fs::create_dir_all(&directory).expect("Create disposable Keychain directory");
            let path =
                CString::new(directory.join("credentials.keychain-db").to_str().unwrap()).unwrap();
            let password = crate::connections::unique_id();
            let mut handle: CFTypeRef = ptr::null();
            let status = unsafe {
                SecKeychainCreate(
                    path.as_ptr(),
                    password.len() as u32,
                    password.as_ptr().cast(),
                    0,
                    ptr::null(),
                    &mut handle,
                )
            };
            assert_eq!(status, 0, "Create disposable Keychain");
            let keychain = DisposableKeychain {
                handle: OwnedCF(handle),
                directory,
            };
            let target = Some(keychain.handle.0);
            let id = "disposable-profile";
            assert_eq!(read_from(id, target).unwrap(), None);
            assert!(save_to(id, "first-synthetic-password", target).is_ok());
            assert!(
                read_from(id, target)
                    .is_ok_and(|value| value.as_deref() == Some("first-synthetic-password"))
            );
            assert!(save_to(id, "replacement-synthetic-password", target).is_ok());
            assert!(
                read_from(id, target)
                    .is_ok_and(|value| value.as_deref() == Some("replacement-synthetic-password"))
            );
            assert!(save_to(id, "", target).is_ok());
            assert_eq!(read_from(id, target).unwrap().as_deref(), Some(""));
            assert!(delete_from(id, target).is_ok());
            assert_eq!(read_from(id, target).unwrap(), None);
            assert!(save_to(id, "final-synthetic-password", target).is_ok());
            let (query, _service, _account, _list) = query(id, target, false).unwrap();
            assert_eq!(
                unsafe { SecItemDelete(query.0) },
                0,
                "Delete synthetic credential"
            );
            assert_eq!(unsafe { SecItemDelete(query.0) }, ITEM_NOT_FOUND);
            assert_eq!(read_from(id, target).unwrap(), None);
            drop(keychain);
        }
    }
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
mod keychain {
    use super::{CREDENTIAL_SERVICE, ProfileError};
    use keyring::{Entry, Error};
    use std::sync::Mutex;

    // The platform stores do not guarantee ordering across concurrent callers.
    // Keep all prototype credential operations serialized, including reads.
    static STORE_ACCESS: Mutex<()> = Mutex::new(());

    fn entry(service: &str, id: &str) -> keyring::Result<Entry> {
        // Name the actual backend rather than the crate's default builder, so a
        // missing Cargo feature cannot silently select its in-memory mock store.
        #[cfg(target_os = "windows")]
        let credential = keyring::windows::WinCredential::new_with_target(None, service, id)?;
        #[cfg(target_os = "linux")]
        let credential = keyring::secret_service::SsCredential::new_with_target(None, service, id)?;
        Ok(Entry::new_with_credential(Box::new(credential)))
    }

    fn password_result(result: keyring::Result<String>) -> Result<Option<String>, ProfileError> {
        match result {
            Ok(password) => Ok(Some(password)),
            Err(Error::NoEntry) => Ok(None),
            // Platform errors may carry credentials or storage details. Expose
            // only our fixed, actionable message; never format or log the error.
            Err(_) => Err(ProfileError::CredentialRead),
        }
    }

    fn deletion_result(result: keyring::Result<()>) -> Result<(), ProfileError> {
        match result {
            Ok(()) | Err(Error::NoEntry) => Ok(()),
            Err(_) => Err(ProfileError::CredentialDelete),
        }
    }

    pub(super) fn read(id: &str) -> Result<Option<String>, ProfileError> {
        read_for_service(CREDENTIAL_SERVICE, id)
    }

    #[cfg(feature = "native-smoke")]
    pub(super) fn probe_read_for_service(
        service: &str,
        id: &str,
    ) -> Result<Option<String>, ProfileError> {
        let _access = STORE_ACCESS
            .lock()
            .map_err(|_| ProfileError::CredentialRead)?;
        match entry(service, id).and_then(|entry| entry.get_password()) {
            Ok(value) => Ok(Some(value)),
            Err(Error::NoEntry) => Ok(None),
            Err(_) => Err(ProfileError::CredentialRead),
        }
    }

    pub(super) fn read_for_service(
        service: &str,
        id: &str,
    ) -> Result<Option<String>, ProfileError> {
        let _access = STORE_ACCESS
            .lock()
            .map_err(|_| ProfileError::CredentialRead)?;
        password_result(entry(service, id).and_then(|entry| entry.get_password()))
    }

    pub(super) fn save(id: &str, password: &str) -> Result<(), ProfileError> {
        save_for_service(CREDENTIAL_SERVICE, id, password)
    }

    pub(super) fn save_for_service(
        service: &str,
        id: &str,
        password: &str,
    ) -> Result<(), ProfileError> {
        let _access = STORE_ACCESS
            .lock()
            .map_err(|_| ProfileError::CredentialWrite)?;
        let entry = entry(service, id).map_err(|_| ProfileError::CredentialWrite)?;
        entry
            .set_password(password)
            .map_err(|_| ProfileError::CredentialWrite)
    }
    pub(super) fn delete(id: &str) -> Result<(), ProfileError> {
        delete_for_service(CREDENTIAL_SERVICE, id)
    }
    pub(super) fn delete_for_service(service: &str, id: &str) -> Result<(), ProfileError> {
        let _access = STORE_ACCESS
            .lock()
            .map_err(|_| ProfileError::CredentialDelete)?;
        deletion_result(entry(service, id).and_then(|entry| entry.delete_credential()))
    }

    #[cfg(test)]
    mod tests {
        use super::{Error, ProfileError, deletion_result, password_result};

        #[test]
        fn missing_and_empty_credentials_remain_distinct() {
            assert_eq!(password_result(Err(Error::NoEntry)), Ok(None));
            assert_eq!(password_result(Ok(String::new())), Ok(Some(String::new())));
            assert_eq!(deletion_result(Err(Error::NoEntry)), Ok(()));
        }

        #[test]
        fn unavailable_store_does_not_become_an_empty_password() {
            let platform_error = || {
                Error::PlatformFailure(
                    std::io::Error::other("synthetic-secret-must-not-be-displayed").into(),
                )
            };
            let read_error = password_result(Err(platform_error())).unwrap_err();
            assert_eq!(read_error, ProfileError::CredentialRead);
            assert!(!read_error.to_string().contains("synthetic-secret"));
            assert_eq!(
                deletion_result(Err(platform_error())),
                Err(ProfileError::CredentialDelete)
            );
        }

        #[test]
        fn locked_store_does_not_become_an_empty_password() {
            let error = Error::NoStorageAccess(std::io::Error::other("locked").into());
            assert_eq!(
                password_result(Err(error)),
                Err(ProfileError::CredentialRead)
            );
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
mod keychain {
    use super::ProfileError;
    pub(super) fn read(_: &str) -> Result<Option<String>, ProfileError> {
        Err(ProfileError::CredentialRead)
    }
    pub(super) fn save(_: &str, _: &str) -> Result<(), ProfileError> {
        Err(ProfileError::CredentialWrite)
    }
    pub(super) fn delete(_: &str) -> Result<(), ProfileError> {
        Err(ProfileError::CredentialDelete)
    }
}

#[cfg(all(test, feature = "native-smoke"))]
pub(crate) fn synthetic_profile_store(path: PathBuf) -> ProfileStore {
    tests::synthetic_profile_store(path)
}

#[cfg(test)]
mod tests {
    use super::{
        ConnectionProfile, LIBRARY_VERSION, ProfileError, ProfileLibrary, ProfileStore,
        default_profile_path, unique_id,
    };
    use std::{ffi::OsString, fs, path::PathBuf};

    use super::{CredentialStore, LibraryReplacement};
    use std::collections::{HashMap, VecDeque};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct SyntheticCredentials {
        values: Mutex<HashMap<String, String>>,
        // Each fault either fails before mutation or after changing the value.
        faults: Mutex<VecDeque<(&'static str, bool)>>,
        calls: Mutex<Vec<&'static str>>,
    }
    impl SyntheticCredentials {
        fn fault(&self, operation: &'static str) -> Option<bool> {
            self.calls.lock().unwrap().push(operation);
            let mut faults = self.faults.lock().unwrap();
            if faults.front().is_some_and(|(op, _)| *op == operation) {
                faults.pop_front().map(|(_, after)| after)
            } else {
                None
            }
        }
        fn value(&self, id: &str) -> Option<String> {
            self.values.lock().unwrap().get(id).cloned()
        }
    }
    impl CredentialStore for SyntheticCredentials {
        fn read(&self, id: &str) -> Result<Option<String>, ProfileError> {
            if self.fault("read").is_some() {
                return Err(ProfileError::CredentialRead);
            }
            Ok(self.value(id))
        }
        fn save(&self, id: &str, value: &str) -> Result<(), ProfileError> {
            let fault = self.fault("save");
            if fault != Some(false) {
                self.values.lock().unwrap().insert(id.into(), value.into());
            }
            if fault.is_some() {
                Err(ProfileError::CredentialWrite)
            } else {
                Ok(())
            }
        }
        fn delete(&self, id: &str) -> Result<(), ProfileError> {
            let fault = self.fault("delete");
            if fault != Some(false) {
                self.values.lock().unwrap().remove(id);
            }
            if fault.is_some() {
                Err(ProfileError::CredentialDelete)
            } else {
                Ok(())
            }
        }
    }
    #[cfg(feature = "native-smoke")]
    pub(super) fn synthetic_profile_store(path: PathBuf) -> ProfileStore {
        let mut store = ProfileStore::new(path);
        store.credentials = Arc::new(SyntheticCredentials::default());
        store
    }

    #[derive(Default)]
    struct ReplacementFault(AtomicBool);
    impl LibraryReplacement for ReplacementFault {
        fn replace(&self, prepared: crate::files::PreparedSave) -> Result<(), ProfileError> {
            if self.0.load(Ordering::SeqCst) {
                return Err(ProfileError::Write);
            }
            prepared
                .publish()
                .map(|_| ())
                .map_err(|_| ProfileError::Write)
        }
    }

    struct TestStore {
        store: ProfileStore,
        directory: PathBuf,
    }

    impl TestStore {
        fn new() -> Self {
            let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../build/gpui/profile-tests")
                .join(unique_id());
            Self {
                store: ProfileStore::new(directory.join("connections.json")),
                directory,
            }
        }
    }

    impl Drop for TestStore {
        fn drop(&mut self) {
            _ = fs::remove_dir_all(&self.directory);
        }
    }

    #[test]
    fn transfer_batch_is_atomic_merges_additions_preserves_selection_and_never_accesses_credentials()
     {
        let mut test = TestStore::new();
        let credentials = Arc::new(SyntheticCredentials::default());
        test.store.credentials = credentials.clone();
        let existing = ConnectionProfile::new();
        credentials
            .values
            .lock()
            .unwrap()
            .insert(existing.id.clone(), "original-secret".into());
        test.store.save(std::slice::from_ref(&existing)).unwrap();
        let expected = test.store.load().unwrap();
        let mut added = ConnectionProfile::new();
        added.name = "Added while reviewing".into();
        test.store.upsert(&added, None).unwrap();
        test.store
            .selection(Some(&crate::model::ProfileId::saved(&added)))
            .commit()
            .unwrap();
        let bytes = crate::transfer::encode(std::slice::from_ref(&existing)).unwrap();
        let rows = crate::transfer::preview(&bytes).unwrap();
        let imported = test.store.import_profiles(&expected, &rows).unwrap();
        assert_eq!(imported.len(), 1);
        assert_ne!(imported[0].id, existing.id);
        assert_ne!(imported[0].id, rows[0].profile.id);
        let library = test.store.load_library().unwrap();
        assert_eq!(
            library.connections,
            vec![existing.clone(), added.clone(), imported[0].clone()]
        );
        assert_eq!(library.selected_profile_id, Some(added.id));
        assert_eq!(
            credentials.value(&existing.id).as_deref(),
            Some("original-secret")
        );
        assert!(credentials.calls.lock().unwrap().is_empty());
    }

    #[test]
    fn transfer_stale_preview_missing_ca_empty_selection_and_failed_replace_leave_library_unchanged()
     {
        let mut test = TestStore::new();
        let credentials = Arc::new(SyntheticCredentials::default());
        test.store.credentials = credentials.clone();
        let existing = ConnectionProfile::new();
        test.store.save(std::slice::from_ref(&existing)).unwrap();
        let expected = test.store.load().unwrap();
        let mut rows = crate::transfer::preview(
            &crate::transfer::encode(&[existing.clone(), existing.clone()]).unwrap(),
        )
        .unwrap();
        let original = fs::read(&test.store.path).unwrap();
        rows[1].profile.ssl_root_cert = Some(
            test.directory
                .join("missing-ca.pem")
                .to_str()
                .unwrap()
                .into(),
        );
        assert!(test.store.import_profiles(&expected, &rows).is_err());
        assert_eq!(fs::read(&test.store.path).unwrap(), original);
        rows[1].selected = false;
        let failure = Arc::new(ReplacementFault(AtomicBool::new(true)));
        test.store.replacement = failure.clone();
        assert_eq!(
            test.store.import_profiles(&expected, &rows),
            Err(ProfileError::Write)
        );
        assert_eq!(fs::read(&test.store.path).unwrap(), original);
        failure.0.store(false, Ordering::SeqCst);
        rows[0].selected = false;
        assert!(test.store.import_profiles(&expected, &rows).is_err());
        assert_eq!(fs::read(&test.store.path).unwrap(), original);
        rows[0].selected = true;
        let mut changed = existing;
        changed.host = "changed.example.test".into();
        test.store.upsert(&changed, None).unwrap();
        let current = fs::read(&test.store.path).unwrap();
        assert_eq!(
            test.store.import_profiles(&expected, &rows),
            Err(ProfileError::Conflict)
        );
        assert_eq!(fs::read(&test.store.path).unwrap(), current);
        assert!(credentials.calls.lock().unwrap().is_empty());
        assert!(!fs::read_dir(&test.directory).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".tmp")
        }));
    }

    #[test]
    fn profiles_roundtrip_without_credentials() {
        let test = TestStore::new();
        assert!(test.store.load().unwrap().is_empty());
        let pg = ConnectionProfile::new();
        let mut mysql = ConnectionProfile::new();
        mysql.engine = "mysql".into();
        mysql.port = 3306;
        mysql.user = "root".into();
        mysql.environment = "staging".into();
        let profiles = vec![pg, mysql];
        test.store.save(&profiles).unwrap();
        assert_eq!(test.store.load().unwrap(), profiles);
        let json = fs::read_to_string(&test.store.path).unwrap();
        assert!(!json.contains("password"));
        assert!(!json.contains("privateKey"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&test.store.path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn upsert_without_password_preserves_other_profiles() {
        let test = TestStore::new();
        let mut first = ConnectionProfile::new();
        let second = ConnectionProfile::new();
        test.store.save(&[first.clone(), second.clone()]).unwrap();
        first.name = "Updated profile".into();
        test.store.upsert(&first, None).unwrap();
        assert_eq!(test.store.load().unwrap(), vec![first, second]);
    }

    #[test]
    fn replacement_is_atomic_and_removes_prepared_files() {
        let test = TestStore::new();
        let first = ConnectionProfile::new();
        test.store.save(std::slice::from_ref(&first)).unwrap();
        let mut replacement = first;
        replacement.name = "Replaced connection".into();
        let prepared = test
            .store
            .prepare(std::slice::from_ref(&replacement))
            .unwrap();
        let temporary = prepared.prepared.temporary_path().to_owned();
        assert_ne!(test.store.load().unwrap()[0].name, replacement.name);
        prepared.commit().unwrap();
        assert_eq!(test.store.load().unwrap(), vec![replacement]);
        assert!(!temporary.exists());
        let files = fs::read_dir(&test.directory)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect::<std::collections::HashSet<_>>();
        assert_eq!(
            files,
            [
                OsString::from("connections.json"),
                OsString::from(".workspace.lock")
            ]
            .into_iter()
            .collect()
        );
    }

    #[test]
    fn prepared_profile_write_holds_directory_ownership_until_commit() {
        let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/profile-tests")
            .join(unique_id());
        let store = ProfileStore::new(directory.join("connections.json"));
        let prepared = store.prepare(&[]).unwrap();
        drop(store);
        assert!(crate::instance::DataDirectory::acquire(&directory).is_err());
        prepared.commit().unwrap();
        drop(crate::instance::DataDirectory::acquire(&directory).unwrap());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn profile_directory_requires_an_absolute_user_directory() {
        assert_eq!(default_profile_path(|_| None), Err(ProfileError::Read));
        assert_eq!(
            default_profile_path(|_| Some(OsString::from("relative-user-directory"))),
            Err(ProfileError::Read),
        );
    }

    #[test]
    fn certificate_path_validation_uses_native_absolute_paths() {
        let test = TestStore::new();
        let mut profile = ConnectionProfile::new();
        profile.ssl_root_cert = Some(
            test.directory
                .join("root.pem")
                .to_string_lossy()
                .into_owned(),
        );
        assert_eq!(profile.validate(), Ok(()));
        profile.ssl_root_cert = Some("relative-root.pem".into());
        assert_eq!(profile.validate(), Err(ProfileError::Invalid));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_profile_location_preserves_existing_library() {
        let path =
            default_profile_path(|key| (key == "HOME").then(|| "/Users/profile-owner".into()))
                .unwrap();
        assert_eq!(
            path,
            PathBuf::from(
                "/Users/profile-owner/Library/Application Support/DBeerGPUI/connections.json"
            )
        );
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn windows_profile_location_uses_local_app_data() {
        let path = default_profile_path(|key| match key {
            "LOCALAPPDATA" => Some(r"C:\Users\profile-owner\AppData\Local".into()),
            "APPDATA" => Some(r"C:\Users\profile-owner\AppData\Roaming".into()),
            _ => None,
        })
        .unwrap();
        assert_eq!(
            path,
            PathBuf::from(r"C:\Users\profile-owner\AppData\Local\DBeerGPUI\connections.json")
        );
        assert_eq!(
            default_profile_path(
                |key| (key == "LOCALAPPDATA").then(|| r"\not-drive-qualified".into())
            ),
            Err(ProfileError::Read)
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_profile_location_honors_xdg_and_ignores_relative_values() {
        let path = |xdg: Option<&str>, home: Option<&str>| {
            default_profile_path(|key| match key {
                "XDG_CONFIG_HOME" => xdg.map(OsString::from),
                "HOME" => home.map(OsString::from),
                _ => None,
            })
        };
        assert_eq!(
            path(Some("/custom/config"), Some("/home/profile-owner")).unwrap(),
            PathBuf::from("/custom/config/dbeer-gpui/connections.json")
        );
        assert_eq!(
            path(None, Some("/home/profile-owner")).unwrap(),
            PathBuf::from("/home/profile-owner/.config/dbeer-gpui/connections.json")
        );
        assert_eq!(
            path(Some("relative-config"), Some("/home/profile-owner")).unwrap(),
            PathBuf::from("/home/profile-owner/.config/dbeer-gpui/connections.json")
        );
        assert_eq!(
            path(Some(""), Some("/home/profile-owner")).unwrap(),
            PathBuf::from("/home/profile-owner/.config/dbeer-gpui/connections.json")
        );
        assert_eq!(
            path(Some("/custom/config"), None).unwrap(),
            PathBuf::from("/custom/config/dbeer-gpui/connections.json")
        );
    }

    #[test]
    fn malformed_library_is_preserved_when_editing() {
        let test = TestStore::new();
        fs::create_dir_all(&test.directory).unwrap();
        let original = b"{invalid library";
        fs::write(&test.store.path, original).unwrap();
        assert_eq!(test.store.load().err(), Some(ProfileError::Read));
        assert_eq!(
            test.store.upsert(&ConnectionProfile::new(), None),
            Err(ProfileError::Read)
        );
        assert_eq!(fs::read(&test.store.path).unwrap(), original);
    }

    #[test]
    fn invalid_profiles_cannot_replace_saved_profiles() {
        let test = TestStore::new();
        let profile = ConnectionProfile::new();
        test.store.save(std::slice::from_ref(&profile)).unwrap();
        assert_eq!(
            test.store.save(&[profile.clone(), profile.clone()]),
            Err(ProfileError::Invalid)
        );
        let mut invalid = profile.clone();
        invalid.engine = "mysql".into();
        invalid.ssl_mode = "prefer".into();
        assert_eq!(test.store.save(&[invalid]), Err(ProfileError::Invalid));
        assert_eq!(test.store.load().unwrap(), vec![profile]);
    }

    #[test]
    fn json_rejects_embedded_credentials_and_unknown_version() {
        let test = TestStore::new();
        let mut json = serde_json::to_value(ProfileLibrary {
            version: LIBRARY_VERSION,
            connections: vec![ConnectionProfile::new()],
            selected_profile_id: None,
        })
        .unwrap();
        fs::create_dir_all(&test.directory).unwrap();
        json["connections"][0]["password"] = "must-not-load".into();
        fs::write(&test.store.path, serde_json::to_vec(&json).unwrap()).unwrap();
        assert_eq!(test.store.load().err(), Some(ProfileError::Read));
        json["connections"][0]
            .as_object_mut()
            .unwrap()
            .remove("password");
        json["version"] = 99.into();
        fs::write(&test.store.path, serde_json::to_vec(&json).unwrap()).unwrap();
        assert_eq!(test.store.load().err(), Some(ProfileError::Read));
    }

    #[test]
    fn profile_defaults_to_readonly_when_omitted() {
        let mut json = serde_json::to_value(ConnectionProfile::new()).unwrap();
        json.as_object_mut().unwrap().remove("readonly");
        json.as_object_mut().unwrap().remove("environment");
        let profile: ConnectionProfile = serde_json::from_value(json).unwrap();
        assert!(profile.readonly);
        assert_eq!(profile.environment, "development");
    }
    const LEGACY_LIBRARY: &[u8] = include_bytes!("../fixtures/profile-library-v1.json");

    fn synthetic_store() -> (TestStore, Arc<SyntheticCredentials>, Arc<ReplacementFault>) {
        let mut test = TestStore::new();
        let credentials = Arc::new(SyntheticCredentials::default());
        let replacement = Arc::new(ReplacementFault::default());
        test.store.credentials = credentials.clone();
        test.store.replacement = replacement.clone();
        (test, credentials, replacement)
    }

    #[test]
    fn v1_migration_backs_up_exact_bytes_and_preserves_ids_and_policy() {
        let (test, credentials, _) = synthetic_store();
        let original = [b"  \r\n".as_slice(), LEGACY_LIBRARY, b"\r\n\t"].concat();
        fs::write(&test.store.path, &original).unwrap();
        let library = test.store.load_library().unwrap();
        assert_eq!(library.version, LIBRARY_VERSION);
        assert_eq!(library.selected_profile_id.as_deref(), Some("demo-brewery"));
        assert_eq!(library.connections[0].id, "demo-brewery");
        assert!(library.connections[0].readonly);
        assert_eq!(library.connections[0].environment, "development");
        assert!(!library.connections[1].readonly);
        assert_eq!(library.connections[1].environment, "production");
        assert_eq!(
            fs::read(test.store.path.with_extension("json.v1.backup")).unwrap(),
            original
        );
        assert!(credentials.calls.lock().unwrap().is_empty());
        assert_eq!(test.store.load_library().unwrap(), library);
        assert_eq!(fs::read_dir(&test.directory).unwrap().count(), 3);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for path in [
                &test.store.path,
                &test.store.path.with_extension("json.v1.backup"),
            ] {
                assert_eq!(
                    fs::metadata(path).unwrap().permissions().mode() & 0o777,
                    0o600
                );
            }
        }
    }

    #[test]
    fn migration_failure_keeps_original_and_never_overwrites_an_existing_backup() {
        let (test, _, replacement) = synthetic_store();
        let backup = test.store.path.with_extension("json.v1.backup");
        fs::write(&backup, b"previous exact backup").unwrap();
        fs::write(&test.store.path, LEGACY_LIBRARY).unwrap();
        replacement.0.store(true, Ordering::SeqCst);
        assert_eq!(test.store.load_library(), Err(ProfileError::Write));
        assert_eq!(fs::read(&test.store.path).unwrap(), LEGACY_LIBRARY);
        assert_eq!(fs::read(backup).unwrap(), b"previous exact backup");
        assert!(fs::read_dir(&test.directory).unwrap().any(|entry| {
            let entry = entry.unwrap();
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("connections.json.v1-")
                && fs::read(entry.path()).unwrap() == LEGACY_LIBRARY
        }));
    }

    #[test]
    fn actual_legacy_migration_protects_exact_backup_before_first_byte() {
        use crate::files::test_support::{Stage, with_preparation_hook};
        use std::sync::atomic::AtomicUsize;
        let (test, credentials, _) = synthetic_store();
        let original = [b" \r\n".as_slice(), LEGACY_LIBRARY, b"\r\n\t"].concat();
        #[cfg(windows)]
        let private = {
            use crate::files::test_support::windows;
            use std::io::Write;
            windows::set_broad_inheritance(&test.directory);
            let mut source = windows::create_private(&test.store.path).unwrap();
            source.write_all(&original).unwrap();
            source.sync_all().unwrap();
            let descriptor = windows::descriptor(&source);
            assert!(descriptor.starts_with("D:P(A;;FA;;;"));
            assert_eq!(descriptor.matches("(A;").count(), 1);
            descriptor
        };
        #[cfg(not(windows))]
        fs::write(&test.store.path, &original).unwrap();
        let backup = test.store.path.with_extension("json.v1.backup");
        let target = fs::canonicalize(backup.parent().unwrap())
            .unwrap()
            .join(backup.file_name().unwrap());
        let expected = original.clone();
        let seen = Arc::new(AtomicUsize::new(0));
        let observed = seen.clone();
        #[cfg(windows)]
        let expected_private = private.clone();
        let migrated = with_preparation_hook(
            move |stage, path, temporary, retained| {
                if path != target {
                    return Ok(());
                }
                #[cfg(windows)]
                assert_eq!(
                    crate::files::test_support::windows::descriptor(retained),
                    expected_private
                );
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    assert_eq!(retained.metadata()?.permissions().mode() & 0o777, 0o600);
                }
                match stage {
                    Stage::BeforeWrite => assert_eq!(retained.metadata()?.len(), 0),
                    Stage::BeforeSync => assert_eq!(fs::read(temporary)?, expected),
                }
                observed.fetch_add(1, Ordering::SeqCst);
                Ok(())
            },
            || test.store.load_library(),
        )
        .unwrap();
        assert_eq!(seen.load(Ordering::SeqCst), 2);
        assert_eq!(fs::read(&backup).unwrap(), original);
        assert_eq!(migrated.connections[0].id, "demo-brewery");
        assert_eq!(
            migrated.selected_profile_id.as_deref(),
            Some("demo-brewery")
        );
        assert!(credentials.calls.lock().unwrap().is_empty());
        assert_eq!(test.store.load_library().unwrap(), migrated);
        assert!(credentials.calls.lock().unwrap().is_empty());
        #[cfg(windows)]
        for path in [backup, test.store.path.clone()] {
            assert_eq!(
                crate::files::test_support::windows::descriptor(&fs::File::open(path).unwrap()),
                private
            );
        }
    }

    #[test]
    fn actual_legacy_backup_write_sync_faults_preserve_foreign_identity_and_credentials() {
        use crate::files::test_support::{Stage, with_preparation_hook};
        for stage in [Stage::BeforeWrite, Stage::BeforeSync] {
            for replace in [false, true] {
                let (test, credentials, _) = synthetic_store();
                let original = [b" \r\n".as_slice(), LEGACY_LIBRARY, b"\r\n\t"].concat();
                fs::write(&test.store.path, &original).unwrap();
                credentials.values.lock().unwrap().insert(
                    "synthetic-unrelated-profile".into(),
                    "synthetic-preserved".into(),
                );
                let credential_values = credentials.values.lock().unwrap().clone();
                let backup = test.store.path.with_extension("json.v1.backup");
                let target = fs::canonicalize(backup.parent().unwrap())
                    .unwrap()
                    .join(backup.file_name().unwrap());
                let moved = test.directory.join("retained-backup-stage");
                let retained_path = moved.clone();
                let evidence = Arc::new(Mutex::new(None));
                let observed = evidence.clone();
                let result = with_preparation_hook(
                    move |current, path, temporary, _| {
                        if path == target && current == stage {
                            if replace {
                                fs::rename(temporary, &retained_path)?;
                                fs::write(temporary, b"foreign profile backup staging")?;
                                *observed.lock().unwrap() = Some((
                                    temporary.to_path_buf(),
                                    crate::files::open(temporary).unwrap().binding,
                                ));
                            }
                            return Err(std::io::Error::other("synthetic backup stage fault"));
                        }
                        Ok(())
                    },
                    || test.store.load_library(),
                );
                assert_eq!(result, Err(ProfileError::Write));
                assert_eq!(fs::read(&test.store.path).unwrap(), original);
                assert!(!backup.exists());
                assert_eq!(*credentials.values.lock().unwrap(), credential_values);
                assert!(credentials.calls.lock().unwrap().is_empty());
                if replace {
                    let evidence = evidence.lock().unwrap();
                    let (path, binding) = evidence.as_ref().unwrap();
                    assert!(&crate::files::open(path).unwrap().binding == binding);
                    assert_eq!(
                        fs::read(&moved).unwrap(),
                        if stage == Stage::BeforeWrite {
                            &[]
                        } else {
                            original.as_slice()
                        }
                    );
                } else {
                    assert!(
                        !fs::read_dir(&test.directory)
                            .unwrap()
                            .flatten()
                            .any(|entry| { entry.file_name().to_string_lossy().ends_with(".tmp") })
                    );
                }
                let migrated = test.store.load_library().unwrap();
                assert_eq!(migrated.connections[0].id, "demo-brewery");
                assert_eq!(fs::read(backup).unwrap(), original);
                assert_eq!(*credentials.values.lock().unwrap(), credential_values);
                assert!(credentials.calls.lock().unwrap().is_empty());
                if let Some((path, binding)) = evidence.lock().unwrap().as_ref() {
                    assert!(&crate::files::open(path).unwrap().binding == binding);
                }
            }
        }
    }

    #[test]
    fn actual_legacy_backup_refuses_late_foreign_destination_and_retries_without_overwrite() {
        use crate::files::test_support::{Stage, with_preparation_hook};
        let (test, credentials, _) = synthetic_store();
        fs::write(&test.store.path, LEGACY_LIBRARY).unwrap();
        let backup = test.store.path.with_extension("json.v1.backup");
        let target = fs::canonicalize(backup.parent().unwrap())
            .unwrap()
            .join(backup.file_name().unwrap());
        let evidence = Arc::new(Mutex::new(None));
        let observed = evidence.clone();
        let result = with_preparation_hook(
            move |stage, path, _, _| {
                if path == target && stage == Stage::BeforeWrite {
                    fs::write(path, b"late foreign profile backup")?;
                    *observed.lock().unwrap() = Some(crate::files::open(path).unwrap().binding);
                }
                Ok(())
            },
            || test.store.load_library(),
        );
        assert_eq!(result, Err(ProfileError::Write));
        assert_eq!(fs::read(&test.store.path).unwrap(), LEGACY_LIBRARY);
        assert!(Some(crate::files::open(&backup).unwrap().binding) == *evidence.lock().unwrap());
        assert!(credentials.calls.lock().unwrap().is_empty());
        assert_eq!(test.store.load_library().unwrap().version, LIBRARY_VERSION);
        assert!(Some(crate::files::open(&backup).unwrap().binding) == *evidence.lock().unwrap());
        assert!(credentials.calls.lock().unwrap().is_empty());
    }

    fn assert_legacy_primary_changes_during_successful_backup_are_refused(replace: bool) {
        use crate::files::test_support::{Stage, with_preparation_hook};
        use std::sync::atomic::AtomicUsize;
        let original = [b" \r\n".as_slice(), LEGACY_LIBRARY, b"\r\n\t"].concat();
        let mut legacy: serde_json::Value = serde_json::from_slice(LEGACY_LIBRARY).unwrap();
        legacy["connections"][0]["name"] = "Externally edited legacy profile".into();
        let mut foreign_profile = ConnectionProfile::new();
        foreign_profile.id = "external-current-profile".into();
        foreign_profile.name = "Externally selected profile".into();
        foreign_profile.readonly = true;
        foreign_profile.environment = "production".into();
        let current = ProfileLibrary {
            version: LIBRARY_VERSION,
            connections: vec![foreign_profile.clone()],
            selected_profile_id: Some(foreign_profile.id),
        };
        let mut future = serde_json::to_value(&current).unwrap();
        future["version"] = 99.into();
        let mut replacements = vec![
            serde_json::to_vec(&legacy).unwrap(),
            serde_json::to_vec(&current).unwrap(),
            serde_json::to_vec(&future).unwrap(),
            b"{synthetic corrupt profile library\r\n".to_vec(),
        ];
        if replace {
            // Exact bytes alone cannot authorize a different file identity.
            replacements.push(original.clone());
        }
        for stage in [Stage::BeforeWrite, Stage::BeforeSync] {
            for foreign in &replacements {
                let (test, credentials, _) = synthetic_store();
                fs::write(&test.store.path, &original).unwrap();
                credentials.values.lock().unwrap().insert(
                    "synthetic-unrelated-profile".into(),
                    "synthetic-preserved".into(),
                );
                let credential_values = credentials.values.lock().unwrap().clone();
                let backup = test.store.path.with_extension("json.v1.backup");
                let target = fs::canonicalize(backup.parent().unwrap())
                    .unwrap()
                    .join(backup.file_name().unwrap());
                let primary = test.store.path.clone();
                let moved = test.directory.join("retained-legacy-primary");
                let retained_primary = moved.clone();
                let foreign_bytes = foreign.clone();
                let evidence = Arc::new(Mutex::new(None));
                let observed = evidence.clone();
                let seen = Arc::new(AtomicUsize::new(0));
                let observed_count = seen.clone();
                let result = with_preparation_hook(
                    move |current_stage, path, _, _| {
                        if path == target && current_stage == stage {
                            if replace {
                                fs::rename(&primary, &retained_primary)?;
                            }
                            fs::write(&primary, &foreign_bytes)?;
                            *observed.lock().unwrap() =
                                Some(crate::files::open(&primary).unwrap().binding);
                            observed_count.fetch_add(1, Ordering::SeqCst);
                        }
                        // The exact old backup must finish successfully.
                        Ok(())
                    },
                    || test.store.load_library(),
                );
                assert!(matches!(
                    result,
                    Err(ProfileError::Conflict | ProfileError::Write)
                ));
                assert_eq!(seen.load(Ordering::SeqCst), 1);
                assert_eq!(fs::read(&test.store.path).unwrap(), *foreign);
                assert!(
                    Some(crate::files::open(&test.store.path).unwrap().binding)
                        == *evidence.lock().unwrap()
                );
                assert_eq!(fs::read(&backup).unwrap(), original);
                let confirmed_backup = crate::files::open(&backup).unwrap().binding;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    assert_eq!(
                        fs::metadata(&backup).unwrap().permissions().mode() & 0o777,
                        0o600
                    );
                }
                if replace {
                    assert_eq!(fs::read(&moved).unwrap(), original);
                }
                assert_eq!(*credentials.values.lock().unwrap(), credential_values);
                assert!(credentials.calls.lock().unwrap().is_empty());
                // Only an explicit restoration authorizes a new migration.
                fs::write(&test.store.path, &original).unwrap();
                let migrated = test.store.load_library().unwrap();
                let expected: super::PrototypeLibrary =
                    serde_json::from_slice(LEGACY_LIBRARY).unwrap();
                assert_eq!(migrated.connections, expected.connections);
                assert_eq!(migrated.version, LIBRARY_VERSION);
                assert_eq!(
                    migrated.selected_profile_id.as_deref(),
                    Some("demo-brewery")
                );
                assert!(credentials.calls.lock().unwrap().is_empty());
                assert!(crate::files::open(&backup).unwrap().binding == confirmed_backup);
                assert!(
                    fs::read_dir(&test.directory)
                        .unwrap()
                        .flatten()
                        .any(|entry| {
                            entry
                                .file_name()
                                .to_string_lossy()
                                .starts_with("connections.json.v1-")
                                && fs::read(entry.path()).unwrap() == original
                        })
                );
                let mut restarted =
                    ProfileStore::with_owner(test.store.data_owner(), "connections.json");
                restarted.credentials = credentials.clone();
                assert_eq!(restarted.load_library().unwrap(), migrated);
                assert_eq!(*credentials.values.lock().unwrap(), credential_values);
                assert!(credentials.calls.lock().unwrap().is_empty());
            }
        }
    }

    #[test]
    fn actual_legacy_migration_refuses_in_place_primary_changes_during_successful_backup() {
        assert_legacy_primary_changes_during_successful_backup_are_refused(false);
    }

    #[test]
    fn actual_legacy_migration_refuses_replaced_primary_identity_during_successful_backup() {
        assert_legacy_primary_changes_during_successful_backup_are_refused(true);
    }

    #[cfg(unix)]
    #[test]
    fn actual_legacy_migration_refuses_replaced_parent_and_preserves_foreign_primary() {
        use crate::files::test_support::{Stage, with_preparation_hook};
        let (test, credentials, _) = synthetic_store();
        fs::write(&test.store.path, LEGACY_LIBRARY).unwrap();
        let original_directory = test.directory.with_extension("retained-parent");
        let backup = test.store.path.with_extension("json.v1.backup");
        let target = fs::canonicalize(&test.directory)
            .unwrap()
            .join(backup.file_name().unwrap());
        let primary = test.store.path.clone();
        let directory = test.directory.clone();
        let retained_directory = original_directory.clone();
        let evidence = Arc::new(Mutex::new(None));
        let observed = evidence.clone();
        let result = with_preparation_hook(
            move |stage, path, _, _| {
                if path == target && stage == Stage::BeforeSync {
                    fs::rename(&directory, &retained_directory)?;
                    fs::create_dir(&directory)?;
                    // The same primary bytes in a new parent grant no authority.
                    fs::write(&primary, LEGACY_LIBRARY)?;
                    *observed.lock().unwrap() = Some(crate::files::open(&primary).unwrap().binding);
                }
                Ok(())
            },
            || test.store.load_library(),
        );
        assert_eq!(result, Err(ProfileError::Write));
        assert_eq!(fs::read(&test.store.path).unwrap(), LEGACY_LIBRARY);
        assert!(
            Some(crate::files::open(&test.store.path).unwrap().binding)
                == *evidence.lock().unwrap()
        );
        assert_eq!(
            fs::read(original_directory.join("connections.json")).unwrap(),
            LEGACY_LIBRARY
        );
        assert!(!backup.exists());
        assert!(credentials.calls.lock().unwrap().is_empty());
        // Both directories are disposable fixtures owned only by this test.
        fs::remove_dir_all(&original_directory).unwrap();
    }

    #[test]
    fn metadata_failure_restores_exact_missing_empty_and_nonempty_credentials() {
        for previous in [None, Some(""), Some("synthetic-previous")] {
            let (test, credentials, replacement) = synthetic_store();
            let profile = ConnectionProfile::new();
            let other = ConnectionProfile::new();
            test.store.save(&[profile.clone(), other.clone()]).unwrap();
            if let Some(value) = previous {
                credentials
                    .values
                    .lock()
                    .unwrap()
                    .insert(profile.id.clone(), value.into());
            }
            credentials
                .values
                .lock()
                .unwrap()
                .insert(other.id.clone(), "synthetic-unrelated".into());
            let original = fs::read(&test.store.path).unwrap();
            replacement.0.store(true, Ordering::SeqCst);
            let mut edited = profile.clone();
            edited.name = "Updated".into();
            assert_eq!(
                test.store
                    .update(&edited, Some("synthetic-new"), Some(&profile), true),
                Err(ProfileError::Write)
            );
            assert_eq!(credentials.value(&profile.id).as_deref(), previous);
            assert_eq!(
                credentials.value(&other.id).as_deref(),
                Some("synthetic-unrelated")
            );
            assert_eq!(fs::read(&test.store.path).unwrap(), original);
        }
    }

    #[test]
    fn deletion_failure_restores_profile_selection_and_exact_credential() {
        for previous in [None, Some(""), Some("synthetic-previous")] {
            let (test, credentials, replacement) = synthetic_store();
            let profile = ConnectionProfile::new();
            let other = ConnectionProfile::new();
            test.store.save(&[profile.clone(), other.clone()]).unwrap();
            test.store
                .selection(Some(&crate::model::ProfileId::saved(&profile)))
                .commit()
                .unwrap();
            if let Some(value) = previous {
                credentials
                    .values
                    .lock()
                    .unwrap()
                    .insert(profile.id.clone(), value.into());
            }
            let original = fs::read(&test.store.path).unwrap();
            replacement.0.store(true, Ordering::SeqCst);
            assert_eq!(test.store.delete(&profile), Err(ProfileError::Write));
            assert_eq!(credentials.value(&profile.id).as_deref(), previous);
            assert_eq!(fs::read(&test.store.path).unwrap(), original);
            replacement.0.store(false, Ordering::SeqCst);
            let library = test.store.delete(&profile).unwrap();
            assert_eq!(library.connections, vec![other.clone()]);
            assert_eq!(
                library.selected_profile_id.as_deref(),
                Some(other.id.as_str())
            );
            assert_eq!(credentials.value(&profile.id), None);
        }
    }

    #[test]
    fn credential_read_write_delete_and_partial_mutation_failures_do_not_commit_metadata() {
        for operation in ["read", "save", "delete"] {
            for after in [false, true] {
                let (test, credentials, _) = synthetic_store();
                let profile = ConnectionProfile::new();
                test.store.save(std::slice::from_ref(&profile)).unwrap();
                credentials
                    .values
                    .lock()
                    .unwrap()
                    .insert(profile.id.clone(), "synthetic-original".into());
                credentials
                    .faults
                    .lock()
                    .unwrap()
                    .push_back((operation, after));
                let original = fs::read(&test.store.path).unwrap();
                let outcome = if operation == "delete" {
                    test.store.delete(&profile).map(|_| ())
                } else {
                    test.store.upsert(&profile, Some("synthetic-new"))
                };
                let error = match operation {
                    "read" => ProfileError::CredentialRead,
                    "save" => ProfileError::CredentialWrite,
                    _ => ProfileError::CredentialDelete,
                };
                assert_eq!(outcome, Err(error));
                assert_eq!(
                    credentials.value(&profile.id).as_deref(),
                    Some("synthetic-original")
                );
                assert_eq!(fs::read(&test.store.path).unwrap(), original);
            }
        }
    }

    #[test]
    fn rollback_failure_is_explicit_for_update_and_delete() {
        for deleting in [false, true] {
            let (test, credentials, replacement) = synthetic_store();
            let profile = ConnectionProfile::new();
            test.store.save(std::slice::from_ref(&profile)).unwrap();
            credentials
                .values
                .lock()
                .unwrap()
                .insert(profile.id.clone(), "synthetic-original".into());
            replacement.0.store(true, Ordering::SeqCst);
            struct ArmRollback {
                inner: Arc<ReplacementFault>,
                credentials: Arc<SyntheticCredentials>,
            }
            impl LibraryReplacement for ArmRollback {
                fn replace(
                    &self,
                    prepared: crate::files::PreparedSave,
                ) -> Result<(), ProfileError> {
                    *self.credentials.faults.lock().unwrap() = [("save", false)].into();
                    self.inner.replace(prepared)
                }
            }
            let mut store = test.store.clone();
            store.replacement = Arc::new(ArmRollback {
                inner: replacement,
                credentials: credentials.clone(),
            });
            let original = fs::read(&store.path).unwrap();
            let outcome = if deleting {
                store.delete(&profile).map(|_| ())
            } else {
                store.upsert(&profile, Some("synthetic-new"))
            };
            assert_eq!(outcome, Err(ProfileError::CredentialRollback));
            assert_eq!(fs::read(&store.path).unwrap(), original);
            assert_eq!(
                credentials.value(&profile.id).as_deref(),
                if deleting {
                    None
                } else {
                    Some("synthetic-new")
                }
            );
            let message = outcome.unwrap_err().to_string();
            assert!(!message.contains("synthetic"));
        }
    }

    #[test]
    fn nonreplacement_edits_never_access_the_credential_store_and_stale_edits_conflict() {
        let (test, credentials, _) = synthetic_store();
        let profile = ConnectionProfile::new();
        test.store.save(std::slice::from_ref(&profile)).unwrap();
        credentials
            .faults
            .lock()
            .unwrap()
            .push_back(("read", false));
        let mut edited = profile.clone();
        edited.name = "Current".into();
        test.store
            .update(&edited, None, Some(&profile), true)
            .unwrap();
        let mut stale = profile.clone();
        stale.name = "Stale".into();
        assert_eq!(
            test.store
                .update(&stale, Some("synthetic-new"), Some(&profile), true),
            Err(ProfileError::Conflict)
        );
        assert_eq!(test.store.load().unwrap(), vec![edited]);
        assert!(credentials.calls.lock().unwrap().is_empty());
    }

    #[test]
    fn selection_is_stable_across_reordering_and_late_requests_cannot_overwrite_it() {
        let test = TestStore::new();
        let first = ConnectionProfile::new();
        let second = ConnectionProfile::new();
        test.store.save(&[first.clone(), second.clone()]).unwrap();
        let stale = test
            .store
            .selection(Some(&crate::model::ProfileId::saved(&first)));
        let latest = test
            .store
            .selection(Some(&crate::model::ProfileId::saved(&second)));
        latest.commit().unwrap();
        stale.commit().unwrap();
        test.store.save(&[second.clone(), first]).unwrap();
        assert_eq!(
            test.store
                .load_library()
                .unwrap()
                .selected_profile_id
                .as_deref(),
            Some(second.id.as_str())
        );
        test.store.selection(None).commit().unwrap();
        assert_eq!(test.store.load_library().unwrap().selected_profile_id, None);
    }

    #[test]
    fn concurrent_mutations_merge_latest_metadata_and_prepared_stale_writes_are_refused() {
        let (test, credentials, _) = synthetic_store();
        std::thread::scope(|scope| {
            for _ in 0..12 {
                let store = test.store.clone();
                scope.spawn(move || store.upsert(&ConnectionProfile::new(), None).unwrap());
            }
        });
        let profiles = test.store.load().unwrap();
        assert_eq!(profiles.len(), 12);
        assert!(credentials.calls.lock().unwrap().is_empty());
        let prepared = test.store.prepare(&profiles).unwrap();
        // The retained original file lock refuses another in-process publisher.
        assert_eq!(
            test.store.upsert(&ConnectionProfile::new(), None),
            Err(ProfileError::Write)
        );
        assert_eq!(test.store.load().unwrap().len(), 12);
        drop(prepared);
        test.store.upsert(&ConnectionProfile::new(), None).unwrap();
        let mut latest = test.store.load_library().unwrap();
        assert_eq!(latest.connections.len(), 13);
        let prepared = test.store.prepare(&latest.connections).unwrap();
        // An external owner can atomically replace a locked file. The captured
        // publication must preserve those newer bytes on every platform.
        latest.connections.push(ConnectionProfile::new());
        let external = test.store.path.with_file_name("external-library.json");
        let bytes = serde_json::to_vec(&latest).unwrap();
        fs::write(&external, &bytes).unwrap();
        fs::rename(&external, &test.store.path).unwrap();
        assert_eq!(prepared.commit(), Err(ProfileError::Conflict));
        assert_eq!(fs::read(&test.store.path).unwrap(), bytes);
        assert_eq!(test.store.load().unwrap().len(), 14);
        assert!(credentials.calls.lock().unwrap().is_empty());
    }

    #[test]
    fn current_policy_and_selection_corruption_future_versions_and_unknown_fields_are_preserved() {
        let (test, credentials, _) = synthetic_store();
        let profile = ConnectionProfile::new();
        let valid = serde_json::to_value(ProfileLibrary {
            version: LIBRARY_VERSION,
            connections: vec![profile.clone()],
            selected_profile_id: None,
        })
        .unwrap();
        let mut cases = vec![b"{broken".to_vec()];
        for field in ["readonly", "environment"] {
            let mut json = valid.clone();
            json["connections"][0]
                .as_object_mut()
                .unwrap()
                .remove(field);
            cases.push(serde_json::to_vec(&json).unwrap());
        }
        for (key, value) in [
            ("version", serde_json::json!(99)),
            ("selectedProfileId", serde_json::json!("demo:brewery")),
            ("futureField", serde_json::json!(true)),
        ] {
            let mut json = valid.clone();
            json[key] = value;
            cases.push(serde_json::to_vec(&json).unwrap());
        }
        for original in cases {
            fs::write(&test.store.path, &original).unwrap();
            assert_eq!(test.store.load_library(), Err(ProfileError::Read));
            assert_eq!(
                test.store.upsert(&profile, Some("synthetic-new")),
                Err(ProfileError::Read)
            );
            assert_eq!(test.store.delete(&profile), Err(ProfileError::Read));
            assert_eq!(fs::read(&test.store.path).unwrap(), original);
            assert_eq!(fs::read_dir(&test.directory).unwrap().count(), 2);
        }
        assert!(credentials.calls.lock().unwrap().is_empty());
    }

    #[test]
    fn factory_defaults_differ_from_legacy_migration_defaults() {
        let fresh = ConnectionProfile::new();
        assert!(!fresh.readonly);
        assert_eq!(fresh.environment, "unspecified");
        let legacy: super::PrototypeLibrary = serde_json::from_slice(LEGACY_LIBRARY).unwrap();
        assert!(legacy.connections[0].readonly);
        assert_eq!(legacy.connections[0].environment, "development");
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_libraries_are_refused_without_touching_the_target() {
        use std::os::unix::fs::symlink;
        let test = TestStore::new();
        let target = test.directory.join("untouched.json");
        fs::write(&target, LEGACY_LIBRARY).unwrap();
        symlink(&target, &test.store.path).unwrap();
        assert_eq!(test.store.load_library(), Err(ProfileError::Read));
        assert_eq!(fs::read(target).unwrap(), LEGACY_LIBRARY);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn locked_windows_metadata_preserves_original_and_rolls_back_credential() {
        use std::os::windows::fs::OpenOptionsExt;
        let (test, credentials, _) = synthetic_store();
        let profile = ConnectionProfile::new();
        test.store.save(std::slice::from_ref(&profile)).unwrap();
        credentials
            .values
            .lock()
            .unwrap()
            .insert(profile.id.clone(), "synthetic-original".into());
        let original = fs::read(&test.store.path).unwrap();
        let locked = fs::OpenOptions::new()
            .read(true)
            .share_mode(1)
            .open(&test.store.path)
            .unwrap(); // FILE_SHARE_READ, no delete sharing
        assert_eq!(
            test.store.upsert(&profile, Some("synthetic-new")),
            Err(ProfileError::Write)
        );
        assert_eq!(fs::read(&test.store.path).unwrap(), original);
        assert_eq!(
            credentials.value(&profile.id).as_deref(),
            Some("synthetic-original")
        );
        drop(locked);
        test.store.upsert(&profile, Some("")).unwrap();
        assert_eq!(credentials.value(&profile.id).as_deref(), Some(""));
    }
    #[test]
    fn foreign_prepared_profile_replacement_is_preserved_and_credentials_roll_back() {
        let (mut test, credentials, _) = synthetic_store();
        let mut profile = ConnectionProfile::new();
        credentials
            .values
            .lock()
            .unwrap()
            .insert(profile.id.clone(), "original-synthetic".into());
        test.store.save(std::slice::from_ref(&profile)).unwrap();
        let original = fs::read(&test.store.path).unwrap();
        struct SwapTemporary {
            foreign: Mutex<Option<PathBuf>>,
        }
        impl LibraryReplacement for SwapTemporary {
            fn replace(&self, prepared: crate::files::PreparedSave) -> Result<(), ProfileError> {
                let temporary = prepared.temporary_path().to_owned();
                fs::rename(&temporary, temporary.with_extension("detached-owned")).unwrap();
                fs::write(&temporary, b"foreign synthetic metadata").unwrap();
                *self.foreign.lock().unwrap() = Some(temporary);
                prepared
                    .publish()
                    .map(|_| ())
                    .map_err(|_| ProfileError::Write)
            }
        }
        let swap = Arc::new(SwapTemporary {
            foreign: Mutex::new(None),
        });
        test.store.replacement = swap.clone();
        profile.name = "Changed synthetic profile".into();
        assert_eq!(
            test.store.upsert(&profile, Some("new-synthetic")),
            Err(ProfileError::Write)
        );
        assert_eq!(
            credentials.value(&profile.id).as_deref(),
            Some("original-synthetic")
        );
        assert_eq!(fs::read(&test.store.path).unwrap(), original);
        assert_eq!(
            fs::read(swap.foreign.lock().unwrap().as_ref().unwrap()).unwrap(),
            b"foreign synthetic metadata"
        );
    }
}
