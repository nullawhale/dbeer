use crate::shortcuts::{
    BindingChoice, CaptureOutcome, ConfigurableCommand, InputSafety, NativePlatform, Preferences,
    Recording, Shortcut, StoreError, ValidationError,
};
use gpui_kit::KeyDownEvent;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PersistenceState {
    Saved,
    PreviewOnly,
    Saving,
    ReadOnlyFallback(StoreError),
    SaveFailed(StoreError),
    Reloading,
    Recovering,
}

impl PersistenceState {
    pub fn error(self) -> Option<StoreError> {
        match self {
            Self::ReadOnlyFallback(error) | Self::SaveFailed(error) => Some(error),
            _ => None,
        }
    }
    pub fn can_edit(self) -> bool {
        matches!(
            self,
            Self::Saved | Self::PreviewOnly | Self::Saving | Self::SaveFailed(StoreError::Write)
        )
    }
    pub fn can_retry(self) -> bool {
        self == Self::SaveFailed(StoreError::Write)
    }
    pub fn can_reload(self) -> bool {
        !matches!(
            self,
            Self::PreviewOnly | Self::Saving | Self::Reloading | Self::Recovering
        )
    }
    pub fn can_recover(self) -> bool {
        matches!(
            self,
            Self::ReadOnlyFallback(StoreError::Read | StoreError::InvalidBindings)
        )
    }
    pub fn summary(self) -> &'static str {
        match self {
            Self::Saved => "Shortcut settings are saved.",
            Self::PreviewOnly => {
                "Shortcut changes are previews in this disposable workspace. Restart discards them."
            }
            Self::Saving => "Saving shortcut settings...",
            Self::ReadOnlyFallback(_) => {
                "Default shortcuts are active. Settings are read only until reload or explicit recovery succeeds. Existing preferences are preserved."
            }
            Self::SaveFailed(StoreError::Write) => {
                "Current shortcuts remain active. Retry saving or reload saved shortcuts."
            }
            Self::SaveFailed(_) => "Reload saved shortcuts before making further changes.",
            Self::Reloading => "Reloading saved shortcuts...",
            Self::Recovering => {
                "Recovering default shortcuts and preserving the original preferences..."
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MappingSource {
    Default,
    Custom,
    Unbound,
}
impl MappingSource {
    pub fn label(self) -> &'static str {
        match self {
            Self::Default => "Default",
            Self::Custom => "Custom",
            Self::Unbound => "Unbound",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub command: ConfigurableCommand,
    pub current: Option<String>,
    pub default: Option<String>,
    pub source: MappingSource,
    pub has_override: bool,
}
impl Row {
    pub fn title(&self) -> &'static str {
        self.command.title()
    }
    pub fn current_label(&self) -> &str {
        self.current.as_deref().unwrap_or("Unbound")
    }
    pub fn default_label(&self) -> &str {
        self.default.as_deref().unwrap_or("Unbound")
    }
}

/// Neither this snapshot nor events are serializable preference DTOs. The
/// clone exists solely to validate a candidate using the actual shortcut core.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Presentation {
    revision: u64,
    preferences: Preferences,
    platform: NativePlatform,
    persistence: PersistenceState,
}
impl Presentation {
    pub fn new(
        revision: u64,
        preferences: &Preferences,
        platform: NativePlatform,
        persistence: PersistenceState,
    ) -> Result<Self, ValidationError> {
        preferences.validated_bindings(platform)?;
        Ok(Self {
            revision,
            preferences: preferences.clone(),
            platform,
            persistence,
        })
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn persistence(&self) -> PersistenceState {
        self.persistence
    }
    pub fn rows(&self) -> impl Iterator<Item = Row> + '_ {
        ConfigurableCommand::ALL.into_iter().map(|command| {
            let has_override = self.preferences.has_override(command);
            let current = self.preferences.menu_label(command, self.platform);
            Row {
                command,
                source: if !has_override {
                    MappingSource::Default
                } else if current.is_none() {
                    MappingSource::Unbound
                } else {
                    MappingSource::Custom
                },
                current,
                default: Preferences::default().menu_label(command, self.platform),
                has_override,
            }
        })
    }
    pub fn candidate(&self, edit: &Edit) -> Result<Preferences, ValidationError> {
        let mut candidate = self.preferences.clone();
        match edit {
            Edit::Bind(command, shortcut) => candidate.set(
                *command,
                BindingChoice::Bound(shortcut.clone()),
                self.platform,
            )?,
            Edit::Clear(command) => candidate.clear(*command, self.platform)?,
            Edit::RestoreDefault(command) => candidate.restore_default(*command, self.platform)?,
            Edit::ResetAll => candidate.reset_defaults(),
        }
        candidate.validated_bindings(self.platform)?;
        Ok(candidate)
    }
    pub fn accepts(&self, event: &Event) -> bool {
        event.scope.revision == self.revision
            && match &event.action {
                Action::Edit(edit) => self.persistence.can_edit() && self.candidate(edit).is_ok(),
                Action::RetrySave => self.persistence.can_retry(),
                Action::Reload => self.persistence.can_reload(),
                Action::RecoverDefaults => self.persistence.can_recover(),
            }
    }
}

/// All callbacks retain their original rendered scope. A new recorder, blur,
/// presentation or dismissal invalidates old callbacks even at one revision.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Scope {
    pub revision: u64,
    pub epoch: u64,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Edit {
    Bind(ConfigurableCommand, Shortcut),
    Clear(ConfigurableCommand),
    RestoreDefault(ConfigurableCommand),
    ResetAll,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Edit(Edit),
    RetrySave,
    Reload,
    RecoverDefaults,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Event {
    pub scope: Scope,
    pub action: Action,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct RecordingToken {
    pub scope: Scope,
    pub command: ConfigurableCommand,
}
struct Session {
    token: RecordingToken,
    recording: Recording,
}
pub(super) struct State {
    pub presentation: Presentation,
    epoch: u64,
    exhausted: bool,
    dismissed: bool,
    session: Option<Session>,
    pub pending: Option<Event>,
    pub error: Option<(Option<ConfigurableCommand>, ValidationError)>,
}
impl State {
    pub fn new(presentation: Presentation) -> Self {
        Self {
            presentation,
            epoch: 0,
            exhausted: false,
            dismissed: false,
            session: None,
            pending: None,
            error: None,
        }
    }
    pub fn scope(&self) -> Scope {
        Scope {
            revision: self.presentation.revision(),
            epoch: self.epoch,
        }
    }
    pub fn current(&self, scope: Scope) -> bool {
        !self.dismissed && !self.exhausted && self.scope() == scope
    }
    fn advance(&mut self) {
        self.pending = None;
        if let Some(session) = &mut self.session {
            session.recording.cancel();
        }
        self.session = None;
        match self.epoch.checked_add(1) {
            Some(epoch) => self.epoch = epoch,
            None => self.exhausted = true,
        }
    }
    pub fn token(&self) -> Option<RecordingToken> {
        self.session.as_ref().map(|session| session.token)
    }
    pub fn editable(&self) -> bool {
        !self.dismissed
            && !self.exhausted
            && self.pending.is_none()
            && self.presentation.persistence.can_edit()
    }
    /// The view must obtain and check the actual original Input focus first.
    pub fn begin(
        &mut self,
        scope: Scope,
        command: ConfigurableCommand,
        focused: bool,
    ) -> Option<RecordingToken> {
        if !self.current(scope) || !self.editable() || !focused {
            return None;
        }
        self.advance();
        if self.exhausted {
            return None;
        }
        let token = RecordingToken {
            scope: self.scope(),
            command,
        };
        self.session = Some(Session {
            token,
            recording: Recording::begin(command),
        });
        self.error = None;
        Some(token)
    }
    pub fn cancel(&mut self, token: RecordingToken) {
        if self.token() == Some(token) {
            self.advance();
        }
    }
    pub fn focus_lost(&mut self, token: RecordingToken) {
        let pending_capture = self.pending.as_ref().is_some_and(|event| {
            event.scope == token.scope && matches!(&event.action, Action::Edit(Edit::Bind(command, _)) if *command == token.command)
        });
        if self.token() == Some(token) || pending_capture {
            self.advance();
        }
    }
    pub fn dismiss(&mut self) {
        self.advance();
        self.dismissed = true;
    }
    pub fn set_presentation(&mut self, next: Presentation) -> bool {
        if self.dismissed || next.revision() <= self.presentation.revision() {
            return !self.dismissed && next == self.presentation;
        }
        self.advance();
        self.error = None;
        self.presentation = next;
        true
    }
    pub fn event_is_current(&self, event: &Event) -> bool {
        !self.dismissed && self.pending.as_ref() == Some(event) && self.presentation.accepts(event)
    }
    pub fn request(&mut self, scope: Scope, action: Action) -> Option<Event> {
        if !self.current(scope) || self.pending.is_some() {
            return None;
        }
        let event = Event { scope, action };
        if let Action::Edit(edit) = &event.action {
            if !self.presentation.persistence.can_edit() {
                return None;
            }
            if let Err(error) = self.presentation.candidate(edit) {
                self.error = Some((
                    match edit {
                        Edit::Bind(command, _)
                        | Edit::Clear(command)
                        | Edit::RestoreDefault(command) => Some(*command),
                        Edit::ResetAll => None,
                    },
                    error,
                ));
                return None;
            }
        }
        if !self.presentation.accepts(&event) {
            return None;
        }
        self.advance();
        if self.exhausted {
            return None;
        }
        self.error = None;
        self.pending = Some(event.clone());
        Some(event)
    }
    pub fn capture(
        &mut self,
        token: RecordingToken,
        focused: bool,
        event: &KeyDownEvent,
        safety: InputSafety,
    ) -> (CaptureOutcome, Option<Event>) {
        if !self.current(token.scope) || self.token() != Some(token) {
            return (CaptureOutcome::Inactive, None);
        }
        if !focused {
            self.cancel(token);
            return (CaptureOutcome::Inactive, None);
        }
        // Native AltGr can arrive as Ctrl+Alt even when character priority was
        // lost by a backend. Preserve the original input handler in that case.
        if event.keystroke.modifiers.control && event.keystroke.modifiers.alt {
            return (CaptureOutcome::PassThrough, None);
        }
        let mut candidate = self.presentation.preferences.clone();
        let outcome = self.session.as_mut().unwrap().recording.capture(
            &mut candidate,
            event,
            safety,
            self.presentation.platform,
        );
        match outcome {
            CaptureOutcome::Bound => {
                let Some(shortcut) = candidate.shortcut(token.command, self.presentation.platform)
                else {
                    return (CaptureOutcome::Inactive, None);
                };
                let event = self.request(
                    token.scope,
                    Action::Edit(Edit::Bind(token.command, shortcut)),
                );
                (outcome, event)
            }
            CaptureOutcome::Cancelled | CaptureOutcome::Traverse { .. } => {
                self.cancel(token);
                (outcome, None)
            }
            CaptureOutcome::Rejected(error) => {
                self.error = Some((Some(token.command), error));
                (outcome, None)
            }
            _ => (outcome, None),
        }
    }
}

#[cfg(test)]
mod epoch_tests {
    use super::*;
    #[test]
    fn exhausted_epoch_refuses_instead_of_reusing_a_rendered_scope() {
        let presentation = Presentation::new(
            1,
            &Preferences::default(),
            NativePlatform::Windows,
            PersistenceState::Saved,
        )
        .unwrap();
        let mut state = State::new(presentation);
        state.epoch = u64::MAX;
        let scope = state.scope();
        assert!(
            state
                .begin(scope, ConfigurableCommand::RunCurrent, true)
                .is_none()
        );
        assert_eq!(state.scope().epoch, u64::MAX);
        assert!(!state.current(scope));
        assert!(!state.editable());
        assert!(state.request(scope, Action::Reload).is_none());
    }
}
