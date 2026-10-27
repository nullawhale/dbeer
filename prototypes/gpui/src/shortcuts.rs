//! Validated shortcut preferences and recorder. Common command capture remains authoritative.

mod recording;
mod store;
#[cfg(test)]
mod tests;

pub type CaptureOutcome = recording::CaptureOutcome;
pub type Evidence = recording::Evidence;
pub type InputSafety = recording::InputSafety;
pub type Recording = recording::Recording;
pub type LoadedPreferences = store::LoadedPreferences;
pub type SaveOutcome = store::SaveOutcome;
pub type SaveRequest = store::SaveRequest;
pub type ShortcutStore = store::ShortcutStore;
pub type StoreError = store::StoreError;
#[cfg(test)]
use crate::commands::DispatchCommand;
use crate::commands::{CommandId, DEFAULT_SHORTCUTS};
#[cfg(test)]
use gpui_kit::KeyBinding;
use gpui_kit::Keystroke;
use serde::{Deserialize, Serialize};

pub const VERSION: u32 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NativePlatform {
    Windows,
    Linux,
    MacDevelopment,
}
impl NativePlatform {
    pub fn current() -> Self {
        if cfg!(target_os = "windows") {
            Self::Windows
        } else if cfg!(target_os = "macos") {
            Self::MacDevelopment
        } else {
            Self::Linux
        }
    }
}

/// Stable storage IDs map to the existing registry, rather than a second action.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ConfigurableCommand {
    #[serde(rename = "query.runCurrent")]
    RunCurrent,
    #[serde(rename = "query.runScript")]
    RunScript,
    #[serde(rename = "query.stop")]
    Stop,
    #[serde(rename = "query.runToJSON")]
    RunToJson,
    #[serde(rename = "query.runToCSV")]
    RunToCsv,
}
impl ConfigurableCommand {
    pub const ALL: [Self; 5] = [
        Self::RunCurrent,
        Self::RunScript,
        Self::Stop,
        Self::RunToJson,
        Self::RunToCsv,
    ];
    pub(crate) fn command(self) -> CommandId {
        match self {
            Self::RunCurrent => CommandId::RunCurrent,
            Self::RunScript => CommandId::RunScript,
            Self::Stop => CommandId::Stop,
            Self::RunToJson => CommandId::RunToJson,
            Self::RunToCsv => CommandId::RunToCsv,
        }
    }
    pub fn title(self) -> &'static str {
        self.command().title()
    }
    fn scope(self) -> &'static str {
        // Stop is also useful while a table operation owns focus. Its common
        // availability/captured operation gate must still run at dispatch.
        if self == Self::Stop {
            "DBeerWorkspace"
        } else {
            "DBeerSqlEditor > Input"
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Modifiers {
    pub control: bool,
    pub alt: bool,
    pub shift: bool,
    pub platform: bool,
}
/// GPUI's backend-generated key identity; neither a physical position nor text.
/// No macOS key-code table, scan-code conversion or key_char fallback is used.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeyBasis {
    NativeKey,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Shortcut {
    pub basis: KeyBasis,
    pub key: String,
    pub modifiers: Modifiers,
}
impl Shortcut {
    pub fn new(key: impl Into<String>, modifiers: Modifiers) -> Self {
        Self {
            basis: KeyBasis::NativeKey,
            key: key.into(),
            modifiers,
        }
    }
    fn from_suffix(suffix: &str, platform: NativePlatform) -> Result<Self, ValidationError> {
        let primary = if platform == NativePlatform::MacDevelopment {
            "cmd"
        } else {
            "ctrl"
        };
        let stroke = Keystroke::parse(&format!("{primary}-{suffix}"))
            .map_err(|_| ValidationError::Schema)?;
        if stroke.modifiers.function || stroke.key_char.is_some() {
            return Err(ValidationError::Schema);
        }
        Ok(Self::new(
            stroke.key,
            Modifiers {
                control: stroke.modifiers.control,
                alt: stroke.modifiers.alt,
                shift: stroke.modifiers.shift,
                platform: stroke.modifiers.platform,
            },
        ))
    }
    /// Exact GPUI identity; do not use Keystroke::should_match's character alias.
    pub fn matches_native(&self, stroke: &Keystroke) -> bool {
        !stroke.modifiers.function
            && self.key == stroke.key
            && self.modifiers
                == Modifiers {
                    control: stroke.modifiers.control,
                    alt: stroke.modifiers.alt,
                    shift: stroke.modifiers.shift,
                    platform: stroke.modifiers.platform,
                }
    }
    #[cfg(test)]
    pub fn keystroke(&self) -> Keystroke {
        Keystroke {
            key: self.key.clone(),
            key_char: None,
            modifiers: gpui_kit::Modifiers {
                control: self.modifiers.control,
                alt: self.modifiers.alt,
                shift: self.modifiers.shift,
                platform: self.modifiers.platform,
                function: false,
            },
        }
    }
    #[cfg(test)]
    pub fn binding_text(&self) -> String {
        let m = self.modifiers;
        format!(
            "{}{}{}{}{}",
            if m.control { "ctrl-" } else { "" },
            if m.alt { "alt-" } else { "" },
            if m.shift { "shift-" } else { "" },
            if m.platform { "cmd-" } else { "" },
            self.key
        )
    }
    /// Same native identity used by matching, with native desktop modifier names.
    pub fn label(&self, platform: NativePlatform) -> String {
        let m = self.modifiers;
        let mut parts = Vec::new();
        if m.control {
            parts.push("Ctrl".to_string());
        }
        if m.alt {
            parts.push("Alt".to_string());
        }
        if m.shift {
            parts.push("Shift".to_string());
        }
        if m.platform {
            parts.push(
                match platform {
                    NativePlatform::Windows => "Win",
                    NativePlatform::Linux => "Super",
                    NativePlatform::MacDevelopment => "Cmd",
                }
                .to_string(),
            );
        }
        parts.push(match self.key.as_str() {
            "enter" => "Enter".into(),
            "space" => "Space".into(),
            key => key.to_uppercase(),
        });
        parts.join("+")
    }
    fn validate(&self, platform: NativePlatform) -> Result<(), ValidationError> {
        let key = self.key.as_str();
        let function = key
            .strip_prefix('f')
            .and_then(|s| s.parse::<u8>().ok())
            .is_some_and(|n| (1..=24).contains(&n) && key == format!("f{n}"));
        let character = unicode_segmentation::UnicodeSegmentation::graphemes(key, true).count()
            == 1
            && !key.chars().any(|c| c.is_control() || c.is_whitespace());
        if key.is_empty()
            || key.len() > 64
            || (key.is_ascii() && key != key.to_ascii_lowercase())
            || !(character || function || key == "enter" || key == "space")
        {
            return Err(ValidationError::UnsupportedKey);
        }
        let m = self.modifiers;
        if m.platform && platform != NativePlatform::MacDevelopment {
            return Err(ValidationError::SystemReserved);
        }
        if m.control && m.alt {
            return Err(ValidationError::CharacterInput);
        }
        if !m.control && !m.platform && !(m.alt && function) {
            return Err(ValidationError::CharacterInput);
        }
        if key == "space" || (m.alt && !function) {
            return Err(ValidationError::EditingReserved);
        }
        // Native input actions retain precedence, including their shifted forms.
        if (m.control || m.platform)
            && matches!(
                key,
                "a" | "c"
                    | "x"
                    | "v"
                    | "z"
                    | "y"
                    | "h"
                    | "d"
                    | "k"
                    | "u"
                    | "l"
                    | "."
                    | "/"
                    | "["
                    | "]"
            )
            || (m.control && m.shift && key == "e")
        {
            return Err(ValidationError::EditingReserved);
        }
        // OS close/menu/window shortcuts, and desktop/workspace switching keys.
        if (m.alt && matches!(key, "f4" | "f10"))
            || (!m.shift && key == "f10")
            || (m.control && matches!(key, "f4" | "f6"))
        {
            return Err(ValidationError::SystemReserved);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "state", content = "shortcut", rename_all = "camelCase")]
pub enum BindingChoice {
    Bound(Shortcut),
    Unbound,
}
impl<'de> Deserialize<'de> for BindingChoice {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        enum State {
            Bound,
            Unbound,
        }
        fn present<'de, D: serde::Deserializer<'de>>(
            deserializer: D,
        ) -> Result<Option<Shortcut>, D::Error> {
            // Explicit null is malformed; only absence means missing content.
            Shortcut::deserialize(deserializer).map(Some)
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            state: State,
            #[serde(default, deserialize_with = "present")]
            shortcut: Option<Shortcut>,
        }
        let wire = Wire::deserialize(deserializer)?;
        match (wire.state, wire.shortcut) {
            (State::Bound, Some(shortcut)) => Ok(Self::Bound(shortcut)),
            (State::Unbound, None) => Ok(Self::Unbound),
            _ => Err(serde::de::Error::custom("Invalid shortcut assignment.")),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Override {
    pub command: ConfigurableCommand,
    pub binding: BindingChoice,
}
/// This DTO contains no SQL, source restoration, profiles or session state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Preferences {
    pub version: u32,
    pub overrides: Vec<Override>,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            version: VERSION,
            overrides: Vec::new(),
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ValidationError {
    Schema,
    UnsupportedKey,
    CharacterInput,
    EditingReserved,
    SystemReserved,
    Conflict,
}
impl std::fmt::Display for ValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Schema => "Shortcut preferences are invalid or unsupported.",
            Self::UnsupportedKey => {
                "Choose one supported native key. Navigation and modifier keys cannot be assigned."
            }
            Self::CharacterInput => {
                "Include Ctrl. AltGr and character-entry combinations stay available for typing."
            }
            Self::EditingReserved => "This shortcut is reserved for native text editing.",
            Self::SystemReserved => "This shortcut is reserved for the operating system.",
            Self::Conflict => "This shortcut is already assigned to another application command.",
        })
    }
}
#[derive(Clone)]
pub struct ResolvedBinding {
    pub(crate) command: CommandId,
    pub shortcut: Shortcut,
    pub scope: &'static str,
}
impl ResolvedBinding {
    /// Candidate binding only: installation must also apply native input safety
    /// before DispatchCommand; GPUI character alias matching alone is too broad.
    #[cfg(test)]
    pub fn key_binding(&self) -> KeyBinding {
        KeyBinding::new(
            &self.shortcut.binding_text(),
            DispatchCommand {
                command: self.command,
            },
            Some(self.scope),
        )
    }
}
impl Preferences {
    pub fn has_override(&self, command: ConfigurableCommand) -> bool {
        self.overrides.iter().any(|entry| entry.command == command)
    }
    pub fn shortcut(
        &self,
        command: ConfigurableCommand,
        platform: NativePlatform,
    ) -> Option<Shortcut> {
        if let Some(entry) = self.overrides.iter().find(|entry| entry.command == command) {
            return match &entry.binding {
                BindingChoice::Bound(shortcut) => Some(shortcut.clone()),
                BindingChoice::Unbound => None,
            };
        }
        DEFAULT_SHORTCUTS
            .iter()
            .find(|entry| entry.1 == command.command())
            .and_then(|entry| Shortcut::from_suffix(entry.0, platform).ok())
    }
    pub fn menu_label(
        &self,
        command: ConfigurableCommand,
        platform: NativePlatform,
    ) -> Option<String> {
        self.shortcut(command, platform).map(|s| s.label(platform))
    }
    /// Fixed bindings are copied directly from the current common registry.
    /// All configurable scopes conservatively overlap when checking conflicts.
    pub fn validated_bindings(
        &self,
        platform: NativePlatform,
    ) -> Result<Vec<ResolvedBinding>, ValidationError> {
        if self.version != VERSION || self.overrides.len() > ConfigurableCommand::ALL.len() {
            return Err(ValidationError::Schema);
        }
        for &(suffix, _, _) in DEFAULT_SHORTCUTS {
            Shortcut::from_suffix(suffix, platform)?;
        }
        for (i, entry) in self.overrides.iter().enumerate() {
            if self.overrides[..i]
                .iter()
                .any(|other| other.command == entry.command)
            {
                return Err(ValidationError::Schema);
            }
            if let BindingChoice::Bound(shortcut) = &entry.binding {
                shortcut.validate(platform)?;
            }
        }
        let mut bindings: Vec<ResolvedBinding> = DEFAULT_SHORTCUTS
            .iter()
            .filter(|entry| {
                !ConfigurableCommand::ALL
                    .iter()
                    .any(|c| c.command() == entry.1)
            })
            .map(|entry| {
                Ok(ResolvedBinding {
                    command: entry.1,
                    shortcut: Shortcut::from_suffix(entry.0, platform)?,
                    scope: entry.2,
                })
            })
            .collect::<Result<_, ValidationError>>()?;
        for command in ConfigurableCommand::ALL {
            if let Some(shortcut) = self.shortcut(command, platform) {
                if bindings
                    .iter()
                    .any(|existing| existing.shortcut == shortcut)
                {
                    return Err(ValidationError::Conflict);
                }
                bindings.push(ResolvedBinding {
                    command: command.command(),
                    shortcut,
                    scope: command.scope(),
                });
            }
        }
        Ok(bindings)
    }
    /// Validate the complete proposed assignment before replacing any binding.
    /// Supports atomic swaps; a failed edit/reset preserves the previous model.
    pub fn replace_overrides(
        &mut self,
        overrides: Vec<Override>,
        platform: NativePlatform,
    ) -> Result<(), ValidationError> {
        let next = Self {
            version: VERSION,
            overrides,
        };
        next.validated_bindings(platform)?;
        *self = next;
        Ok(())
    }
    pub fn set(
        &mut self,
        command: ConfigurableCommand,
        binding: BindingChoice,
        platform: NativePlatform,
    ) -> Result<(), ValidationError> {
        let mut next = self.overrides.clone();
        next.retain(|entry| entry.command != command);
        next.push(Override { command, binding });
        self.replace_overrides(next, platform)
    }
    pub fn clear(
        &mut self,
        command: ConfigurableCommand,
        platform: NativePlatform,
    ) -> Result<(), ValidationError> {
        self.set(command, BindingChoice::Unbound, platform)
    }
    pub fn restore_default(
        &mut self,
        command: ConfigurableCommand,
        platform: NativePlatform,
    ) -> Result<(), ValidationError> {
        let next = self
            .overrides
            .iter()
            .filter(|entry| entry.command != command)
            .cloned()
            .collect();
        self.replace_overrides(next, platform)
    }
    pub fn reset_defaults(&mut self) {
        *self = Self::default();
    }
}
