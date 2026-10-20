//! Small desktop differences shared by the workspace and helper launcher.

use std::{
    ffi::OsStr,
    path::{Path, PathBuf},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Desktop {
    MacOS,
    Windows,
    Linux,
}

impl Desktop {
    fn current() -> Self {
        if cfg!(target_os = "macos") {
            Self::MacOS
        } else if cfg!(target_os = "windows") {
            Self::Windows
        } else {
            Self::Linux
        }
    }

    fn helper_name(self) -> &'static str {
        use crate::product_identity::Platform;
        match self {
            Self::MacOS => Platform::MacDevelopment,
            Self::Windows => Platform::Windows,
            Self::Linux => Platform::Linux,
        }
        .helper_executable()
    }

    fn modifier(self) -> &'static str {
        match self {
            Self::MacOS => "cmd",
            Self::Windows | Self::Linux => "ctrl",
        }
    }

    fn modifier_label(self) -> &'static str {
        match self {
            Self::MacOS => "Cmd",
            Self::Windows | Self::Linux => "Ctrl",
        }
    }
}

pub(super) fn binding(key: &str) -> String {
    format!("{}-{key}", Desktop::current().modifier())
}

pub(super) fn shortcut(key: &str) -> String {
    format!("{}+{key}", Desktop::current().modifier_label())
}

/// Packaged clients find the helper beside the executable; the development
/// wrapper supplies its build path explicitly. A release never embeds a checkout path.
pub(super) fn helper_path() -> PathBuf {
    let executable = std::env::current_exe().unwrap_or_default();
    resolve_helper(
        Desktop::current(),
        &executable,
        // Marked products always select their sibling pair. An invalid present
        // marker cannot downgrade into an environment-selected development helper.
        if option_env!("DBEER_PRODUCT_BUILD_IDENTITY").is_none() {
            std::env::var_os("DBEER_GPUI_HELPER_PATH")
        } else {
            None
        }
        .as_deref(),
        Path::is_file,
    )
}

fn resolve_helper(
    desktop: Desktop,
    executable: &Path,
    override_path: Option<&OsStr>,
    is_file: impl Fn(&Path) -> bool,
) -> PathBuf {
    if let Some(path) = override_path.filter(|path| !path.is_empty()) {
        return path.into();
    }
    let Some(directory) = executable
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
    else {
        // Do not search the working directory or PATH if executable discovery
        // fails. An empty launch path produces the existing safe helper error.
        return PathBuf::new();
    };
    if desktop == Desktop::MacOS
        && directory.file_name().is_some_and(|name| name == "MacOS")
        && let Some(contents) = directory
            .parent()
            .filter(|path| path.file_name().is_some_and(|name| name == "Contents"))
    {
        let bundled = contents.join("Helpers").join(desktop.helper_name());
        if is_file(&bundled) {
            return bundled;
        }
    }
    directory.join(desktop.helper_name())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn primary_shortcuts_follow_desktop_conventions() {
        for (desktop, binding, label) in [
            (Desktop::MacOS, "cmd", "Cmd"),
            (Desktop::Windows, "ctrl", "Ctrl"),
            (Desktop::Linux, "ctrl", "Ctrl"),
        ] {
            assert_eq!(desktop.modifier(), binding);
            assert_eq!(desktop.modifier_label(), label);
        }
    }

    #[test]
    fn explicit_helper_override_wins_on_every_desktop() {
        for desktop in [Desktop::MacOS, Desktop::Windows, Desktop::Linux] {
            let path = resolve_helper(
                desktop,
                Path::new("/client/DBeer"),
                Some(OsStr::new("/custom/helper")),
                |_| true,
            );
            assert_eq!(path, Path::new("/custom/helper"));
        }
    }

    #[test]
    fn packaged_helpers_live_beside_the_client() {
        for (desktop, name) in [
            (Desktop::MacOS, "dbeer-core"),
            (Desktop::Windows, "dbeer-core.exe"),
            (Desktop::Linux, "dbeer-core"),
        ] {
            let path = resolve_helper(desktop, Path::new("/client/DBeer"), None, |_| false);
            assert_eq!(path, Path::new("/client").join(name));
        }
    }

    #[test]
    fn macos_bundle_uses_contents_helpers_only_when_present() {
        let executable = Path::new("/Applications/DBeerGPUI.app/Contents/MacOS/DBeerGPUI");
        let bundled = Path::new("/Applications/DBeerGPUI.app/Contents/Helpers/dbeer-core");
        assert_eq!(
            resolve_helper(Desktop::MacOS, executable, None, |path| path == bundled),
            bundled
        );
        assert_eq!(
            resolve_helper(Desktop::MacOS, executable, None, |_| false),
            executable.parent().unwrap().join("dbeer-core")
        );
    }

    #[test]
    fn nonmacos_does_not_search_macos_bundle_layout() {
        let executable = Path::new("/client/Contents/MacOS/DBeer");
        for desktop in [Desktop::Windows, Desktop::Linux] {
            assert_eq!(
                resolve_helper(desktop, executable, None, |_| true),
                executable.parent().unwrap().join(desktop.helper_name())
            );
        }
    }

    #[test]
    fn missing_and_empty_overrides_use_the_same_packaged_path() {
        let executable = Path::new("/client/DBeer");
        assert_eq!(
            resolve_helper(Desktop::Linux, executable, None, |_| false),
            resolve_helper(Desktop::Linux, executable, Some(OsStr::new("")), |_| false)
        );
    }

    #[test]
    fn missing_executable_never_falls_back_to_working_directory_or_path() {
        for desktop in [Desktop::MacOS, Desktop::Windows, Desktop::Linux] {
            assert!(
                resolve_helper(desktop, Path::new(""), None, |_| true)
                    .as_os_str()
                    .is_empty()
            );
        }
    }
}
