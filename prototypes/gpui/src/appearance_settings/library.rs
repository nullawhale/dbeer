//! Original Settings/library request ownership. Parsing and publication run off-thread.
use super::*;
use crate::theme_library::{self, CommitOutcome, Error, MutationRequest};
use crate::theme_library_view::{
    ImportMode, ImportRequest, ImportReview, LibraryAccess, LibraryAction, LibraryEvent,
    Presentation as LibraryPresentation, PreviewToken, RemovalRequest, ThemeLibraryView, Workflow,
};
use std::path::PathBuf;

#[cfg(test)]
mod tests;

type Result = std::result::Result<(), Error>;
#[derive(Clone)]
struct Completion {
    result: Arc<Mutex<Option<Result>>>,
    done: async_channel::Receiver<()>,
}
impl Completion {
    fn new() -> (Self, async_channel::Sender<()>) {
        let (sender, done) = async_channel::bounded(1);
        (
            Self {
                result: Arc::new(Mutex::new(None)),
                done,
            },
            sender,
        )
    }
    fn finish(&self, result: Result) {
        if let Ok(mut output) = self.result.lock() {
            *output = Some(result);
        }
    }
    async fn wait(&self) -> Result {
        let _ = self.done.recv().await;
        self.result
            .lock()
            .map_err(|_| Error::LibraryWrite)?
            .unwrap_or(Err(Error::LibraryWrite))
    }
}
struct Job {
    completion: Completion,
    _task: Task<()>,
}
#[derive(Clone)]
struct ImportCapture {
    owner: EntityId,
    request: ImportRequest,
    /// Original preferences authority, captured BEFORE the native chooser.
    preference_revision: u64,
    path: Option<PathBuf>,
}
#[derive(Clone)]
enum MutationIntent {
    Import {
        review: ImportReview,
        capture: ImportCapture,
    },
    Remove(RemovalRequest),
}
#[derive(Clone)]
struct PendingMutation {
    revision: u64,
    completion: Completion,
}
pub(super) struct LibraryState {
    revision: u64,
    serial: u64,
    workflow: Workflow,
    browsed: Option<String>,
    import: Option<ImportCapture>,
    pending: Option<PendingMutation>,
    jobs: Vec<Job>,
    reload: Option<(u64, EntityId)>,
}
impl Default for LibraryState {
    fn default() -> Self {
        Self {
            revision: 0,
            serial: 0,
            workflow: Workflow::Idle,
            browsed: None,
            import: None,
            pending: None,
            jobs: Vec::new(),
            reload: None,
        }
    }
}
impl LibraryState {
    fn serial(&mut self) -> Option<u64> {
        self.serial = self.serial.checked_add(1)?;
        Some(self.serial)
    }
    fn advance(&mut self) -> bool {
        let Some(next) = self.revision.checked_add(1) else {
            return false;
        };
        self.revision = next;
        self.jobs.retain(|job| !job.completion.done.is_closed());
        true
    }
    fn finalization(
        &self,
        original_store: Option<theme_library::LibraryStore>,
    ) -> close::finalizers::FinalizationJob {
        let revision = self.revision;
        let jobs = self
            .jobs
            .iter()
            .map(|j| j.completion.clone())
            .collect::<Vec<_>>();
        let pending = self.pending.clone();
        close::finalizers::FinalizationJob {
            revision,
            future: Box::pin(async move {
                let _original_store = original_store;
                // Even canceled native chooser/read futures stay owned until their ORIGINAL
                // callback drains. UI cancellation never means an OS picker was dismissed.
                for job in jobs {
                    let _ = job.wait().await;
                }
                if let Some(pending) = pending {
                    if pending.revision > revision {
                        return Err(Error::Conflict.to_string());
                    }
                    pending.completion.wait().await.map_err(|e|
                    format!("{e} Open Appearance settings to retry or explicitly reload the saved theme library."))?;
                }
                Ok(())
            }),
        }
    }
}
impl State {
    fn library_access(&self) -> LibraryAccess {
        match (self.library_store.is_some(), self.library_error) {
            (true, None) => LibraryAccess::Writable,
            (false, None) => LibraryAccess::PreviewOnly,
            (_, error) => LibraryAccess::ReadOnly {
                error: error.unwrap_or(Error::LibraryRead),
                recovery_available: self.library_recovery_available,
            },
        }
    }
    pub(super) fn library_presentation(&self) -> LibraryPresentation {
        LibraryPresentation::new(
            self.presentation_revision,
            &self.themes,
            self.library.browsed.as_deref(),
            self.resolved.application_scheme,
            self.library_access(),
            self.library.workflow.clone(),
        )
    }
    fn library_owner(&self, owner: EntityId) -> bool {
        self.dialog
            .as_ref()
            .is_some_and(|d| d.view.entity_id() == owner)
    }
    fn accepts_library(
        &self,
        owner: EntityId,
        section: EntityId,
        event: &LibraryEvent,
        cx: &App,
    ) -> bool {
        self.dialog.as_ref().is_some_and(|d| {
            d.view.entity_id() == owner
                && d.library.entity_id() == section
                && d.library.read(cx).presentation() == &self.library_presentation()
        }) && self.library_presentation().accepts(event)
    }
    fn import_current(&self, capture: &ImportCapture) -> bool {
        self.library_owner(capture.owner)
            && self.library.import.as_ref().is_some_and(|active| {
                active.owner == capture.owner && active.request == capture.request
            })
            && self.library.workflow.import_request() == Some(capture.request)
    }
}
impl Workspace {
    pub(super) fn mount_theme_library(
        &mut self,
        settings: &Entity<SettingsView>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> (Entity<ThemeLibraryView>, Subscription) {
        let owner = settings.entity_id();
        let presentation = self.appearance.library_presentation();
        let library = cx.new(|cx| ThemeLibraryView::new(presentation, window, cx));
        let section = library.entity_id();
        let subscription = cx.subscribe_in(
            &library,
            window,
            move |this, original, event: &LibraryEvent, window, cx| {
                if original.entity_id() == section {
                    this.theme_library_event(owner, section, event, window, cx);
                }
            },
        );
        settings.update(cx, |view, cx| {
            view.set_additional_sections(vec![library.clone().into()], cx)
        });
        (library, subscription)
    }
    fn theme_library_event(
        &mut self,
        owner: EntityId,
        section: EntityId,
        event: &LibraryEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing
            || self.appearance.reload.is_some()
            || !window.has_active_dialog(cx)
            || !self.appearance.accepts_library(owner, section, event, cx)
        {
            return;
        }
        match &event.action {
            LibraryAction::Browse(id) => {
                self.appearance.library.browsed = Some(id.clone());
                self.publish_appearance(window, cx);
            }
            LibraryAction::RequestImport => {
                self.choose_theme_file(owner, ImportMode::Standard, window, cx)
            }
            LibraryAction::RequestRecoveryImport => {
                self.choose_theme_file(owner, ImportMode::Recovery, window, cx)
            }
            LibraryAction::CancelImport { request, preview } => {
                // Match the exact originating request AND original preview, never recapture.
                if self.appearance.library.workflow.import_request() == Some(*request)
                    && self
                        .appearance
                        .library
                        .workflow
                        .review()
                        .map(ImportReview::token)
                        == *preview
                {
                    if let Workflow::ImportSaveFailed { error, .. } =
                        self.appearance.library.workflow
                    {
                        self.appearance.library_error = Some(error);
                        self.appearance.library_recovery_available = false;
                    }
                    self.appearance.library.import = None;
                    self.appearance.library.workflow = Workflow::Idle;
                    self.publish_appearance(window, cx);
                }
            }
            LibraryAction::CommitImport(token) | LibraryAction::RetryImportSave(token) => {
                let Some(review) = self
                    .appearance
                    .library
                    .workflow
                    .review()
                    .filter(|r| r.token() == *token)
                    .cloned()
                else {
                    return;
                };
                let Some(capture) = self
                    .appearance
                    .library
                    .import
                    .clone()
                    .filter(|c| c.request == token.request())
                else {
                    return;
                };
                self.commit_theme(MutationIntent::Import { review, capture }, window, cx);
            }
            LibraryAction::RetryImport(request) => {
                if let Some(capture) = self
                    .appearance
                    .library
                    .import
                    .clone()
                    .filter(|c| c.request == *request && c.path.is_some())
                {
                    self.parse_theme_file(capture, window, cx);
                }
            }
            LibraryAction::Remove(id) => {
                let Some(serial) = self.appearance.library.serial() else {
                    return;
                };
                let Some(request) = RemovalRequest::new(event.revision, serial, id) else {
                    return;
                };
                self.commit_theme(MutationIntent::Remove(request), window, cx);
            }
            LibraryAction::RetryRemove(request) => {
                self.commit_theme(MutationIntent::Remove(request.clone()), window, cx)
            }
            LibraryAction::Reload => self.reload_theme_library(owner, window, cx),
        }
    }
    fn choose_theme_file(
        &mut self,
        owner: EntityId,
        mode: ImportMode,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.appearance.library.advance() {
            return;
        }
        let Some(serial) = self.appearance.library.serial() else {
            return;
        };
        let Some(request) = ImportRequest::new(self.appearance.presentation_revision, serial, mode)
        else {
            return;
        };
        let capture = ImportCapture {
            owner,
            request,
            preference_revision: self.appearance.revision,
            path: None,
        };
        self.appearance.library.import = Some(capture.clone());
        self.appearance.library.workflow = Workflow::Choosing(request);
        self.publish_appearance(window, cx);
        // The pinned native picker has no extension filter/cancel handle. Actual bounded
        // format sniffing accepts JSON/JSONC, XML/binary TextMate and ICLS after selection.
        let selected = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Import Theme (.json, .jsonc, .tmTheme, .plist, .icls)".into()),
        });
        let (completion, sender) = Completion::new();
        let output = completion.clone();
        let task = cx.spawn_in(window, async move |view, cx| {
            let selected = selected.await;
            _ = view.update_in(cx, |this, window, cx| {
                if this.closing || !this.appearance.import_current(&capture) {
                    return;
                }
                match selected {
                    Ok(Ok(Some(mut paths))) if paths.len() == 1 => {
                        let mut capture = capture.clone();
                        capture.path = paths.pop();
                        this.parse_theme_file(capture, window, cx);
                    }
                    Ok(Ok(None)) => {
                        this.appearance.library.import = None;
                        this.appearance.library.workflow = Workflow::Idle;
                        this.publish_appearance(window, cx);
                    }
                    _ => {
                        this.appearance.library.workflow = Workflow::ImportFailed {
                            request,
                            error: Error::ChooserUnavailable,
                        };
                        this.publish_appearance(window, cx);
                    }
                }
            });
            output.finish(Ok(()));
            drop(sender);
        });
        self.appearance.library.jobs.push(Job {
            completion,
            _task: task,
        });
    }
    fn parse_theme_file(
        &mut self,
        capture: ImportCapture,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing
            || !self.appearance.import_current(&capture)
            || !self.appearance.library.advance()
        {
            return;
        }
        let Some(path) = capture.path.clone() else {
            return;
        };
        self.appearance.library.import = Some(capture.clone());
        self.appearance.library.workflow = Workflow::Parsing(capture.request);
        self.publish_appearance(window, cx);
        let (completion, sender) = Completion::new();
        let output = completion.clone();
        let task = cx.spawn_in(window, async move |view, cx| {
            let parsed = cx
                .background_executor()
                .spawn(async move { theme_library::preview_import(&path) })
                .await;
            _ = view.update_in(cx, |this, window, cx| {
                if this.closing
                    || !this.appearance.import_current(&capture)
                    || this.appearance.library.workflow != Workflow::Parsing(capture.request)
                {
                    return;
                }
                this.appearance.library.workflow = match parsed {
                    Ok(preview) => {
                        let Some(serial) = this.appearance.library.serial() else {
                            return;
                        };
                        let Some(token) = PreviewToken::new(capture.request, serial) else {
                            return;
                        };
                        Workflow::Review(ImportReview::new(token, &preview))
                    }
                    Err(error) => Workflow::ImportFailed {
                        request: capture.request,
                        error,
                    },
                };
                this.publish_appearance(window, cx);
            });
            output.finish(Ok(()));
            drop(sender);
        });
        self.appearance.library.jobs.push(Job {
            completion,
            _task: task,
        });
    }
    fn commit_theme(
        &mut self,
        intent: MutationIntent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(store) = self.appearance.library_store.clone() else {
            return;
        };
        if self.closing
            || self.appearance.revision.checked_add(1).is_none()
            || self
                .appearance
                .presentation_revision
                .checked_add(4)
                .is_none()
            || !self.appearance.library.advance()
        {
            return;
        }
        // Reserve once, synchronously, on the ORIGINAL store before yielding.
        let request: MutationRequest = match &intent {
            MutationIntent::Import { review, capture } => {
                if !self.appearance.import_current(capture) {
                    return;
                }
                self.appearance.library.workflow = Workflow::SavingImport(review.clone());
                match capture.request.mode() {
                    ImportMode::Standard => store.reserve_import(review.preview().clone()),
                    ImportMode::Recovery => store.reserve_recovery_import(review.preview().clone()),
                }
            }
            MutationIntent::Remove(removal) => {
                self.appearance.library.workflow = Workflow::Removing(removal.clone());
                store.reserve_remove(removal.theme_id())
            }
        };
        let revision = self.appearance.library.revision;
        let (completion, sender) = Completion::new();
        self.appearance.library.pending = Some(PendingMutation {
            revision,
            completion: completion.clone(),
        });
        self.publish_appearance(window, cx);
        let output = completion.clone();
        let task = cx.spawn_in(window, async move |view, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { request.commit() })
                .await;
            let reconciled = view
                .update_in(cx, |this, window, cx| {
                    this.finish_theme_commit(revision, intent, result, window, cx)
                })
                .unwrap_or(Err(Error::LibraryWrite));
            // Completion includes UI reconciliation and required appearance reservation.
            // Hiding Settings never cancels an already dispatched publication.
            output.finish(reconciled);
            drop(sender);
        });
        self.appearance.library.jobs.push(Job {
            completion,
            _task: task,
        });
    }
    fn finish_theme_commit(
        &mut self,
        revision: u64,
        intent: MutationIntent,
        result: std::result::Result<CommitOutcome, Error>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result {
        if !self
            .appearance
            .library
            .pending
            .as_ref()
            .is_some_and(|p| p.revision == revision)
        {
            return Err(Error::Conflict);
        }
        match result {
            Ok(CommitOutcome::Imported(theme)) => {
                let MutationIntent::Import { review, capture } = &intent else {
                    return Err(Error::Conflict);
                };
                if review.theme() != &theme {
                    return Err(Error::InvalidIdentity);
                }
                if capture.request.mode() == ImportMode::Recovery {
                    self.appearance.themes.retain(|t| !t.is_imported);
                }
                self.appearance.themes.retain(|t| t.id != theme.id);
                self.appearance.themes.push(theme.clone());
                self.appearance.library.browsed = Some(theme.id.clone());
                // Library success is independent from the original automatic editor choice.
                // Never persist a preview ID or overwrite a newer explicit choice.
                if self.appearance.import_current(capture)
                    && self.appearance.revision == capture.preference_revision
                {
                    let mut next = self.appearance.preferences.clone();
                    if next.choose_editor(&theme.id, &self.appearance.themes)
                        && next != self.appearance.preferences
                    {
                        if !self.appearance.advance() {
                            return Err(Error::Conflict);
                        }
                        self.appearance.preferences = next;
                        self.save_appearance(window, cx);
                    }
                }
            }
            Ok(CommitOutcome::Removed(id)) => {
                let MutationIntent::Remove(request) = &intent else {
                    return Err(Error::Conflict);
                };
                if request.theme_id() != id {
                    return Err(Error::InvalidIdentity);
                }
                self.appearance.themes.retain(|t| t.id != id);
                let mut next = self.appearance.preferences.clone();
                next.remove_theme_selection(&id);
                if next != self.appearance.preferences {
                    if !self.appearance.advance() {
                        return Err(Error::Conflict);
                    }
                    self.appearance.preferences = next;
                    self.save_appearance(window, cx);
                }
            }
            Ok(CommitOutcome::Unchanged | CommitOutcome::Superseded) => {
                return self.theme_commit_failed(intent, Error::Conflict, window, cx);
            }
            Err(error) => return self.theme_commit_failed(intent, error, window, cx),
        }
        self.appearance.library_error = None;
        self.appearance.library_recovery_available = false;
        self.appearance.library.workflow = Workflow::Idle;
        self.appearance.library.import = None;
        self.resolve_appearance(window, cx);
        Ok(())
    }
    fn theme_commit_failed(
        &mut self,
        intent: MutationIntent,
        error: Error,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result {
        let requires_reload = matches!(
            error,
            Error::Conflict
                | Error::PublishedUnverified
                | Error::RecoveryRequired
                | Error::LibraryRead
        );
        #[cfg(windows)]
        let requires_reload = requires_reload || error == Error::PublicationUnknown;
        if requires_reload {
            self.appearance.library_error = Some(error);
            self.appearance.library_recovery_available = false;
        }
        self.appearance.library.workflow = match intent {
            MutationIntent::Import { review, capture }
                if self.appearance.library_owner(capture.owner) =>
            {
                Workflow::ImportSaveFailed { review, error }
            }
            MutationIntent::Import { .. } => {
                self.appearance.library_error = Some(error);
                self.appearance.library_recovery_available = false;
                Workflow::Idle
            }
            MutationIntent::Remove(request) => Workflow::RemoveFailed { request, error },
        };
        self.publish_appearance(window, cx);
        Err(error)
    }
    fn reload_theme_library(
        &mut self,
        owner: EntityId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(store) = self.appearance.library_store.clone() else {
            return;
        };
        if self.closing || !self.appearance.library.advance() {
            return;
        }
        let ticket = (self.appearance.library.revision, owner);
        self.appearance.library.reload = Some(ticket);
        self.appearance.library.import = None;
        self.appearance.library.workflow = Workflow::Reloading;
        self.publish_appearance(window, cx);
        let (completion, sender) = Completion::new();
        let output = completion.clone();
        let task = cx.spawn_in(window, async move |view, cx| {
            let loaded = cx
                .background_executor()
                .spawn(async move { store.load_or_builtins() })
                .await;
            _ = view.update_in(cx, |this, window, cx| {
                if this.closing
                    || this.appearance.library.reload != Some(ticket)
                    || !this.appearance.library_owner(owner)
                {
                    return;
                }
                this.appearance.library.reload = None;
                this.appearance.library.pending = None;
                match loaded {
                    Ok(loaded) => {
                        this.appearance.themes = loaded.themes;
                        this.appearance.library_error = loaded.error;
                        this.appearance.library_recovery_available = loaded.recovery_available;
                    }
                    Err(error) => {
                        this.appearance.library_error = Some(error);
                        this.appearance.library_recovery_available = false;
                    }
                }
                this.appearance.library.workflow = Workflow::Idle;
                this.resolve_appearance(window, cx);
            });
            output.finish(Ok(()));
            drop(sender);
        });
        self.appearance.library.jobs.push(Job {
            completion,
            _task: task,
        });
    }
    pub(super) fn invalidate_theme_settings(&mut self, cx: &mut Context<Self>) {
        if let Some(dialog) = &self.appearance.dialog {
            dialog.library.update(cx, |view, cx| view.invalidate(cx));
        }
        self.appearance.library.import = None;
        self.appearance.library.reload = None;
        if let Workflow::ImportSaveFailed { error, .. } | Workflow::RemoveFailed { error, .. } =
            self.appearance.library.workflow
        {
            // Preserve mutation failure after its original review controls are gone.
            // A source parse error grants no authority over the saved library.
            self.appearance.library_error = Some(error);
            self.appearance.library_recovery_available = false;
        }
        if !matches!(
            self.appearance.library.workflow,
            Workflow::SavingImport(_) | Workflow::Removing(_)
        ) {
            self.appearance.library.workflow = Workflow::Idle;
        }
    }
    pub(super) fn register_theme_library_finalizer(&mut self) {
        self.register_close_finalizer(close::finalizers::Finalizer::new(
            close::finalizers::FinalizerKind::ThemeLibrary,
            |this, _| this.appearance.library.revision,
            |this, _, _| {
                this.appearance
                    .library
                    .finalization(this.appearance.library_store.clone())
            },
        ));
    }
}
