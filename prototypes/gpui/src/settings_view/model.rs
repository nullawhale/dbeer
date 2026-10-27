use crate::appearance::{
    AUTOMATIC, EditorPalette, NativeAppearance, Preferences, Scheme, StoreError, Theme,
};
use std::collections::HashSet;

/// An immutable projection of the owner's current persistence state. This view
/// cannot turn a failed load into write authority or reserve/commit a save.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PersistenceState {
    Saved,
    /// Disposable demo/test workspaces deliberately have no personal store.
    PreviewOnly,
    Saving,
    /// Unreadable/corrupt/future preferences remain untouched. Choices can be
    /// previewed; only a successful explicit owner reload restores writes.
    ReadOnlyFallback,
    SaveFailed(StoreError),
    Reloading,
}
impl PersistenceState {
    pub fn error(self) -> Option<StoreError> {
        match self {
            Self::ReadOnlyFallback => Some(StoreError::Read),
            Self::SaveFailed(error) => Some(error),
            Self::Saved | Self::PreviewOnly | Self::Saving | Self::Reloading => None,
        }
    }
    pub fn can_retry(self) -> bool {
        self == Self::SaveFailed(StoreError::Write)
    }
    pub fn can_reload(self) -> bool {
        !matches!(self, Self::PreviewOnly | Self::Saving | Self::Reloading)
    }
    pub fn choices_enabled(self) -> bool {
        self != Self::Reloading
    }
    pub fn summary(self) -> &'static str {
        match self {
            Self::Saved => "Appearance settings are saved.",
            Self::PreviewOnly => {
                "Appearance changes in this disposable workspace are preview only and are not saved."
            }
            Self::Saving => "Saving appearance settings...",
            Self::ReadOnlyFallback | Self::SaveFailed(StoreError::Read) => {
                "These preview changes will be discarded on restart. Reload a repaired settings file to enable future saves."
            }
            Self::SaveFailed(StoreError::Write) => {
                "The current preview remains active. Retry saving or reload saved settings."
            }
            Self::SaveFailed(StoreError::Conflict) => {
                "Reload saved settings before making further persistent changes."
            }
            Self::Reloading => "Reloading saved appearance settings...",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ChoiceGroup {
    Native,
    FollowApplication,
    Schemes,
    Unavailable,
}

/// Menu presentation only. Theme/color data is always the authoritative
/// appearance::Theme, and choices are never a second persisted preferences DTO.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Choice {
    id: String,
    title: String,
    pub(super) group: ChoiceGroup,
    available: bool,
}
impl Choice {
    fn new(id: &str, title: &str, group: ChoiceGroup) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            group,
            available: true,
        }
    }
    pub fn id(&self) -> &str {
        &self.id
    }
    pub fn title(&self) -> &str {
        &self.title
    }
    pub fn available(&self) -> bool {
        self.available
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SettingsAction {
    ChooseApplication(String),
    ChooseEditor(String),
    RetrySave,
    Reload,
    Close,
}
/// The owner must recheck this revision AND the original Settings entity/modal
/// owner before handling the event. Never recapture a newer preference DTO from
/// a stale callback, retry, reload completion, or close finalizer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SettingsEvent {
    pub revision: u64,
    pub action: SettingsAction,
}

/// Read-only value supplied by the authoritative Workspace owner. It contains
/// selected display values and the resolved preview palette, no store, mutable
/// Preferences, document/grid/session, source revision or operation entity.
#[derive(Clone, Debug, PartialEq)]
pub struct Presentation {
    revision: u64,
    application_choices: Vec<Choice>,
    editor_choices: Vec<Choice>,
    application_selection: String,
    editor_selection: String,
    editor_palette: EditorPalette,
    persistence: PersistenceState,
}
impl Presentation {
    pub fn new(
        revision: u64,
        preferences: &Preferences,
        system: Scheme,
        themes: &[Theme],
        persistence: PersistenceState,
    ) -> Self {
        let mut application_choices = NativeAppearance::ALL
            .iter()
            .map(|native| Choice::new(native.id(), native.title(), ChoiceGroup::Native))
            .collect::<Vec<_>>();
        let mut editor_choices = vec![Choice::new(
            AUTOMATIC,
            "Follow App Appearance",
            ChoiceGroup::FollowApplication,
        )];
        let mut ids: HashSet<&str> = ["system", "light", "dark", "native", AUTOMATIC]
            .into_iter()
            .collect();
        // Same library and source order as the owner. Refuse invalid/ambiguous
        // rows rather than inventing a hardcoded or separately parsed catalog.
        for theme in themes {
            if theme.is_valid() && ids.insert(&theme.id) {
                let choice = Choice::new(&theme.id, &theme.name, ChoiceGroup::Schemes);
                application_choices.push(choice.clone());
                editor_choices.push(choice);
            }
        }
        let application_selection = preferences.application_selection().to_owned();
        let editor_selection = preferences.editor_color_theme.clone();
        retain_unavailable(
            &mut application_choices,
            &application_selection,
            "Unavailable saved appearance (using fallback colors)",
        );
        retain_unavailable(
            &mut editor_choices,
            &editor_selection,
            "Unavailable saved scheme (following app appearance)",
        );
        Self {
            revision,
            application_choices,
            editor_choices,
            application_selection,
            editor_selection,
            editor_palette: preferences.resolve(system, themes).editor,
            persistence,
        }
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn application_choices(&self) -> &[Choice] {
        &self.application_choices
    }
    pub fn editor_choices(&self) -> &[Choice] {
        &self.editor_choices
    }
    pub fn application_selection(&self) -> &str {
        &self.application_selection
    }
    pub fn editor_selection(&self) -> &str {
        &self.editor_selection
    }
    pub fn editor_palette(&self) -> &EditorPalette {
        &self.editor_palette
    }
    pub fn persistence(&self) -> PersistenceState {
        self.persistence
    }
    pub fn accepts(&self, event: &SettingsEvent) -> bool {
        if event.revision != self.revision {
            return false;
        }
        match &event.action {
            SettingsAction::ChooseApplication(id) => self.can_choose(&self.application_choices, id),
            SettingsAction::ChooseEditor(id) => self.can_choose(&self.editor_choices, id),
            SettingsAction::RetrySave => self.persistence.can_retry(),
            SettingsAction::Reload => self.persistence.can_reload(),
            SettingsAction::Close => true,
        }
    }
    fn can_choose(&self, choices: &[Choice], id: &str) -> bool {
        self.persistence.choices_enabled()
            && choices
                .iter()
                .any(|choice| choice.id == id && choice.available)
    }
}
fn retain_unavailable(choices: &mut Vec<Choice>, id: &str, title: &str) {
    if !choices.iter().any(|choice| choice.id == id) {
        choices.push(Choice {
            id: id.into(),
            title: title.into(),
            group: ChoiceGroup::Unavailable,
            available: false,
        });
    }
}
