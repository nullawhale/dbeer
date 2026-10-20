#![cfg(any(target_os = "linux", target_os = "freebsd"))]
mod linux;

pub use linux::{current_platform, linux_platform, native_clipboard_publication, KeyInputSafety, current_key_input_safety};
