//! Appearance preferences and value palettes, independent of SQL restoration.

#[cfg(all(test, feature = "native-smoke"))]
mod native_tests;
mod normalized;
mod palette;
mod store;

pub use normalized::{Color, Scheme, Theme};
pub use palette::{AppPalette, EditorPalette, ResolvedAppearance};
pub use store::StoreError;
pub type TokenRule = normalized::TokenRule;
pub type TokenStyle = normalized::TokenStyle;
pub type AppearanceStore = store::AppearanceStore;
pub type LoadedPreferences = store::LoadedPreferences;
pub type SaveRequest = store::SaveRequest;
pub type SaveOutcome = store::SaveOutcome;
pub fn apply_application(
    resolved: &ResolvedAppearance,
    window: Option<&mut gpui_kit::Window>,
    cx: &mut gpui_kit::App,
) {
    palette::apply_application(resolved, window, cx);
}
use serde::{Deserialize, Serialize};

pub const VERSION: u32 = 1;
pub const NATIVE: &str = "native";
pub const AUTOMATIC: &str = "automatic";

/// Deliberately contains no document, editor, grid, session or connection state.
/// IDs remain strings so unknown/missing library entries survive fallback.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Preferences {
    pub version: u32,
    pub appearance_theme: String,
    pub application_color_theme: String,
    pub editor_color_theme: String,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            version: VERSION,
            appearance_theme: "system".into(),
            application_color_theme: NATIVE.into(),
            editor_color_theme: AUTOMATIC.into(),
        }
    }
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum NativeAppearance {
    #[default]
    System,
    Lager,
    Porter,
}
impl NativeAppearance {
    pub const ALL: [Self; 3] = [Self::System, Self::Lager, Self::Porter];
    pub fn id(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Lager => "light",
            Self::Porter => "dark",
        }
    }
    pub fn title(self) -> &'static str {
        match self {
            Self::System => "System",
            Self::Lager => "Lager",
            Self::Porter => "Porter",
        }
    }
    pub fn from_id(id: &str) -> Self {
        match id {
            "light" => Self::Lager,
            "dark" => Self::Porter,
            _ => Self::System,
        }
    }
    pub fn resolve(self, system: Scheme) -> Scheme {
        match self {
            Self::System => system,
            Self::Lager => Scheme::Light,
            Self::Porter => Scheme::Dark,
        }
    }
}
impl Preferences {
    pub fn validate(&self) -> Result<(), StoreError> {
        if self.version != VERSION
            || [
                &self.appearance_theme,
                &self.application_color_theme,
                &self.editor_color_theme,
            ]
            .into_iter()
            .any(|id| id.is_empty() || id.len() > 256 || id.chars().any(char::is_control))
        {
            return Err(StoreError::Read);
        }
        Ok(())
    }
    pub fn application_selection(&self) -> &str {
        if self.application_color_theme == NATIVE {
            &self.appearance_theme
        } else {
            &self.application_color_theme
        }
    }
    /// Explicitly selecting a native appearance exits a named app scheme, even
    /// when choosing the same native value again. Editor choice is untouched.
    pub fn choose_application(&mut self, id: &str, themes: &[Theme]) -> bool {
        if NativeAppearance::ALL.iter().any(|choice| choice.id() == id) {
            self.appearance_theme = id.into();
            self.application_color_theme = NATIVE.into();
            true
        } else if themes.iter().any(|theme| theme.id == id) {
            self.application_color_theme = id.into();
            true
        } else {
            false
        }
    }
    pub fn choose_editor(&mut self, id: &str, themes: &[Theme]) -> bool {
        if id == AUTOMATIC || themes.iter().any(|theme| theme.id == id) {
            self.editor_color_theme = id.into();
            true
        } else {
            false
        }
    }
    /// Theme removal is an explicit edit; a temporary read failure is not.
    pub fn remove_theme_selection(&mut self, id: &str) {
        if self.application_color_theme == id {
            self.application_color_theme = NATIVE.into();
        }
        if self.editor_color_theme == id {
            self.editor_color_theme = AUTOMATIC.into();
        }
    }
    pub fn resolve(&self, system: Scheme, themes: &[Theme]) -> ResolvedAppearance {
        let native = NativeAppearance::from_id(&self.appearance_theme).resolve(system);
        let application = themes
            .iter()
            .find(|theme| theme.id == self.application_color_theme && theme.is_valid());
        let application_scheme = application.map_or(native, |theme| theme.appearance);
        let editor = themes
            .iter()
            .find(|theme| theme.id == self.editor_color_theme && theme.is_valid());
        // Follow App uses the complete named app scheme, not merely its mode.
        // Unknown editor IDs resolve as automatic without overwriting the ID.
        let fallback_editor = Theme::native(application_scheme);
        let editor = editor.or(application).unwrap_or(&fallback_editor);
        ResolvedAppearance {
            application: application.map_or_else(
                || AppPalette::native(application_scheme),
                AppPalette::from_theme,
            ),
            editor: EditorPalette::from_theme(editor),
            application_scheme,
            application_theme_id: application.map(|theme| theme.id.clone()),
            editor_theme_id: editor.id.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selectors_are_independent_and_native_reselection_exits_named_app() {
        let themes = [Theme::native(Scheme::Light), Theme::native(Scheme::Dark)];
        let mut preferences = Preferences::default();
        assert!(preferences.choose_editor("native-dark", &themes));
        assert!(preferences.choose_application("native-light", &themes));
        assert_eq!(
            preferences.resolve(Scheme::Dark, &themes).editor_theme_id,
            "native-dark"
        );
        assert!(preferences.choose_application("system", &themes));
        assert_eq!(preferences.application_color_theme, NATIVE);
        assert_eq!(preferences.editor_color_theme, "native-dark");
        assert_eq!(preferences.appearance_theme, "system");
    }
    #[test]
    fn system_changes_only_following_choices_and_preserves_unresolved_ids() {
        let mut preferences = Preferences::default();
        let light = preferences.resolve(Scheme::Light, &[]);
        let dark = preferences.resolve(Scheme::Dark, &[]);
        assert_ne!(light.application.background, dark.application.background);
        assert_ne!(light.editor.background, dark.editor.background);
        preferences.application_color_theme = "imported-unavailable".into();
        preferences.editor_color_theme = "future-editor".into();
        preferences.appearance_theme = "future-native".into();
        let original = preferences.clone();
        assert_eq!(
            preferences.resolve(Scheme::Dark, &[]).application_scheme,
            Scheme::Dark
        );
        assert_eq!(preferences, original);
    }
    #[test]
    fn automatic_follows_named_palette_and_removal_changes_only_affected_choices() {
        let mut theme = Theme::native(Scheme::Dark);
        theme.id = "named".into();
        theme
            .colors
            .insert("editor.background".into(), Color::hex("#123456").unwrap());
        let themes = [theme];
        let mut preferences = Preferences::default();
        preferences.choose_application("named", &themes);
        let resolved = preferences.resolve(Scheme::Light, &themes);
        assert_eq!(resolved.editor.background, Color::hex("#123456").unwrap());
        preferences.remove_theme_selection("unrelated");
        assert_eq!(preferences.application_color_theme, "named");
        preferences.remove_theme_selection("named");
        assert_eq!(preferences.application_color_theme, NATIVE);
        assert_eq!(preferences.editor_color_theme, AUTOMATIC);
    }
    #[test]
    fn preference_dto_allow_list_does_not_capture_runtime_entities() {
        let value = serde_json::to_value(Preferences::default()).unwrap();
        let keys: std::collections::BTreeSet<_> = value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(
            keys,
            [
                "version",
                "appearanceTheme",
                "applicationColorTheme",
                "editorColorTheme"
            ]
            .into_iter()
            .collect()
        );
        assert!(serde_json::from_str::<Preferences>(r#"{"version":1,"appearanceTheme":"system","applicationColorTheme":"native","editorColorTheme":"automatic","text":"excluded"}"#).is_err());
    }
}
