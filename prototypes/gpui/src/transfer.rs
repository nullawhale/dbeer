//! Shared Swift-compatible, secret-free profile transfer. No credential APIs.
use crate::connections::ConnectionProfile;
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::path::Path;
use unicode_segmentation::UnicodeSegmentation;

pub const MAX_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_PROFILES: usize = 1000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransferError {
    Invalid,
    UnsupportedVersion,
    Read,
    Write,
    #[cfg(windows)]
    PublicationUnknown,
    MissingCA,
}
impl std::fmt::Display for TransferError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Invalid => "The profile file is invalid or contains unsupported fields. No connections were imported.",
            Self::UnsupportedVersion => "This profile file uses an unsupported version. No connections were imported.",
            Self::Read => "The profile file could not be read. No connections were imported.",
            Self::Write => "The connection profiles could not be exported. The destination was left unchanged.",
            #[cfg(windows)]
            Self::PublicationUnknown => "Profile export publication could not be verified. Inspect the destination before exporting again.",
            Self::MissingCA => "Choose the missing or foreign CA files before importing. TLS verification stays unchanged.",
        })
    }
}
impl std::error::Error for TransferError {}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Policy {
    environment: String,
    read_only: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PortableProfile {
    name: String,
    engine: String,
    host: String,
    port: u16,
    database: String,
    user: String,
    ssl_mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ssl_root_cert: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    policy: Option<Policy>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u32,
    profiles: Vec<PortableProfile>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImportedProfile {
    pub profile: ConnectionProfile,
    pub selected: bool,
    // A UNC hint is never probed automatically, even on Windows. Only explicit
    // native chooser selection permits access to that location.
    pub ca_remapped: bool,
}
impl ImportedProfile {
    pub fn requires_ca(&self) -> bool {
        self.profile
            .ssl_root_cert
            .as_deref()
            .is_some_and(|path| !local_ca_readable(path, self.ca_remapped))
    }
    pub fn remap_ca(&mut self, path: &Path) -> Result<(), TransferError> {
        let path = path.to_str().ok_or(TransferError::MissingCA)?;
        if !local_ca_readable(path, true) {
            return Err(TransferError::MissingCA);
        }
        self.profile.ssl_root_cert = Some(path.to_owned());
        self.ca_remapped = true;
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HintKind {
    Posix,
    Drive,
    Unc,
}
fn hint_kind(path: &str) -> Option<HintKind> {
    if path.is_empty() || path.len() > 4096 || path.contains('\0') {
        return None;
    }
    let b = path.as_bytes();
    if path.starts_with('/') {
        return Some(HintKind::Posix);
    }
    if b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && matches!(b[2], b'\\' | b'/') {
        return Some(HintKind::Drive);
    }
    if let Some(rest) = path.strip_prefix("\\\\") {
        let mut parts = rest.split('\\');
        let server = parts.next().unwrap_or_default();
        let share = parts.next().unwrap_or_default();
        if !server.is_empty()
            && !share.is_empty()
            && !["?", "."].contains(&server)
            && !server.contains(['/', ':'])
            && !share.contains(['/', ':'])
        {
            return Some(HintKind::Unc);
        }
    }
    None
}
pub fn valid_ca_hint(path: &str) -> bool {
    hint_kind(path).is_some()
}
fn local_ca_readable(path: &str, remapped: bool) -> bool {
    let Some(kind) = hint_kind(path) else {
        return false;
    };
    #[cfg(windows)]
    let native = matches!(kind, HintKind::Drive) || (kind == HintKind::Unc && remapped);
    #[cfg(not(windows))]
    let native = {
        let _ = remapped;
        kind == HintKind::Posix
    };
    // Check syntax before ANY filesystem access. Foreign Windows/UNC hints must
    // never accidentally address a same-named local file or a network share.
    if !native || !fs::metadata(path).is_ok_and(|m| m.is_file()) {
        return false;
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    options
        .open(path)
        .and_then(|file| file.metadata())
        .is_ok_and(|m| m.is_file())
}

impl PortableProfile {
    fn from_profile(p: &ConnectionProfile) -> Self {
        Self {
            name: p.name.clone(),
            engine: p.engine.clone(),
            host: p.host.clone(),
            port: p.port,
            database: p.database.clone(),
            user: p.user.clone(),
            ssl_mode: p.ssl_mode.clone(),
            ssl_root_cert: p.ssl_root_cert.clone(),
            policy: Some(Policy {
                environment: p.environment.clone(),
                read_only: p.readonly,
            }),
        }
    }
    fn imported(self) -> ImportedProfile {
        let mut profile = ConnectionProfile::new();
        profile.name = self.name;
        profile.engine = self.engine;
        profile.host = self.host;
        profile.port = self.port;
        profile.database = self.database;
        profile.user = self.user;
        profile.ssl_mode = self.ssl_mode;
        profile.ssl_root_cert = self.ssl_root_cert;
        // Swift TRANSFER v1 omission means unspecified/false. GPUI LIBRARY v1's
        // development/true migration defaults are intentionally unrelated.
        if let Some(policy) = self.policy {
            profile.environment = policy.environment;
            profile.readonly = policy.read_only;
        }
        ImportedProfile {
            profile,
            selected: true,
            ca_remapped: false,
        }
    }
    fn validate(&self) -> Result<(), TransferError> {
        if [&self.name, &self.host, &self.database, &self.user]
            .iter()
            .any(|s| s.trim().is_empty() || s.contains('\0') || s.len() > 1024)
            || self.name.graphemes(true).count() > 128
            || self.port == 0
            || !matches!(self.engine.as_str(), "postgresql" | "mysql")
            || !match self.engine.as_str() {
                "mysql" => ["disable", "require", "verify-ca", "verify-full"]
                    .contains(&self.ssl_mode.as_str()),
                _ => [
                    "disable",
                    "allow",
                    "prefer",
                    "require",
                    "verify-ca",
                    "verify-full",
                ]
                .contains(&self.ssl_mode.as_str()),
            }
            || self
                .ssl_root_cert
                .as_deref()
                .is_some_and(|p| !valid_ca_hint(p))
            || self.policy.as_ref().is_some_and(|p| {
                !["unspecified", "development", "staging", "production"]
                    .contains(&p.environment.as_str())
            })
        {
            return Err(TransferError::Invalid);
        }
        Ok(())
    }
}
fn validate(profiles: &[PortableProfile]) -> Result<(), TransferError> {
    if profiles.is_empty() || profiles.len() > MAX_PROFILES {
        return Err(TransferError::Invalid);
    }
    for profile in profiles {
        profile.validate()?;
    }
    Ok(())
}
fn bounded_structure(bytes: &[u8]) -> Result<(), TransferError> {
    if bytes.is_empty() || bytes.len() > MAX_BYTES {
        return Err(TransferError::Invalid);
    }
    let (mut depth, mut string, mut escaped) = (0usize, false, false);
    for &b in bytes {
        if string {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                string = false;
            }
        } else {
            match b {
                b'"' => string = true,
                b'{' | b'[' => {
                    depth += 1;
                    if depth > 16 {
                        return Err(TransferError::Invalid);
                    }
                }
                b'}' | b']' => {
                    depth = depth.checked_sub(1).ok_or(TransferError::Invalid)?;
                }
                _ => {}
            }
        }
    }
    if depth != 0 || string {
        return Err(TransferError::Invalid);
    }
    Ok(())
}
pub fn preview(bytes: &[u8]) -> Result<Vec<ImportedProfile>, TransferError> {
    bounded_structure(bytes)?;
    // Derived struct visitors reject duplicate keys (including escaped aliases)
    // and unknown keys at EVERY level; no untyped map discards repeats first.
    let envelope: Envelope = serde_json::from_slice(bytes).map_err(|_| TransferError::Invalid)?;
    if ![1, 2].contains(&envelope.version) {
        return Err(TransferError::UnsupportedVersion);
    }
    if envelope.version == 2 && envelope.profiles.iter().any(|p| p.policy.is_none()) {
        return Err(TransferError::Invalid);
    }
    validate(&envelope.profiles)?;
    Ok(envelope
        .profiles
        .into_iter()
        .map(PortableProfile::imported)
        .collect())
}
pub fn encode(profiles: &[ConnectionProfile]) -> Result<Vec<u8>, TransferError> {
    let profiles: Vec<_> = profiles.iter().map(PortableProfile::from_profile).collect();
    validate(&profiles)?;
    let mut bytes = serde_json::to_vec_pretty(&Envelope {
        version: 2,
        profiles,
    })
    .map_err(|_| TransferError::Invalid)?;
    bytes.push(b'\n');
    if bytes.len() > MAX_BYTES {
        return Err(TransferError::Invalid);
    }
    Ok(bytes)
}
pub fn read_preview(path: &Path) -> Result<Vec<ImportedProfile>, TransferError> {
    if !fs::symlink_metadata(path).is_ok_and(|m| m.is_file()) {
        return Err(TransferError::Read);
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000);
    }
    let file = options.open(path).map_err(|_| TransferError::Read)?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if file
            .metadata()
            .map_err(|_| TransferError::Read)?
            .file_attributes()
            & 0x400
            != 0
        {
            return Err(TransferError::Read);
        }
    }
    let metadata = file.metadata().map_err(|_| TransferError::Read)?;
    if !metadata.is_file() || metadata.len() > MAX_BYTES as u64 {
        return Err(TransferError::Invalid);
    }
    let mut bytes = Vec::new();
    file.take(MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| TransferError::Read)?;
    preview(&bytes)
}
#[cfg(test)]
pub fn write_atomic(bytes: &[u8], destination: &Path) -> Result<(), TransferError> {
    let capture = crate::files::CapturedDestination::capture(destination)
        .map_err(|_| TransferError::Write)?;
    write_captured(bytes, destination, &capture)
}
pub(super) fn write_captured(
    bytes: &[u8],
    destination: &Path,
    capture: &crate::files::CapturedDestination,
) -> Result<(), TransferError> {
    prepare_captured(bytes, destination, capture)?
        .publish()
        .map(|_| ())
        .map_err(|error| {
            #[cfg(windows)]
            if error == crate::files::FileError::Uncertain {
                return TransferError::PublicationUnknown;
            }
            let _ = error;
            TransferError::Write
        })
}
fn prepare_captured(
    bytes: &[u8],
    destination: &Path,
    capture: &crate::files::CapturedDestination,
) -> Result<crate::files::PreparedSave, TransferError> {
    preview(bytes)?;
    let source = std::str::from_utf8(bytes).map_err(|_| TransferError::Invalid)?;
    crate::files::PreparedSave::prepare_captured(source.into(), destination, capture)
        .map_err(|_| TransferError::Write)
}

#[cfg(test)]
#[path = "transfer_tests.rs"]
mod tests;
