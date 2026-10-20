//! Windows/Linux product identity. Storage names deliberately remain compatible
//! with the prototype; presentation identity does not move files or credentials.

use serde::{Deserialize, Serialize};
use std::{ffi::OsString, path::PathBuf};

mod preflight;
pub(crate) use preflight::{VerifiedHelper, prepare_helper};

pub const PRODUCT_ID: &str = "app.dbeer.DBeer";
pub const DISPLAY_NAME: &str = "DBeer";
#[allow(dead_code)] // Shared desktop integration contract; launcher generation is Python-owned.
pub const DESKTOP_FILE: &str = "app.dbeer.DBeer.desktop";
#[allow(dead_code)] // Shared desktop integration contract; Windows consumes integer icon ID 1.
pub const ICON_NAME: &str = PRODUCT_ID;
pub const CREDENTIAL_SERVICE: &str = "dev.dbeer.gpui-prototype";
pub const PROTOCOL_VERSION: u32 = 3;
pub const CONTRACT_REVISION: &str = "gpui-v3-captured-export-v1";
pub const REQUIRED_CAPABILITY: &str = "capturedExportV1";
pub const VERSION: &str = include_str!("../../../VERSION");
pub const BUILD_NUMBER: &str = include_str!("../../../BUILD_NUMBER");

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    Windows,
    Linux,
    MacDevelopment,
}
impl Platform {
    pub fn current() -> Option<Self> {
        match std::env::consts::OS {
            "windows" => Some(Self::Windows),
            "linux" => Some(Self::Linux),
            "macos" => Some(Self::MacDevelopment),
            _ => None,
        }
    }
    pub fn helper_executable(self) -> &'static str {
        match self {
            Self::Windows => "dbeer-core.exe",
            _ => "dbeer-core",
        }
    }
}

pub fn application_id() -> &'static str {
    if cfg!(target_os = "macos") {
        "dev.dbeer.gpui-prototype"
    } else {
        PRODUCT_ID
    }
}
pub fn application_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "DBeer GPUI"
    } else {
        DISPLAY_NAME
    }
}

/// The old and new executable must acquire this *same* DataDirectory owner
/// before loading any store. There is no copy, alias directory, PID or secret API.
pub fn compatible_library_path(
    platform: Platform,
    mut environment: impl FnMut(&str) -> Option<OsString>,
) -> Result<PathBuf, IdentityError> {
    let absolute =
        |value: Option<OsString>| value.map(PathBuf::from).filter(|path| path.is_absolute());
    let root = match platform {
        Platform::Windows => absolute(environment("LOCALAPPDATA"))
            .ok_or(IdentityError)?
            .join("DBeerGPUI"),
        Platform::Linux => absolute(environment("XDG_CONFIG_HOME"))
            .or_else(|| absolute(environment("HOME")).map(|path| path.join(".config")))
            .ok_or(IdentityError)?
            .join("dbeer-gpui"),
        Platform::MacDevelopment => absolute(environment("HOME"))
            .ok_or(IdentityError)?
            .join("Library/Application Support/DBeerGPUI"),
    };
    Ok(root.join("connections.json"))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StartupPolicy {
    pub built_in_fixtures: bool,
    pub restore_disconnected: bool,
}
impl StartupPolicy {
    /// Explicit --demo/native smoke on the Mac development host may retain its
    /// disposable fixtures. Product startup never infers fixtures from saved IDs.
    pub fn new(platform: Platform, explicit_disposable_fixtures: bool) -> Self {
        Self {
            built_in_fixtures: platform == Platform::MacDevelopment && explicit_disposable_fixtures,
            restore_disconnected: true,
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum NativeTarget {
    #[serde(rename = "windows-x86_64-msvc")]
    WindowsX64,
    #[serde(rename = "linux-x86_64-gnu")]
    UbuntuX64,
}
impl NativeTarget {
    pub fn platform(self) -> Platform {
        match self {
            Self::WindowsX64 => Platform::Windows,
            Self::UbuntuX64 => Platform::Linux,
        }
    }
    /// Rust x86_64 and Go amd64 denote the same product architecture. The
    /// serialized target is canonical and never copied from a caller's free text.
    pub fn from_native(os: &str, architecture: &str, abi: &str) -> Option<Self> {
        if !matches!(architecture, "x86_64" | "amd64") {
            return None;
        }
        match (os, abi) {
            ("windows", "msvc") => Some(Self::WindowsX64),
            ("linux", "gnu") => Some(Self::UbuntuX64),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuildIdentity {
    pub schema_version: u32,
    pub product_id: String,
    pub version: String,
    pub build_number: String,
    pub target: NativeTarget,
    pub protocol_version: u32,
    pub contract_revision: String,
    pub source_sha256: String,
    pub capabilities: Vec<String>,
}
impl BuildIdentity {
    /// Absence is permitted only for existing unmarked development builds.
    /// A present but invalid compiled marker can never downgrade to development.
    pub fn optional_embedded() -> Result<Option<Self>, IdentityError> {
        option_env!("DBEER_PRODUCT_BUILD_IDENTITY")
            .map(|_| Self::embedded())
            .transpose()
    }

    /// Preserve the original nested representation before generic wire decoding.
    /// Unknown wire fields are handled by the transport's existing validator.
    pub fn optional_from_frame(
        bytes: &[u8],
        maximum_frame_bytes: usize,
    ) -> Result<Option<Self>, IdentityError> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Envelope<'a> {
            #[serde(rename = "type")]
            kind: String,
            #[serde(borrow)]
            build_identity: Option<&'a serde_json::value::RawValue>,
        }
        if bytes.len() > maximum_frame_bytes {
            return Err(IdentityError);
        }
        let envelope: Envelope<'_> = serde_json::from_slice(bytes).map_err(|_| IdentityError)?;
        match (envelope.kind.as_str(), envelope.build_identity) {
            ("hello.ack", Some(raw)) => Self::parse(raw.get().as_bytes()).map(Some),
            // The wire validator owns unexpected non-hello fields, including
            // its existing malformed-terminal completed-prefix recovery.
            _ => Ok(None),
        }
    }

    pub fn validate(&self) -> Result<(), IdentityError> {
        let version: Vec<_> = self.version.split('.').collect();
        let digits =
            |value: &str| !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit());
        if self.schema_version != 1
            || self.product_id != PRODUCT_ID
            || version.len() != 3
            || !version.iter().all(|value| digits(value))
            || self.version.len() > 32
            || !digits(&self.build_number)
            || self.build_number.starts_with('0')
            || self.build_number.len() > 20
            || self.protocol_version != PROTOCOL_VERSION
            || self.contract_revision != CONTRACT_REVISION
            || self.source_sha256.len() != 64
            || !self
                .source_sha256
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            || self.capabilities != [REQUIRED_CAPABILITY]
        {
            return Err(IdentityError);
        }
        Ok(())
    }
    pub fn parse(bytes: &[u8]) -> Result<Self, IdentityError> {
        if bytes.len() > 4096 {
            return Err(IdentityError);
        }
        let identity: Self = serde_json::from_slice(bytes).map_err(|_| IdentityError)?;
        identity.validate()?;
        Ok(identity)
    }
    /// Sorted keys independent of additive serde_json preserve_order features.
    /// All accepted schema values are ASCII; the embedded marker has no LF.
    pub fn canonical_json(&self) -> Result<String, IdentityError> {
        self.validate()?;
        let serde_json::Value::Object(fields) =
            serde_json::to_value(self).map_err(|_| IdentityError)?
        else {
            return Err(IdentityError);
        };
        let sorted: std::collections::BTreeMap<_, _> = fields.into_iter().collect();
        serde_json::to_string(&sorted).map_err(|_| IdentityError)
    }
    /// Product builds use shared VERSION/BUILD_NUMBER; Cargo's crate version is
    /// not release metadata. No helper process, profile read or OS store is used.
    pub fn embedded() -> Result<Self, IdentityError> {
        let bytes = option_env!("DBEER_PRODUCT_BUILD_IDENTITY").ok_or(IdentityError)?;
        let identity = Self::parse(bytes.as_bytes())?;
        let native = NativeTarget::from_native(
            std::env::consts::OS,
            std::env::consts::ARCH,
            if cfg!(target_env = "msvc") {
                "msvc"
            } else if cfg!(target_env = "gnu") {
                "gnu"
            } else {
                "unsupported"
            },
        );
        if identity.canonical_json()? != bytes
            || identity.version != VERSION.trim()
            || identity.build_number != BUILD_NUMBER.trim()
            || Some(identity.target.platform()) != Platform::current()
            || Some(identity.target) != native
        {
            return Err(IdentityError);
        }
        Ok(identity)
    }
    /// Required before any product helper operation. A wire-v3 helper with
    /// absent/old semantic capabilities or a different build cannot be accepted.
    pub fn require_matching_helper(
        &self,
        remote: Option<&Self>,
        protocol: u32,
        capabilities: &[String],
    ) -> Result<(), IdentityError> {
        self.validate()?;
        let remote = remote.ok_or(IdentityError)?;
        remote.validate()?;
        if self != remote
            || protocol != PROTOCOL_VERSION
            || !capabilities
                .iter()
                .any(|value| value == REQUIRED_CAPABILITY)
        {
            return Err(IdentityError);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Component {
    Gui,
    Helper,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuildInfo {
    pub component: Component,
    pub identity: BuildIdentity,
}
impl BuildInfo {
    /// The GUI's --build-info dispatch must run before GPUI initialization,
    /// data-directory ownership, restore, helper startup and credential access.
    pub fn gui_json() -> Result<String, IdentityError> {
        if cfg!(debug_assertions) || cfg!(feature = "native-smoke") {
            return Err(IdentityError);
        }
        Ok(format!(
            "{{\"component\":\"gui\",\"identity\":{}}}",
            BuildIdentity::embedded()?.canonical_json()?
        ))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IdentityError;
impl std::fmt::Display for IdentityError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("The DBeer application and helper build identities do not match. Extract a complete matching package.")
    }
}
impl std::error::Error for IdentityError {}

#[cfg(test)]
#[path = "product_identity/tests.rs"]
mod tests;

#[cfg(test)]
#[path = "product_identity/contract_fixtures.rs"]
mod contract_fixtures;
