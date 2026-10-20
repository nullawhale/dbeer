//! GNOME session-end policy and owned native D-Bus client. Session signals never
//! start Quit or a modal. A close already in progress remains the sole authority.
//! See PLATFORM_CORE.md for GNOME's noninteractive deadline and force limits.

// Portable contracts and target-only native entry points share this module.
#![allow(dead_code, unused_imports)]

#[path = "session_end/policy.rs"]
mod policy;
pub(crate) use policy::*;

#[cfg(target_os = "linux")]
#[path = "session_end/gnome.rs"]
mod gnome;
#[cfg(target_os = "linux")]
pub(crate) use gnome::{Client, ClientError, ReadinessPublisher, Snapshot};
