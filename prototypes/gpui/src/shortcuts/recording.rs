use super::{
    BindingChoice, ConfigurableCommand, Modifiers, NativePlatform, Preferences, Shortcut,
    ValidationError,
};
use gpui_kit::KeyDownEvent;

/// Unknown must remain unknown; GPUI does not expose a physical key/scan code
/// or a universal native dead-key/composition flag on KeyDownEvent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Evidence {
    Clear,
    Active,
    Unknown,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InputSafety {
    pub marked_text: Evidence,
    pub dead_key: Evidence,
}
impl InputSafety {
    /// The caller supplies marked-text evidence from the original focused input.
    /// Linux reads its maintained scoped raw-keysym/compose evidence. Windows
    /// uses its native character-priority contract. Missing evidence is Unknown.
    pub fn from_gpui(event: &KeyDownEvent, marked_text: Evidence) -> Self {
        Self::from_native(event, marked_text, NativePlatform::current())
    }
    /// Platform must describe the native source of this event, not a requested
    /// display convention. Windows ToUnicode marks dead keys character-priority;
    /// control keys without that flag can be admitted with real IME evidence.
    pub fn from_native(
        event: &KeyDownEvent,
        marked_text: Evidence,
        platform: NativePlatform,
    ) -> Self {
        let key = event.keystroke.key.as_str();
        let named = matches!(
            key,
            "enter" | "escape" | "tab" | "up" | "down" | "home" | "end" | "space"
        ) || key
            .strip_prefix('f')
            .and_then(|s| s.parse::<u8>().ok())
            .is_some_and(|n| (1..=24).contains(&n) && key == format!("f{n}"));
        Self {
            marked_text,
            dead_key: if event.prefer_character_input
                || key.starts_with("dead_")
                || key == "compose"
            {
                Evidence::Active
            } else if platform == NativePlatform::Linux {
                linux_native_evidence()
            } else if named
                || (platform == NativePlatform::Windows
                    && event.keystroke.modifiers.control
                    && !event.keystroke.modifiers.alt)
            {
                Evidence::Clear
            } else {
                Evidence::Unknown
            },
        }
    }
    fn clear(self) -> bool {
        self.marked_text == Evidence::Clear && self.dead_key == Evidence::Clear
    }
}
fn linux_native_evidence() -> Evidence {
    #[cfg(target_os = "linux")]
    {
        use dbeer_gpui_linux::{KeyInputSafety, current_key_input_safety};
        match current_key_input_safety() {
            Some(KeyInputSafety::Clear) => Evidence::Clear,
            Some(KeyInputSafety::Composing) => Evidence::Active,
            Some(KeyInputSafety::Unknown) | None => Evidence::Unknown,
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        Evidence::Unknown
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaptureOutcome {
    Inactive,
    /// Keep text/IME/dead key handling on the original native control.
    PassThrough,
    IgnoredRepeat,
    ModifierOnly,
    Cancelled,
    Traverse {
        reverse: bool,
    },
    Rejected(ValidationError),
    Bound,
}
impl CaptureOutcome {
    pub fn consume(self) -> bool {
        !matches!(
            self,
            Self::Inactive | Self::PassThrough | Self::Traverse { .. }
        )
    }
}
pub struct Recording {
    command: ConfigurableCommand,
    active: bool,
}
impl Recording {
    /// Call only after the actual recorder obtained focus. No global monitor.
    pub fn begin(command: ConfigurableCommand) -> Self {
        Self {
            command,
            active: true,
        }
    }
    #[cfg(test)]
    pub fn active(&self) -> bool {
        self.active
    }
    /// Escape, Cancel button, focus loss or closing Settings all use this.
    /// No preference is changed until a complete candidate validates.
    pub fn cancel(&mut self) {
        self.active = false;
    }
    #[cfg(test)]
    pub fn clear(
        &mut self,
        preferences: &mut Preferences,
        platform: NativePlatform,
    ) -> Result<(), ValidationError> {
        preferences.clear(self.command, platform)?;
        self.cancel();
        Ok(())
    }
    #[cfg(test)]
    pub fn restore_default(
        &mut self,
        preferences: &mut Preferences,
        platform: NativePlatform,
    ) -> Result<(), ValidationError> {
        preferences.restore_default(self.command, platform)?;
        self.cancel();
        Ok(())
    }
    #[cfg(test)]
    pub fn reset_defaults(&mut self, preferences: &mut Preferences) {
        preferences.reset_defaults();
        self.cancel();
    }
    pub fn capture(
        &mut self,
        preferences: &mut Preferences,
        event: &KeyDownEvent,
        safety: InputSafety,
        platform: NativePlatform,
    ) -> CaptureOutcome {
        if !self.active {
            return CaptureOutcome::Inactive;
        }
        if event.prefer_character_input || !safety.clear() {
            return CaptureOutcome::PassThrough;
        }
        if event.is_held {
            return CaptureOutcome::IgnoredRepeat;
        }
        let key = event.keystroke.key.as_str();
        if key == "escape" {
            self.cancel();
            return CaptureOutcome::Cancelled;
        }
        if key == "tab" {
            self.cancel();
            return CaptureOutcome::Traverse {
                reverse: event.keystroke.modifiers.shift,
            };
        }
        if modifier_only(key) {
            return CaptureOutcome::ModifierOnly;
        }
        let shortcut = match candidate(event) {
            Ok(shortcut) => shortcut,
            Err(error) => return CaptureOutcome::Rejected(error),
        };
        match preferences.set(self.command, BindingChoice::Bound(shortcut), platform) {
            Ok(()) => {
                self.active = false;
                CaptureOutcome::Bound
            }
            Err(error) => CaptureOutcome::Rejected(error),
        }
    }
}
fn modifier_only(key: &str) -> bool {
    matches!(
        key,
        "shift"
            | "control"
            | "ctrl"
            | "alt"
            | "super"
            | "cmd"
            | "fn"
            | "shift_l"
            | "shift_r"
            | "control_l"
            | "control_r"
            | "alt_l"
            | "alt_r"
            | "super_l"
            | "super_r"
            | "iso_level3_shift"
            | "capslock"
    )
}
fn candidate(event: &KeyDownEvent) -> Result<Shortcut, ValidationError> {
    let m = event.keystroke.modifiers;
    if m.function {
        return Err(ValidationError::UnsupportedKey);
    }
    Ok(Shortcut::new(
        event.keystroke.key.clone(),
        Modifiers {
            control: m.control,
            alt: m.alt,
            shift: m.shift,
            platform: m.platform,
        },
    ))
}
impl Preferences {
    /// Resolve only; caller must synchronously call Workspace::command with
    /// Shortcut origin to capture/recheck modal, focus, busy and original owner.
    /// Never dispatch directly to a database, editor action or active tab.
    pub(crate) fn command_for_native(
        &self,
        event: &KeyDownEvent,
        safety: InputSafety,
        platform: NativePlatform,
    ) -> Option<crate::commands::CommandId> {
        if event.prefer_character_input
            || event.is_held
            || !safety.clear()
            || (event.keystroke.modifiers.control && event.keystroke.modifiers.alt)
        {
            return None;
        }
        self.validated_bindings(platform)
            .ok()?
            .into_iter()
            .find(|binding| binding.shortcut.matches_native(&event.keystroke))
            .map(|binding| binding.command)
    }
}
