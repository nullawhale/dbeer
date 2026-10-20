//! Production appearance owner. No SQL, grid, session or restoration DTO lives here.
use super::*;
use appearance::{
    AppearanceStore, Preferences, ResolvedAppearance, SaveOutcome, Scheme, StoreError,
};
use settings_view::{PersistenceState, Presentation, SettingsAction, SettingsEvent, SettingsView};
use std::sync::{Arc, Mutex};

mod library;
#[cfg(test)]
mod tests;

type SaveResult = Result<SaveOutcome, StoreError>;
/// A broadcast completion: closing the channel wakes every waiter; the result
/// remains available to both the UI watcher and a normal-close finalizer.
#[derive(Clone)]
struct PendingSave {
    revision: u64,
    result: Arc<Mutex<Option<SaveResult>>>,
    done: async_channel::Receiver<()>,
}
impl PendingSave {
    async fn wait(&self) -> SaveResult {
        // The worker writes before dropping its only sender. No waiter consumes
        // the publication evidence or relies on a view callback being scheduled.
        let _ = self.done.recv().await;
        self.result
            .lock()
            .map_err(|_| StoreError::Write)?
            .unwrap_or(Err(StoreError::Write))
    }
}
pub(super) struct DialogOwner {
    pub(super) view: Entity<SettingsView>,
    focus: Option<FocusHandle>,
    pub(super) library: Entity<theme_library_view::ThemeLibraryView>,
    _library_subscription: Subscription,
    pub(super) shortcuts: Entity<shortcut_settings_view::ShortcutSettingsView>,
    _shortcuts_subscription: Subscription,
    _subscription: Subscription,
}
pub(super) struct State {
    pub(super) preferences: Preferences,
    pub(super) themes: Vec<appearance::Theme>,
    pub(super) library_store: Option<theme_library::LibraryStore>,
    pub(super) library_error: Option<theme_library::Error>,
    pub(super) library_recovery_available: bool,
    library: library::LibraryState,
    pub(super) store: Option<AppearanceStore>,
    pub(super) system: Scheme,
    pub(super) resolved: ResolvedAppearance,
    persistence: PersistenceState,
    writable: bool,
    /// Changes only for accepted choices, retry and explicit reload. OS palette
    /// notifications never change this save/normal-close ownership revision.
    revision: u64,
    presentation_revision: u64,
    pending: Option<PendingSave>,
    save_observer: Option<Task<()>>,
    reload: Option<(u64, EntityId)>,
    reload_task: Option<Task<()>>,
    pub(super) dialog: Option<DialogOwner>,
}
fn scheme(appearance: WindowAppearance) -> Scheme {
    match appearance {
        WindowAppearance::Dark | WindowAppearance::VibrantDark => Scheme::Dark,
        WindowAppearance::Light | WindowAppearance::VibrantLight => Scheme::Light,
    }
}
impl State {
    pub(super) fn load(store: Option<&ProfileStore>, os: WindowAppearance) -> Self {
        // Load normalized imports before resolving either saved selector. Builtin
        // assets are checked-in GPUI resources and never require a Mac build.
        let library_store = store.map(|s| theme_library::LibraryStore::new(s.data_owner()));
        let library = library_store.as_ref().map_or_else(
            || {
                theme_library::builtin_themes().map(|themes| theme_library::LoadedLibrary {
                    themes,
                    error: None,
                    recovery_available: false,
                })
            },
            theme_library::LibraryStore::load_or_builtins,
        );
        let (themes, library_error, library_recovery_available) = match library {
            Ok(library) => (library.themes, library.error, library.recovery_available),
            // A damaged builtin is a visible library error, never a hidden
            // successful catalog. Native fallback remains usable.
            Err(error) => (Vec::new(), Some(error), false),
        };
        let appearance_store = store.map(|s| AppearanceStore::new(s.data_owner()));
        let loaded: Option<appearance::LoadedPreferences> = appearance_store
            .as_ref()
            .map(AppearanceStore::load_or_default);
        let writable = loaded.as_ref().is_some_and(|p| p.error.is_none());
        let preferences = loaded.map_or_else(Preferences::default, |p| p.preferences);
        let system = scheme(os);
        let resolved = preferences.resolve(system, &themes);
        Self {
            preferences,
            themes,
            library_store,
            library_error,
            library_recovery_available,
            library: library::LibraryState::default(),
            store: appearance_store,
            system,
            resolved,
            persistence: if writable {
                PersistenceState::Saved
            } else if store.is_none() {
                PersistenceState::PreviewOnly
            } else {
                PersistenceState::ReadOnlyFallback
            },
            writable,
            revision: 0,
            presentation_revision: 0,
            pending: None,
            save_observer: None,
            reload: None,
            reload_task: None,
            dialog: None,
        }
    }
    pub(super) fn apply(&self, window: &mut Window, cx: &mut App) {
        controls::publish_editor_palette(self.resolved.editor.clone(), cx);
        appearance::apply_application(&self.resolved, Some(window), cx);
    }
    fn presentation(&self) -> Presentation {
        Presentation::new(
            self.presentation_revision,
            &self.preferences,
            self.system,
            &self.themes,
            self.persistence,
        )
    }
    fn accepts(&self, owner: EntityId, event: &SettingsEvent, cx: &App) -> bool {
        self.dialog.as_ref().is_some_and(|dialog| {
            dialog.view.entity_id() == owner
                && dialog.view.read(cx).presentation() == &self.presentation()
        }) && self.presentation().accepts(event)
    }
    fn finalization(&self) -> close::finalizers::FinalizationJob {
        let pending = self.pending.clone();
        let original_store = self.store.clone();
        let revision = self.revision;
        close::finalizers::FinalizationJob {
            revision,
            future: Box::pin(async move {
                let _original_store = original_store;
                // Unchanged corrupt/read-only fallback and explicitly labeled
                // preview-only choices have no writable reservation to flush.
                let Some(pending) = pending else {
                    return Ok(());
                };
                if pending.revision != revision {
                    return Err(StoreError::Conflict.to_string());
                }
                match pending.wait().await {
                    Ok(SaveOutcome::Published) => Ok(()),
                    Ok(SaveOutcome::Superseded) => Err(StoreError::Conflict.to_string()),
                    Err(error) => Err(format!(
                        "{error} Open Appearance settings to retry or explicitly reload saved choices."
                    )),
                }
            }),
        }
    }
    fn advance(&mut self) -> bool {
        let Some(next) = self.revision.checked_add(1) else {
            return false;
        };
        if self.presentation_revision.checked_add(2).is_none() {
            return false;
        }
        self.revision = next;
        true
    }
}
impl Workspace {
    pub(super) fn editor_palette(&self, _cx: &App) -> appearance::EditorPalette {
        self.appearance.resolved.editor.clone()
    }
    fn publish_appearance(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(revision) = self.appearance.presentation_revision.checked_add(1) else {
            return;
        };
        self.appearance.presentation_revision = revision;
        if let Some(dialog) = &self.appearance.dialog {
            let presentation = self.appearance.presentation();
            dialog.view.update(cx, |view, cx| {
                view.set_presentation(presentation, window, cx);
            });
            let presentation = self.appearance.library_presentation();
            dialog.library.update(cx, |view, cx| {
                view.set_presentation(presentation, window, cx);
            });
        }
        cx.notify();
    }
    fn resolve_appearance(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.appearance.resolved = self
            .appearance
            .preferences
            .resolve(self.appearance.system, &self.appearance.themes);
        self.appearance.apply(window, cx);
        self.publish_appearance(window, cx);
    }
    pub(super) fn system_appearance_changed(
        &mut self,
        os: WindowAppearance,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.appearance.system = scheme(os);
        // A toolkit system refresh must precede the authoritative named palette.
        // This also reapplies a named workbench scheme when the OS mode is equal.
        gpui_kit::component::Theme::sync_system_appearance(Some(window), cx);
        self.resolve_appearance(window, cx);
    }
    pub(super) fn toggle_theme(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let choice = if self.appearance.resolved.application_scheme == Scheme::Dark {
            "light"
        } else {
            "dark"
        };
        self.choose_appearance(SettingsAction::ChooseApplication(choice.into()), window, cx);
    }
    pub(super) fn show_appearance_settings(
        &mut self,
        focus: Option<FocusHandle>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.show_settings(focus, false, window, cx);
    }
    pub(super) fn show_shortcut_settings(
        &mut self,
        focus: Option<FocusHandle>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.show_settings(focus, true, window, cx);
    }
    fn show_settings(
        &mut self,
        focus: Option<FocusHandle>,
        shortcuts_first: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing || window.has_active_dialog(cx) || self.appearance.dialog.is_some() {
            return;
        }
        self.dismiss_completion();
        self.dismiss_signatures();
        let presentation = self.appearance.presentation();
        let settings = cx.new(|cx| SettingsView::new(presentation, window, cx));
        let (library, library_subscription) = self.mount_theme_library(&settings, window, cx);
        let (shortcuts, shortcuts_subscription) = self.mount_shortcuts(&settings, window, cx);
        settings.update(cx, |view, cx| {
            view.set_additional_sections(
                vec![library.clone().into(), shortcuts.clone().into()],
                cx,
            );
        });
        let owner = settings.entity_id();
        let subscription = cx.subscribe_in(
            &settings,
            window,
            move |this, original, event: &SettingsEvent, window, cx| {
                if original.entity_id() == owner {
                    this.appearance_event(owner, event, window, cx);
                }
            },
        );
        self.appearance.dialog = Some(DialogOwner {
            view: settings.clone(),
            focus,
            library: library.clone(),
            _library_subscription: library_subscription,
            shortcuts: shortcuts.clone(),
            _shortcuts_subscription: shortcuts_subscription,
            _subscription: subscription,
        });
        let weak = cx.entity().downgrade();
        let content = settings.clone();
        window.open_dialog(cx, move |dialog, _, cx| {
            // Capture this rendered request/review before installing Escape. A late
            // old handler must not cancel whichever import happens to be current.
            let projection = library.read(cx).presentation();
            let revision = projection.revision();
            let import_cancel = projection.cancel_action();
            let publication_pending = matches!(
                projection.workflow(),
                theme_library_view::Workflow::SavingImport(_)
                    | theme_library_view::Workflow::Removing(_)
            );
            let cancel = weak.clone();
            let accept = weak.clone();
            dialog
                .title("Settings")
                .accessibility_label("Settings")
                .w(px(680.))
                .overlay_closable(false)
                .close_button(false)
                .on_ok(move |_, _, cx| {
                    _ = accept.update(cx, |this, cx| {
                        if let Some(dialog) = &this.appearance.dialog
                            && dialog.view.entity_id() == owner
                        {
                            dialog.view.update(cx, |view, cx| view.request_close(cx));
                        }
                    });
                    false
                })
                .on_cancel(move |_, _, cx| {
                    _ = cancel.update(cx, |this, cx| {
                        if let Some(dialog) = &this.appearance.dialog
                            && dialog.view.entity_id() == owner
                        {
                            if let Some(theme_library_view::LibraryAction::CancelImport {
                                request,
                                preview,
                            }) = &import_cancel
                            {
                                let (request, preview) = (*request, *preview);
                                dialog.library.update(cx, |view, cx| {
                                    view.request_cancel_import(revision, request, preview, cx);
                                });
                            } else if !publication_pending {
                                dialog.view.update(cx, |view, cx| view.request_close(cx));
                            }
                        }
                    });
                    false
                })
                .child(content.clone())
        });
        // Deliberate initial focus only; status/OS/save publications never focus.
        if shortcuts_first {
            shortcuts.update(cx, |view, cx| view.focus_first(window, cx));
        } else {
            settings.update(cx, |view, cx| view.focus_application(window, cx));
        }
        cx.notify();
    }
    fn appearance_event(
        &mut self,
        owner: EntityId,
        event: &SettingsEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing
            || !window.has_active_dialog(cx)
            || !self.appearance.accepts(owner, event, cx)
        {
            return;
        }
        match &event.action {
            SettingsAction::ChooseApplication(_) | SettingsAction::ChooseEditor(_) => {
                self.choose_appearance(event.action.clone(), window, cx)
            }
            SettingsAction::RetrySave => {
                if self.appearance.advance() {
                    self.save_appearance(window, cx);
                    self.publish_appearance(window, cx);
                }
            }
            SettingsAction::Reload => self.reload_appearance(owner, window, cx),
            SettingsAction::Close => self.close_appearance_settings(owner, window, cx),
        }
    }
    fn choose_appearance(
        &mut self,
        action: SettingsAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing || self.appearance.reload.is_some() {
            return;
        }
        let mut next = self.appearance.preferences.clone();
        let valid = match action {
            SettingsAction::ChooseApplication(id) => {
                next.choose_application(&id, &self.appearance.themes)
            }
            SettingsAction::ChooseEditor(id) => next.choose_editor(&id, &self.appearance.themes),
            _ => false,
        };
        if !valid || next == self.appearance.preferences || !self.appearance.advance() {
            return;
        }
        self.appearance.preferences = next;
        // Reserve latest full preferences synchronously, before the worker or
        // presentation can yield to another selector. Read-only previews reserve nothing.
        if self.appearance.writable {
            self.save_appearance(window, cx);
        }
        self.resolve_appearance(window, cx);
    }
    fn save_appearance(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.appearance.writable {
            return;
        }
        let Some(store) = &self.appearance.store else {
            return;
        };
        let request: appearance::SaveRequest = store.reserve(self.appearance.preferences.clone());
        let (sender, done) = async_channel::bounded(1);
        let pending = PendingSave {
            revision: self.appearance.revision,
            result: Arc::new(Mutex::new(None)),
            done,
        };
        let output = pending.result.clone();
        // The actual worker owns the request/store until completion even when
        // the Settings view closes or an older UI observer is superseded.
        cx.background_executor()
            .spawn(async move {
                let outcome = request.commit();
                if let Ok(mut result) = output.lock() {
                    *result = Some(outcome);
                }
                drop(sender);
            })
            .detach();
        self.appearance.pending = Some(pending.clone());
        self.appearance.persistence = PersistenceState::Saving;
        self.appearance.save_observer = Some(cx.spawn_in(window, async move |view, cx| {
            let result = pending.wait().await;
            _ = view.update_in(cx, |this, window, cx| {
                if this.appearance.revision != pending.revision
                    || !this
                        .appearance
                        .pending
                        .as_ref()
                        .is_some_and(|p| p.revision == pending.revision)
                {
                    return;
                }
                match result {
                    Ok(SaveOutcome::Published) => {
                        this.appearance.persistence = PersistenceState::Saved;
                    }
                    Ok(SaveOutcome::Superseded) => {
                        this.appearance.writable = false;
                        this.appearance.persistence =
                            PersistenceState::SaveFailed(StoreError::Conflict);
                    }
                    Err(error) => {
                        if error != StoreError::Write {
                            this.appearance.writable = false;
                        }
                        this.appearance.persistence = PersistenceState::SaveFailed(error);
                    }
                }
                this.publish_appearance(window, cx);
            });
        }));
    }
    fn reload_appearance(&mut self, owner: EntityId, window: &mut Window, cx: &mut Context<Self>) {
        let Some(store) = self.appearance.store.clone() else {
            return;
        };
        if !self.appearance.advance() {
            return;
        }
        let ticket = (self.appearance.revision, owner);
        self.appearance.reload = Some(ticket);
        self.appearance.pending = None;
        self.appearance.save_observer = None;
        self.appearance.writable = false;
        self.appearance.persistence = PersistenceState::Reloading;
        self.publish_appearance(window, cx);
        self.appearance.reload_task = Some(cx.spawn_in(window, async move |view, cx| {
            let loaded = cx
                .background_executor()
                .spawn(async move { store.load_or_default() })
                .await;
            _ = view.update_in(cx, |this, window, cx| {
                if this.appearance.reload != Some(ticket)
                    || this.appearance.revision != ticket.0
                    || !this
                        .appearance
                        .dialog
                        .as_ref()
                        .is_some_and(|d| d.view.entity_id() == owner)
                {
                    return;
                }
                this.appearance.reload = None;
                this.appearance.preferences = loaded.preferences;
                this.appearance.writable = loaded.error.is_none();
                this.appearance.persistence = if this.appearance.writable {
                    PersistenceState::Saved
                } else {
                    PersistenceState::ReadOnlyFallback
                };
                this.resolve_appearance(window, cx);
            });
        }));
    }
    fn close_appearance_settings(
        &mut self,
        owner: EntityId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self
            .appearance
            .dialog
            .as_ref()
            .is_some_and(|d| d.view.entity_id() == owner)
        {
            return;
        }
        if let Some(dialog) = &self.appearance.dialog {
            dialog
                .shortcuts
                .update(cx, |view, cx| view.dismiss(window, cx));
        }
        self.invalidate_theme_settings(cx);
        let dialog = self.appearance.dialog.take().unwrap();
        dialog.view.read(cx).invalidate_accessibility();
        if self.appearance.reload.take().is_some() {
            self.appearance.reload_task = None;
            self.appearance.writable = false;
            self.appearance.persistence = PersistenceState::ReadOnlyFallback;
            self.publish_appearance(window, cx);
        }
        window.close_dialog(cx);
        self.dismiss_completion();
        self.dismiss_signatures();
        if let Some(focus) = dialog.focus {
            focus.focus(window, cx);
        }
        cx.notify();
    }
    pub(crate) fn prepare_appearance_close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(dialog) = &self.appearance.dialog {
            let owner = dialog.view.entity_id();
            self.close_appearance_settings(owner, window, cx);
        }
    }
    pub(super) fn register_appearance_finalizer(&mut self) {
        self.register_theme_library_finalizer();
        self.register_close_finalizer(close::finalizers::Finalizer::new(
            close::finalizers::FinalizerKind::Appearance,
            |this, _| this.appearance.revision,
            |this, _, _| this.appearance.finalization(),
        ));
    }
}
