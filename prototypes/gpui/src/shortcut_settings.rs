//! Workspace shortcut authority, original Settings projection and latest close publication.
use super::*;
use shortcut_settings_view::{Action, Event, PersistenceState, Presentation, ShortcutSettingsView};
use shortcuts::{
    ConfigurableCommand, Evidence, InputSafety, NativePlatform, Preferences, SaveOutcome,
    ShortcutStore, StoreError,
};
use std::sync::{Arc, Mutex};

#[cfg(test)]
mod tests;

type SaveResult = Result<SaveOutcome, StoreError>;
#[derive(Clone)]
struct Completion {
    result: Arc<Mutex<Option<SaveResult>>>,
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
    fn finish(&self, result: SaveResult) {
        if let Ok(mut output) = self.result.lock() {
            *output = Some(result);
        }
    }
    async fn wait(&self) -> SaveResult {
        let _ = self.done.recv().await;
        self.result
            .lock()
            .map_err(|_| StoreError::Write)?
            .unwrap_or(Err(StoreError::Write))
    }
}
#[derive(Clone)]
struct PendingSave {
    revision: u64,
    reservation: u64,
    completion: Completion,
}
struct Job {
    completion: Completion,
    _task: Task<()>,
}
pub(super) struct State {
    pub(super) preferences: Preferences,
    store: Option<ShortcutStore>,
    platform: NativePlatform,
    persistence: PersistenceState,
    revision: u64,
    presentation_revision: u64,
    /// An accepted in-memory writable edit needs publication. Failed startup
    /// defaults and disposable previews have no such obligation.
    dirty: bool,
    pending: Option<PendingSave>,
    observer: Option<Task<()>>,
    io: Option<(u64, EntityId)>,
    jobs: Vec<Job>,
}
impl State {
    pub(super) fn load(profile_store: Option<&ProfileStore>) -> Self {
        let platform = NativePlatform::current();
        let store = profile_store.map(|s| ShortcutStore::new(s.data_owner()));
        let loaded: Option<shortcuts::LoadedPreferences> =
            store.as_ref().map(|s| s.load_or_default(platform));
        let persistence = match loaded.as_ref() {
            Some(loaded) => loaded
                .error
                .map_or(PersistenceState::Saved, PersistenceState::ReadOnlyFallback),
            None => PersistenceState::PreviewOnly,
        };
        Self {
            preferences: loaded.map_or_else(Preferences::default, |p| p.preferences),
            store,
            platform,
            persistence,
            revision: 0,
            presentation_revision: 0,
            dirty: false,
            pending: None,
            observer: None,
            io: None,
            jobs: Vec::new(),
        }
    }
    fn presentation(&self) -> Presentation {
        // Only validated core mutations or strict store loads reach this owner.
        Presentation::new(
            self.presentation_revision,
            &self.preferences,
            self.platform,
            self.persistence,
        )
        .expect("Workspace shortcut preferences remain validated")
    }
    fn advance(&mut self) -> bool {
        let Some(next) = self.revision.checked_add(1) else {
            return false;
        };
        if self.presentation_revision.checked_add(3).is_none() {
            return false;
        }
        self.revision = next;
        self.jobs.retain(|job| !job.completion.done.is_closed());
        true
    }
    fn finalization(&self) -> close::finalizers::FinalizationJob {
        let revision = self.revision;
        let dirty = self.dirty;
        let pending = self.pending.clone();
        let store = self.store.clone();
        let jobs = self
            .jobs
            .iter()
            .map(|job| job.completion.clone())
            .collect::<Vec<_>>();
        close::finalizers::FinalizationJob {
            revision,
            future: Box::pin(async move {
                // IO jobs include their original foreground reconciliation. A
                // recovery/reload completion changes revision and reflushes.
                for job in jobs {
                    let _ = job.wait().await;
                }
                if !dirty {
                    return Ok(());
                }
                let Some(pending) = pending else {
                    return Err(StoreError::Write.to_string());
                };
                if pending.revision > revision {
                    return Err(StoreError::Conflict.to_string());
                }
                match pending.completion.wait().await {
                    Ok(SaveOutcome::Published)
                        if store.as_ref().is_some_and(ShortcutStore::latest_saved) =>
                    {
                        Ok(())
                    }
                    Ok(_) => Err(StoreError::Conflict.to_string()),
                    Err(error) => Err(format!(
                        "{error} Open Shortcuts settings to retry saving or explicitly reload."
                    )),
                }
            }),
        }
    }
}
impl Workspace {
    pub(super) fn mount_shortcuts(
        &mut self,
        settings: &Entity<settings_view::SettingsView>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> (Entity<ShortcutSettingsView>, Subscription) {
        let owner = settings.entity_id();
        let presentation = self.shortcuts.presentation();
        let section = cx.new(|cx| ShortcutSettingsView::new(presentation, window, cx));
        let identity = section.entity_id();
        let subscription = cx.subscribe_in(
            &section,
            window,
            move |this, original, event: &Event, window, cx| {
                if original.entity_id() == identity {
                    this.shortcut_event(owner, identity, event, window, cx);
                }
            },
        );
        (section, subscription)
    }
    fn publish_shortcuts(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(next) = self.shortcuts.presentation_revision.checked_add(1) else {
            return;
        };
        self.shortcuts.presentation_revision = next;
        if let Some(dialog) = &self.appearance.dialog {
            let presentation = self.shortcuts.presentation();
            dialog.shortcuts.update(cx, |view, cx| {
                view.set_presentation(presentation, window, cx);
            });
        }
        self.refresh_native_menus(window, cx);
        cx.notify();
    }
    fn shortcut_event(
        &mut self,
        owner: EntityId,
        section: EntityId,
        event: &Event,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing || self.shortcuts.io.is_some() || !window.has_active_dialog(cx) {
            return;
        }
        let presentation = self.shortcuts.presentation();
        if !self.appearance.dialog.as_ref().is_some_and(|d| {
            d.view.entity_id() == owner
                && d.shortcuts.entity_id() == section
                && d.shortcuts.read(cx).presentation() == &presentation
                && d.shortcuts.read(cx).event_is_current(event, window, cx)
        }) || !presentation.accepts(event)
        {
            return;
        }
        // Candidate is recomputed against the CURRENT owner, never the view's
        // validation clone or an event relabeled with a current revision.
        let candidate = match &event.action {
            Action::Edit(edit) => match presentation.candidate(edit) {
                Ok(candidate) => Some(candidate),
                Err(_) => return,
            },
            _ => None,
        };
        if !self.shortcuts.advance() {
            return;
        }
        match &event.action {
            Action::Edit(_) => {
                let candidate = candidate.unwrap();
                if candidate != self.shortcuts.preferences {
                    self.shortcuts.preferences = candidate;
                    self.save_shortcuts(window, cx);
                }
                self.publish_shortcuts(window, cx);
            }
            Action::RetrySave => {
                self.save_shortcuts(window, cx);
                self.publish_shortcuts(window, cx);
            }
            Action::Reload => self.read_shortcuts(owner, false, window, cx),
            Action::RecoverDefaults => self.read_shortcuts(owner, true, window, cx),
        }
    }
    fn save_shortcuts(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(store) = self.shortcuts.store.clone() else {
            return;
        };
        self.shortcuts.dirty = true;
        // This reservation MUST precede spawn and presentation publication.
        let request: shortcuts::SaveRequest =
            match store.reserve(self.shortcuts.preferences.clone(), self.shortcuts.platform) {
                Ok(request) => request,
                Err(error) => {
                    self.shortcuts.pending = None;
                    self.shortcuts.persistence = PersistenceState::SaveFailed(error);
                    return;
                }
            };
        let (completion, sender) = Completion::new();
        let pending = PendingSave {
            revision: self.shortcuts.revision,
            reservation: request.revision(),
            completion: completion.clone(),
        };
        let output = completion;
        cx.background_executor()
            .spawn(async move {
                output.finish(request.commit());
                drop(sender);
            })
            .detach();
        self.shortcuts.pending = Some(pending.clone());
        self.shortcuts.persistence = PersistenceState::Saving;
        self.shortcuts.observer = Some(cx.spawn_in(window, async move |view, cx| {
            let result = pending.completion.wait().await;
            _ = view.update_in(cx, |this, window, cx| {
                // A handled no-change request may advance the UI revision.
                // The retained latest reservation, rather than that UI epoch,
                // proves which exact preference value this result belongs to.
                if this.shortcuts.io.is_some()
                    || !this
                        .shortcuts
                        .pending
                        .as_ref()
                        .is_some_and(|p| p.reservation == pending.reservation)
                {
                    return;
                }
                this.shortcuts.persistence = match result {
                    Ok(SaveOutcome::Published)
                        if this
                            .shortcuts
                            .store
                            .as_ref()
                            .is_some_and(ShortcutStore::latest_saved) =>
                    {
                        PersistenceState::Saved
                    }
                    Ok(_) => PersistenceState::SaveFailed(StoreError::Conflict),
                    Err(error) => PersistenceState::SaveFailed(error),
                };
                this.publish_shortcuts(window, cx);
            });
        }));
    }
    fn read_shortcuts(
        &mut self,
        owner: EntityId,
        recover: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(store) = self.shortcuts.store.clone() else {
            return;
        };
        if self.shortcuts.revision.checked_add(1).is_none() {
            self.shortcuts.persistence = PersistenceState::SaveFailed(StoreError::Unavailable);
            self.publish_shortcuts(window, cx);
            return;
        }
        let ticket = (self.shortcuts.revision, owner);
        let platform = self.shortcuts.platform;
        self.shortcuts.io = Some(ticket);
        self.shortcuts.persistence = if recover {
            PersistenceState::Recovering
        } else {
            PersistenceState::Reloading
        };
        self.publish_shortcuts(window, cx);
        let (completion, sender) = Completion::new();
        let output = completion.clone();
        let task = cx.spawn_in(window, async move |view, cx| {
            let loaded = cx
                .background_executor()
                .spawn(async move {
                    if recover {
                        match store.recover_defaults(platform)? {
                            SaveOutcome::Published => Ok(Preferences::default()),
                            SaveOutcome::Superseded => Err(StoreError::Conflict),
                        }
                    } else {
                        store.load(platform)
                    }
                })
                .await;
            let result = loaded
                .as_ref()
                .map(|_| SaveOutcome::Published)
                .map_err(|e| *e);
            _ = view.update_in(cx, |this, window, cx| {
                // Retain this original request through Settings dismissal and
                // close. No newer edit/request may acquire authority during IO.
                if this.shortcuts.io != Some(ticket) || this.shortcuts.revision != ticket.0 {
                    return;
                }
                this.shortcuts.io = None;
                if !this.shortcuts.advance() {
                    return;
                }
                match loaded {
                    Ok(preferences) => {
                        this.shortcuts.preferences = preferences;
                        this.shortcuts.persistence = PersistenceState::Saved;
                        this.shortcuts.dirty = false;
                        this.shortcuts.pending = None;
                        this.shortcuts.observer = None;
                    }
                    Err(error) => {
                        this.shortcuts.persistence = if this.shortcuts.dirty {
                            PersistenceState::SaveFailed(error)
                        } else {
                            PersistenceState::ReadOnlyFallback(error)
                        };
                    }
                }
                this.publish_shortcuts(window, cx);
            });
            output.finish(result);
            drop(sender);
        });
        self.shortcuts.jobs.push(Job {
            completion,
            _task: task,
        });
    }
    pub(super) fn register_shortcut_finalizer(&mut self) {
        self.register_close_finalizer(close::finalizers::Finalizer::new(
            close::finalizers::FinalizerKind::Shortcuts,
            |this, _| this.shortcuts.revision,
            |this, _, _| this.shortcuts.finalization(),
        ));
    }
    pub(super) fn shortcut_label(&self, command: CommandId, title: &str) -> String {
        ConfigurableCommand::ALL
            .into_iter()
            .find(|id| id.command() == command)
            .and_then(|id| {
                self.shortcuts
                    .preferences
                    .menu_label(id, self.shortcuts.platform)
            })
            .map_or_else(|| title.to_owned(), |key| format!("{title}  {key}"))
    }
    pub(super) fn command_label(&self, command: CommandId) -> String {
        self.shortcut_label(command, command.title())
    }
    /// Original synchronous native callback. Settings/recorders and all other
    /// modal inputs get precedence. No generic candidate binding is installed.
    pub(super) fn shortcut_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing || window.has_active_dialog(cx) || window.has_active_prompt() {
            return;
        }
        let context = self.command_context(CommandId::Stop, None, window, cx);
        let marked = match context.focus {
            commands::CommandFocus::Editor => {
                let Some(editor) = self.tabs.get(self.active).map(|t| t.editor.clone()) else {
                    return;
                };
                editor.update(cx, |input, cx| {
                    if input.marked_text_range(window, cx).is_some() {
                        Evidence::Active
                    } else {
                        Evidence::Clear
                    }
                })
            }
            commands::CommandFocus::TextInput => return,
            // Proven non-text focus has no original composing input. Unknown
            // native dead-key/compose evidence still passes through below.
            commands::CommandFocus::Grid | commands::CommandFocus::Workspace => Evidence::Clear,
        };
        let safety = InputSafety::from_gpui(event, marked);
        let Some(command) =
            self.shortcuts
                .preferences
                .command_for_native(event, safety, self.shortcuts.platform)
        else {
            return;
        };
        // Fixed registry commands retain their original routes; this callback
        // replaces only the five configurable mappings, including explicit Unbound.
        if !ConfigurableCommand::ALL
            .iter()
            .any(|id| id.command() == command)
        {
            return;
        }
        let Some(binding) = self
            .shortcuts
            .preferences
            .validated_bindings(self.shortcuts.platform)
            .ok()
            .and_then(|bindings| {
                bindings
                    .into_iter()
                    .find(|binding| binding.command == command)
            })
        else {
            return;
        };
        if binding.scope != "DBeerWorkspace" && context.focus != commands::CommandFocus::Editor {
            return;
        }
        // Refused operations preserve the input's native event path as well.
        let current = self.command_context(command, None, window, cx);
        if commands::availability(command, &current).is_err() {
            return;
        }
        self.command(command, CommandOrigin::Shortcut, None, window, cx);
        window.prevent_default();
        cx.stop_propagation();
    }
}
