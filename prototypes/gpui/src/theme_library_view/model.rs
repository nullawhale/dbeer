use crate::{
    appearance::{EditorPalette, Scheme, Theme},
    theme_library::{BUILTIN_IDS, Error, ImportPreview},
};
use std::collections::HashSet;

/// These values describe store authority; they do not grant it. In particular,
/// showing built-ins after a refused load cannot make ordinary imports writable.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LibraryAccess {
    Writable,
    /// Disposable workspaces have no personal store or reload authority.
    PreviewOnly,
    ReadOnly {
        error: Error,
        recovery_available: bool,
    },
}
impl LibraryAccess {
    pub fn can_import(self, mode: ImportMode) -> bool {
        matches!(
            (self, mode),
            (Self::Writable, ImportMode::Standard)
                | (
                    Self::ReadOnly {
                        recovery_available: true,
                        ..
                    },
                    ImportMode::Recovery
                )
        )
    }
    pub fn error(self) -> Option<Error> {
        match self {
            Self::Writable | Self::PreviewOnly => None,
            Self::ReadOnly { error, .. } => Some(error),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ImportMode {
    Standard,
    /// Separately authorized import; preserve exact unreadable library bytes.
    Recovery,
}

/// Allocate once from the original accepted import event, before native chooser
/// dispatch. Serial numbers belong to the retained Settings owner, never wrap,
/// and are never reused across cancellation, reload or reopening Settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ImportRequest {
    origin_revision: u64,
    serial: u64,
    mode: ImportMode,
}
impl ImportRequest {
    pub fn new(origin_revision: u64, serial: u64, mode: ImportMode) -> Option<Self> {
        (serial != 0).then_some(Self {
            origin_revision,
            serial,
            mode,
        })
    }
    pub fn origin_revision(self) -> u64 {
        self.origin_revision
    }
    #[allow(dead_code)] // Inspection API; live ownership compares the complete opaque token.
    pub fn serial(self) -> u64 {
        self.serial
    }
    pub fn mode(self) -> ImportMode {
        self.mode
    }
}

/// Allocate for this parse completion, retaining its ORIGINAL import request.
/// A newer presentation does not relabel a chooser/worker as a newer request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PreviewToken {
    request: ImportRequest,
    serial: u64,
}
impl PreviewToken {
    pub fn new(request: ImportRequest, serial: u64) -> Option<Self> {
        (serial != 0).then_some(Self { request, serial })
    }
    pub fn request(self) -> ImportRequest {
        self.request
    }
    #[allow(dead_code)] // Inspection API; live ownership compares the complete opaque token.
    pub fn serial(self) -> u64 {
        self.serial
    }
}

/// The existing normalized preview, never a second theme or persistence DTO.
#[derive(Clone, Debug, PartialEq)]
pub struct ImportReview {
    token: PreviewToken,
    preview: ImportPreview,
}
impl ImportReview {
    pub fn new(token: PreviewToken, preview: &ImportPreview) -> Self {
        Self {
            token,
            preview: preview.clone(),
        }
    }
    pub fn token(&self) -> PreviewToken {
        self.token
    }
    pub fn preview(&self) -> &ImportPreview {
        &self.preview
    }
    pub fn theme(&self) -> &Theme {
        self.preview.theme()
    }
}

/// An owner-allocated mutation identity for one original imported theme.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemovalRequest {
    origin_revision: u64,
    serial: u64,
    theme_id: String,
}
impl RemovalRequest {
    pub fn new(origin_revision: u64, serial: u64, theme_id: &str) -> Option<Self> {
        (serial != 0 && !theme_id.is_empty()).then(|| Self {
            origin_revision,
            serial,
            theme_id: theme_id.into(),
        })
    }
    pub fn origin_revision(&self) -> u64 {
        self.origin_revision
    }
    #[allow(dead_code)] // Inspection API; live ownership compares the complete opaque token.
    pub fn serial(&self) -> u64 {
        self.serial
    }
    pub fn theme_id(&self) -> &str {
        &self.theme_id
    }
}

/// An immutable projection supplied by the owner. No variant executes a native
/// chooser, retains a source path, parses, reserves a save or changes preferences.
#[derive(Clone, Debug, PartialEq)]
pub enum Workflow {
    Idle,
    Choosing(ImportRequest),
    Parsing(ImportRequest),
    Review(ImportReview),
    ImportFailed {
        request: ImportRequest,
        error: Error,
    },
    SavingImport(ImportReview),
    ImportSaveFailed {
        review: ImportReview,
        error: Error,
    },
    Removing(RemovalRequest),
    RemoveFailed {
        request: RemovalRequest,
        error: Error,
    },
    Reloading,
}
impl Workflow {
    pub fn review(&self) -> Option<&ImportReview> {
        match self {
            Self::Review(review)
            | Self::SavingImport(review)
            | Self::ImportSaveFailed { review, .. } => Some(review),
            _ => None,
        }
    }
    pub fn error(&self) -> Option<Error> {
        match self {
            Self::ImportFailed { error, .. }
            | Self::ImportSaveFailed { error, .. }
            | Self::RemoveFailed { error, .. } => Some(*error),
            _ => None,
        }
    }
    pub fn import_request(&self) -> Option<ImportRequest> {
        match self {
            Self::Choosing(request)
            | Self::Parsing(request)
            | Self::ImportFailed { request, .. } => Some(*request),
            _ => self.review().map(|review| review.token().request()),
        }
    }
    pub fn summary(&self) -> &'static str {
        match self {
            Self::Idle => {
                "Browse the library to preview a scheme without changing either selection."
            }
            Self::Choosing(_) => "Choose a local VS Code, TextMate or JetBrains theme file.",
            Self::Parsing(_) => "Reading and checking the selected theme...",
            Self::Review(_) => {
                "This preview is not saved. Import adds the theme and selects it for the SQL editor."
            }
            Self::ImportFailed { .. } => "No theme was imported. Choose another file or cancel.",
            Self::SavingImport(_) => "Saving the normalized theme library...",
            Self::ImportSaveFailed {
                error: Error::PublishedUnverified,
                ..
            } => {
                "The library was replaced, but its durability could not be verified. Reload before continuing."
            }
            #[cfg(windows)]
            Self::ImportSaveFailed {
                error: Error::PublicationUnknown,
                ..
            } => {
                "Import publication is unknown. Inspect the saved library, then reload before continuing."
            }
            Self::ImportSaveFailed { .. } => {
                "The library save did not complete. The import preview remains available."
            }
            Self::Removing(_) => "Removing the imported theme...",
            Self::RemoveFailed {
                error: Error::PublishedUnverified,
                ..
            } => {
                "Removal could not be confirmed after publication. Reload before continuing. Saved selections have been retained."
            }
            #[cfg(windows)]
            Self::RemoveFailed {
                error: Error::PublicationUnknown,
                ..
            } => {
                "Removal publication is unknown. Inspect the saved library, then reload before continuing. Saved selections have been retained."
            }
            Self::RemoveFailed { .. } => {
                "The theme was not removed. Its saved selections have been retained."
            }
            Self::Reloading => "Reloading the saved theme library...",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LibraryAction {
    /// Browse changes only this section's displayed preview, never preferences.
    Browse(String),
    RequestImport,
    RequestRecoveryImport,
    CancelImport {
        request: ImportRequest,
        preview: Option<PreviewToken>,
    },
    CommitImport(PreviewToken),
    RetryImport(ImportRequest),
    RetryImportSave(PreviewToken),
    Remove(String),
    RetryRemove(RemovalRequest),
    Reload,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LibraryEvent {
    pub revision: u64,
    pub action: LibraryAction,
}

/// Only normalized values from the owner's actual library enter this section.
/// The original selected application/editor IDs and mutable Preferences do not.
#[derive(Clone, Debug, PartialEq)]
pub struct Presentation {
    revision: u64,
    themes: Vec<Theme>,
    browsed_id: Option<String>,
    access: LibraryAccess,
    workflow: Workflow,
    editor_palette: EditorPalette,
}
impl Presentation {
    pub fn new(
        revision: u64,
        themes: &[Theme],
        browsed_id: Option<&str>,
        fallback: Scheme,
        access: LibraryAccess,
        workflow: Workflow,
    ) -> Self {
        let mut seen = HashSet::new();
        let themes = themes
            .iter()
            .filter(|theme| theme.is_valid() && seen.insert(theme.id.clone()))
            .cloned()
            .collect::<Vec<_>>();
        let browsed_id = browsed_id
            .and_then(|id| themes.iter().find(|theme| theme.id == id))
            .or_else(|| themes.first())
            .map(|theme| theme.id.clone());
        let fallback = Theme::native(fallback);
        let theme = workflow
            .review()
            .map(ImportReview::theme)
            .or_else(|| {
                themes
                    .iter()
                    .find(|theme| Some(&theme.id) == browsed_id.as_ref())
            })
            .unwrap_or(&fallback);
        let editor_palette = EditorPalette::from_theme(theme);
        Self {
            revision,
            themes,
            browsed_id,
            access,
            workflow,
            editor_palette,
        }
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn themes(&self) -> &[Theme] {
        &self.themes
    }
    pub fn browsed_id(&self) -> Option<&str> {
        self.browsed_id.as_deref()
    }
    pub fn access(&self) -> LibraryAccess {
        self.access
    }
    pub fn workflow(&self) -> &Workflow {
        &self.workflow
    }
    pub fn editor_palette(&self) -> &EditorPalette {
        &self.editor_palette
    }
    pub fn preview_theme(&self) -> &Theme {
        &self.editor_palette.theme
    }
    pub fn browsed_theme(&self) -> Option<&Theme> {
        self.themes
            .iter()
            .find(|theme| Some(theme.id.as_str()) == self.browsed_id())
    }
    pub fn can_browse(&self) -> bool {
        matches!(
            self.workflow,
            Workflow::Idle | Workflow::ImportFailed { .. } | Workflow::RemoveFailed { .. }
        )
    }
    pub fn can_reload(&self) -> bool {
        self.access != LibraryAccess::PreviewOnly
            && !matches!(
                self.workflow,
                Workflow::SavingImport(_) | Workflow::Removing(_) | Workflow::Reloading
            )
    }
    pub fn can_start(&self, mode: ImportMode) -> bool {
        !self.requires_reload()
            && self.access.can_import(mode)
            && matches!(
                self.workflow,
                Workflow::Idle | Workflow::ImportFailed { .. } | Workflow::RemoveFailed { .. }
            )
    }
    pub fn can_remove(&self, id: &str) -> bool {
        !self.requires_reload()
            && self.access == LibraryAccess::Writable
            && self.can_browse()
            && self.browsed_id() == Some(id)
            && self
                .themes
                .iter()
                .any(|theme| theme.id == id && removable(theme))
    }
    pub fn cancel_action(&self) -> Option<LibraryAction> {
        #[cfg(windows)]
        if self.workflow.error() == Some(Error::PublicationUnknown) {
            return None;
        }
        if matches!(
            self.workflow,
            Workflow::SavingImport(_)
                | Workflow::ImportSaveFailed {
                    error: Error::PublishedUnverified,
                    ..
                }
        ) {
            return None;
        }
        self.workflow
            .import_request()
            .map(|request| LibraryAction::CancelImport {
                request,
                preview: self.workflow.review().map(ImportReview::token),
            })
    }
    pub fn error(&self) -> Option<Error> {
        self.workflow.error().or_else(|| self.access.error())
    }
    pub fn requires_reload(&self) -> bool {
        let requires_reload = matches!(
            self.workflow.error(),
            Some(
                Error::Conflict
                    | Error::PublishedUnverified
                    | Error::RecoveryRequired
                    | Error::LibraryRead
            )
        );
        #[cfg(windows)]
        let requires_reload =
            requires_reload || self.workflow.error() == Some(Error::PublicationUnknown);
        requires_reload
    }
    pub fn accepts(&self, event: &LibraryEvent) -> bool {
        if event.revision != self.revision {
            return false;
        }
        match &event.action {
            LibraryAction::Browse(id) => {
                self.can_browse() && self.themes.iter().any(|theme| theme.id == *id)
            }
            LibraryAction::RequestImport => self.can_start(ImportMode::Standard),
            LibraryAction::RequestRecoveryImport => self.can_start(ImportMode::Recovery),
            LibraryAction::CancelImport { request, .. } => {
                request.origin_revision() <= self.revision
                    && self.cancel_action().as_ref() == Some(&event.action)
            }
            LibraryAction::CommitImport(token) => matches!(&self.workflow, Workflow::Review(review)
                if review.token() == *token && self.review_is_current(review)),
            LibraryAction::RetryImport(request) => {
                matches!(&self.workflow, Workflow::ImportFailed { request: current, error }
                if current == request && request.origin_revision() <= self.revision
                    && self.access.can_import(request.mode()) && *error == Error::Unreadable)
            }
            LibraryAction::RetryImportSave(token) => {
                matches!(&self.workflow, Workflow::ImportSaveFailed { review, error }
                if review.token() == *token && *error == Error::LibraryWrite && self.review_is_current(review))
            }
            LibraryAction::Remove(id) => self.can_remove(id),
            LibraryAction::RetryRemove(request) => {
                matches!(&self.workflow, Workflow::RemoveFailed { request: current, error }
                if current == request && request.origin_revision() <= self.revision && *error == Error::LibraryWrite
                    && self.can_remove(request.theme_id()))
            }
            LibraryAction::Reload => self.can_reload(),
        }
    }
    fn review_is_current(&self, review: &ImportReview) -> bool {
        review.token().request().origin_revision() <= self.revision
            && self.access.can_import(review.token().request().mode())
            && removable(review.theme())
            && !self
                .themes
                .iter()
                .any(|theme| theme.id == review.theme().id)
    }
}

fn removable(theme: &Theme) -> bool {
    theme.is_imported
        && theme.is_valid()
        && !BUILTIN_IDS.contains(&theme.id.as_str())
        && theme
            .id
            .strip_prefix("imported-")
            .is_some_and(|id| id.len() == 36 && uuid::Uuid::parse_str(id).is_ok())
}
