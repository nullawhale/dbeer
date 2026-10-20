//! Normalized theme assets, bounded source import and owner-scoped persistence.
//! Production Settings consumes the same normalized values and original data owner.
mod assets;
mod jetbrains;
mod parser;
mod store;
#[cfg(test)]
mod tests;

use crate::appearance::Theme;
pub use assets::builtin_themes;
pub use parser::{MAX_FILE_BYTES, MAX_TOTAL_BYTES, parse_bytes, preview_import};
pub use store::{CommitOutcome, LibraryStore, LoadedLibrary, MutationRequest};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    InvalidFormat,
    InvalidColor,
    TooLarge,
    TooComplex,
    UnsafeReference,
    ReferenceCycle,
    UnsupportedParent,
    Unreadable,
    ChooserUnavailable,
    LibraryRead,
    LibraryWrite,
    Conflict,
    LibraryFull,
    InvalidIdentity,
    RecoveryRequired,
    PublishedUnverified,
    #[cfg(windows)]
    PublicationUnknown,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::InvalidFormat => "This is not a supported VS Code, TextMate or JetBrains editor color scheme.",
            Self::InvalidColor => "The theme contains an invalid color. Use #RGB, #RGBA, #RRGGBB or #RRGGBBAA.",
            Self::TooLarge => "The theme exceeds the import limit (1 MB per file, 4 MB total, 16 files).",
            Self::TooComplex => "The theme exceeds the limit of 10,000 colors or token rules.",
            Self::UnsafeReference => "Theme references must point to local files inside the selected theme's folder.",
            Self::ReferenceCycle => "The theme contains a circular or excessively deep include.",
            Self::UnsupportedParent => "Supported IntelliJ parents are Default and Darcula. Export a self-contained scheme or use one of these parents.",
            Self::ChooserUnavailable => "The native theme chooser could not be opened. Choose Import Theme to try again.",
            Self::Unreadable => "The theme or one of its included files could not be read.",
            Self::LibraryRead => "Saved themes could not be loaded. The existing library has been left unchanged.",
            Self::LibraryWrite => "The theme library could not be saved. Retry before closing.",
            Self::Conflict => "The theme library changed outside this window. Reload before saving.",
            Self::LibraryFull => "The editor theme library is full. Remove an imported theme before adding another.",
            Self::InvalidIdentity => "The theme identity is invalid or reserved.",
            Self::RecoveryRequired => "Import with explicit library recovery to preserve the unreadable library before replacing it.",
            Self::PublishedUnverified => "The theme library was replaced but its durability could not be verified. Reload before continuing.",
            #[cfg(windows)]
            Self::PublicationUnknown => "Theme library publication could not be verified. Keep this window open and inspect the saved library, then reload before continuing.",
        })
    }
}

/// Contains only normalized colors/styles; no source path or source file bytes.
#[derive(Clone, Debug, PartialEq)]
pub struct ImportPreview {
    theme: Theme,
}
impl ImportPreview {
    pub fn theme(&self) -> &Theme {
        &self.theme
    }
}

pub const BUILTIN_IDS: [&str; 8] = [
    "native-light",
    "native-dark",
    "vscode-light-plus",
    "vscode-dark-plus",
    "solarized-light",
    "solarized-dark",
    "jetbrains-light",
    "jetbrains-darcula",
];
fn valid_import(theme: &Theme) -> bool {
    theme.is_imported && theme.is_valid() && imported_id(&theme.id)
}
fn imported_id(id: &str) -> bool {
    id.strip_prefix("imported-")
        .is_some_and(|suffix| suffix.len() == 36 && uuid::Uuid::parse_str(suffix).is_ok())
}
