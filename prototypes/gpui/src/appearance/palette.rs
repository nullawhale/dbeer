use super::{Color, Scheme, Theme};
use gpui_kit::base::input::{DiagnosticColors, HighlightStyleResolver, InputEditorStyle};
use gpui_kit::component::{Theme as KitTheme, ThemeMode};
use gpui_kit::{App, Window};
use std::sync::Arc;

#[derive(Clone, Debug, PartialEq)]
pub struct AppPalette {
    pub background: Color,
    pub window: Color,
    pub sidebar: Color,
    pub panel: Color,
    pub control: Color,
    pub text: Color,
    pub secondary_text: Color,
    pub disabled_text: Color,
    pub border: Color,
    pub selection: Color,
    pub selection_text: Color,
    pub accent: Color,
    pub accent_text: Color,
    pub hover: Color,
    pub active: Color,
    pub error: Color,
    pub warning: Color,
    pub success: Color,
    pub info: Color,
    pub link: Color,
    pub overlay: Color,
    pub terminal_background: Color,
    pub terminal_text: Color,
    pub terminal_ansi: [Color; 16],
}
impl AppPalette {
    pub fn native(appearance: Scheme) -> Self {
        let dark = appearance.is_dark();
        let mut native = Theme::native(appearance);
        for (key, value) in if dark {
            [
                ("editor.background", "#1B1C1F"),
                ("foreground", "#E7E8EB"),
                ("sideBar.background", "#1E2023"),
                ("panel.background", "#1B1C1F"),
                ("titleBar.activeBackground", "#232529"),
                ("input.background", "#27292D"),
                ("focusBorder", "#E8AA48"),
                ("panel.border", "#36383D"),
            ]
        } else {
            [
                ("editor.background", "#F7F6F2"),
                ("foreground", "#242424"),
                ("sideBar.background", "#F0EFEB"),
                ("panel.background", "#FFFFFF"),
                ("titleBar.activeBackground", "#F3F2EE"),
                ("input.background", "#FFFFFF"),
                ("focusBorder", "#9C5C14"),
                ("panel.border", "#C8C7C3"),
            ]
        } {
            native.colors.insert(key.into(), Color::hex(value).unwrap());
        }
        Self::from_theme(&native)
    }
    /// Mirrors AppColorScheme's key order, alpha composition, contrast fallback.
    /// Additional GPUI roles are derived from these readable semantic surfaces.
    pub fn from_theme(theme: &Theme) -> Self {
        let dark = theme.appearance.is_dark();
        let base = if dark {
            Color::hex("#1E1E1E").unwrap()
        } else {
            Color::WHITE
        };
        let background = first(theme, &["editor.background"], base).over(base);
        let foreground = first(
            theme,
            &["foreground", "editor.foreground"],
            if dark { Color::WHITE } else { Color::BLACK },
        )
        .over(background);
        let surface = |keys: &[&str], fallback| first(theme, keys, fallback).over(background);
        let sidebar = surface(
            &["sideBar.background", "editorGutter.background"],
            background.mix(foreground, 0.035),
        );
        let panel = surface(&["panel.background"], background);
        let window = surface(&["titleBar.activeBackground"], background);
        let control = surface(
            &[
                "input.background",
                "dropdown.background",
                "editorWidget.background",
            ],
            background.mix(foreground, 0.07),
        );
        let surfaces = [background, sidebar, panel, window, control];
        let text = foreground.readable(&surfaces, 4.5);
        let secondary_text = surface(
            &["descriptionForeground", "editorLineNumber.foreground"],
            text.mix(background, 0.28),
        )
        .readable(&surfaces, 4.5);
        let accent_fallback = theme
            .style(&["source.sql", "keyword.control.sql"])
            .foreground
            .unwrap_or_else(|| Color::hex(if dark { "#73B7FF" } else { "#0066CC" }).unwrap());
        let accent = surface(&["focusBorder", "button.background"], accent_fallback)
            .readable(&[background, control], 3.);
        let selection = surface(
            &[
                "list.activeSelectionBackground",
                "editor.selectionBackground",
            ],
            accent.mix(background, 0.6),
        );
        let selection_text = surface(
            &[
                "list.activeSelectionForeground",
                "editor.selectionForeground",
            ],
            text,
        )
        .readable(&[selection], 4.5);
        let border = surface(
            &[
                "panel.border",
                "sideBar.border",
                "input.border",
                "contrastBorder",
            ],
            text.mix(background, 0.77),
        );
        let status = |keys: &[&str], light, dark_value| {
            surface(
                keys,
                Color::hex(if dark { dark_value } else { light }).unwrap(),
            )
            .readable(&[background, panel, control], 3.)
        };
        let error = status(
            &["errorForeground", "editorError.foreground"],
            "#C82323",
            "#FF6B66",
        );
        let warning = status(&["editorWarning.foreground"], "#996000", "#FFBF5A");
        let success = status(
            &["testing.iconPassed", "terminal.ansiGreen"],
            "#26743A",
            "#7BCB91",
        );
        let info = status(&["editorInfo.foreground"], "#0066CC", "#73B7FF");
        let terminal_background = surface(&["terminal.background"], background);
        let terminal_text = first(theme, &["terminal.foreground"], text)
            .over(terminal_background)
            .readable(&[terminal_background], 4.5);
        let terminal_ansi = [
            "Black",
            "Red",
            "Green",
            "Yellow",
            "Blue",
            "Magenta",
            "Cyan",
            "White",
            "BrightBlack",
            "BrightRed",
            "BrightGreen",
            "BrightYellow",
            "BrightBlue",
            "BrightMagenta",
            "BrightCyan",
            "BrightWhite",
        ]
        .map(|name| {
            let fallback = match name {
                "Black" | "BrightBlack" => secondary_text,
                "Red" | "BrightRed" => error,
                "Green" | "BrightGreen" => success,
                "Yellow" | "BrightYellow" => warning,
                "Blue" | "BrightBlue" => info,
                "Magenta" | "BrightMagenta" => {
                    Color::hex(if dark { "#D89EF2" } else { "#8539A6" }).unwrap()
                }
                "Cyan" | "BrightCyan" => {
                    Color::hex(if dark { "#70CFD0" } else { "#00787A" }).unwrap()
                }
                _ => text,
            };
            first(theme, &[&format!("terminal.ansi{name}")], fallback).over(terminal_background)
        });
        Self {
            background,
            window,
            sidebar,
            panel,
            control,
            text,
            secondary_text,
            disabled_text: surface(&["disabledForeground"], secondary_text).readable(&surfaces, 3.),
            border,
            selection,
            selection_text,
            accent,
            accent_text: first(theme, &["button.foreground"], text)
                .over(accent)
                .readable(&[accent], 4.5),
            hover: surface(&["list.hoverBackground"], control.mix(text, 0.07)),
            active: surface(
                &["list.inactiveSelectionBackground"],
                control.mix(text, 0.13),
            ),
            error,
            warning,
            success,
            info,
            link: surface(&["textLink.foreground"], info).readable(&surfaces, 3.),
            overlay: Color {
                alpha: if dark { 0.6 } else { 0.3 },
                ..Color::BLACK
            },
            terminal_background,
            terminal_text,
            terminal_ansi,
        }
    }
}
fn first(theme: &Theme, keys: &[&str], fallback: Color) -> Color {
    keys.iter()
        .find_map(|key| {
            theme
                .colors
                .get(*key)
                .copied()
                .filter(|color| color.is_valid())
        })
        .unwrap_or(fallback)
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorPalette {
    pub theme: Theme,
    pub background: Color,
    pub text: Color,
    pub selection: Color,
    pub selection_text: Color,
    pub inactive_selection: Color,
    pub caret: Color,
    pub gutter: Color,
    pub line_number: Color,
    pub active_line_number: Color,
    pub active_line: Color,
    pub invisible: Color,
    pub error: Color,
    pub warning: Color,
    pub info: Color,
    pub hint: Color,
    pub popup: Color,
    pub popup_text: Color,
    pub popup_selection: Color,
    pub popup_selection_text: Color,
    pub popup_match: Color,
    pub popup_focus_match: Color,
    pub border: Color,
}
impl EditorPalette {
    pub fn from_theme(theme: &Theme) -> Self {
        let fallback = Theme::native(theme.appearance);
        let dark = theme.appearance.is_dark();
        let base = if dark {
            Color::hex("#1E1E1E").unwrap()
        } else {
            Color::WHITE
        };
        let background = first(theme, &["editor.background"], base).over(base);
        let color = |key: &str, fallback_color| {
            first(theme, &[key], first(&fallback, &[key], fallback_color))
        };
        // Preserve editor alpha and token styles. Application-only contrast
        // correction must not rewrite the user's syntax scheme.
        let text = color(
            "editor.foreground",
            if dark { Color::WHITE } else { Color::BLACK },
        );
        let selection = color("editor.selectionBackground", text.mix(background, 0.7));
        let popup = color("editorSuggestWidget.background", background).over(background);
        let popup_text = color("editorSuggestWidget.foreground", text)
            .over(popup)
            .readable(&[popup], 4.5);
        let popup_selection =
            color("editorSuggestWidget.selectedBackground", selection).over(popup);
        Self {
            theme: theme.clone(),
            background,
            text,
            selection,
            selection_text: color("editor.selectionForeground", text),
            inactive_selection: color("editor.inactiveSelectionBackground", selection),
            caret: color("editorCursor.foreground", text),
            gutter: color("editorGutter.background", background).over(background),
            line_number: color("editorLineNumber.foreground", text),
            active_line_number: color("editorLineNumber.activeForeground", text),
            active_line: color("editor.lineHighlightBackground", background),
            invisible: color("editorWhitespace.foreground", text.mix(background, 0.65)),
            error: color("editorError.foreground", Color::hex("#D93636").unwrap()),
            warning: color("editorWarning.foreground", Color::hex("#C78A00").unwrap()),
            info: color("editorInfo.foreground", Color::hex("#3388DD").unwrap()),
            hint: color("editorHint.foreground", text),
            popup,
            popup_text,
            popup_selection,
            popup_selection_text: color("editorSuggestWidget.selectedForeground", popup_text)
                .over(popup_selection)
                .readable(&[popup_selection], 4.5),
            popup_match: color("editorSuggestWidget.highlightForeground", text),
            popup_focus_match: color("editorSuggestWidget.focusHighlightForeground", text),
            border: color("editorSuggestWidget.border", text.mix(background, 0.7)),
        }
    }
    /// Install on retained EditorState via set_editor_style; no source, caret,
    /// scroll, selection, Undo, language provider or entity mutation is needed.
    /// GPUI Kit Editor reprojects global colors on render; the final UI must use
    /// a wrapper that projects this style after that projection (see handoff).
    pub fn input_style(&self) -> InputEditorStyle {
        InputEditorStyle {
            foreground: self.text.hsla(),
            muted_foreground: self.line_number.hsla(),
            background: self.background.hsla(),
            border: self.border.hsla(),
            selection: self.selection.hsla(),
            caret: self.caret.hsla(),
            diagnostics: DiagnosticColors {
                error: self.error.hsla(),
                warning: self.warning.hsla(),
                info: self.info.hsla(),
                hint: self.hint.hsla(),
            },
            highlight_styles: Arc::new(SyntaxResolver(self.theme.clone())),
            editor_invisible: Some(self.invisible.hsla()),
            editor_active_line: Some(self.active_line.hsla()),
            editor_gutter_background: Some(self.gutter.hsla()),
            fold_icon_renderer: None,
        }
    }
}
struct SyntaxResolver(Theme);
impl HighlightStyleResolver for SyntaxResolver {
    fn style(&self, name: &str) -> Option<gpui_kit::HighlightStyle> {
        let scope = match name {
            "number" | "float" => "constant.numeric.sql".into(),
            "boolean" => "constant.language.boolean.sql".into(),
            "function" | "function.call" => "support.function.sql".into(),
            "type" | "type.builtin" => "storage.type.sql".into(),
            "operator" => "keyword.operator.sql".into(),
            "variable" | "property" | "field" => "variable.other.sql".into(),
            "keyword" => "keyword.control.sql".into(),
            "string" => "string.quoted.single.sql".into(),
            "comment" | "comment.doc" => "comment.line.sql".into(),
            other => format!("{other}.sql"),
        };
        Some(self.0.style(&["source.sql", &scope]).highlight())
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedAppearance {
    pub application: AppPalette,
    pub editor: EditorPalette,
    pub application_scheme: Scheme,
    pub application_theme_id: Option<String>,
    pub editor_theme_id: String,
}

/// Changes only GPUI global presentation tokens. Call on explicit choices and
/// OS appearance changes; retain all Workspace/editor/grid/document entities.
pub fn apply_application(resolved: &ResolvedAppearance, window: Option<&mut Window>, cx: &mut App) {
    let mode = if resolved.application_scheme.is_dark() {
        ThemeMode::Dark
    } else {
        ThemeMode::Light
    };
    KitTheme::change(mode, window, cx);
    KitTheme::update(cx, |theme| {
        theme.font_size = gpui_kit::px(13.);
        theme.mono_font_size = gpui_kit::px(13.);
        map_application_colors(&resolved.application, &mut theme.colors);
    });
}
fn map_application_colors(p: &AppPalette, colors: &mut gpui_kit::component::theme::ThemeColor) {
    macro_rules! assign { ($value:expr; $($field:ident),+ $(,)?) => { $(colors.$field = $value.hsla();)+ }; }
    assign!(p.background; background, table, list, scrollbar);
    assign!(p.window; title_bar, status_bar);
    assign!(p.sidebar; sidebar, table_even, list_even);
    assign!(p.panel; popover, table_foot, list_head, accordion, group_box);
    assign!(p.control; button, button_secondary, secondary, muted, tab, tab_bar, tab_bar_segmented, table_head, description_list_label, switch, slider_bar, skeleton);
    assign!(p.text; foreground, button_foreground, button_secondary_foreground, secondary_foreground, popover_foreground, tab_foreground, tab_active_foreground, table_head_foreground, table_foot_foreground, group_box_foreground, description_list_label_foreground, sidebar_foreground);
    assign!(p.disabled_text; muted_foreground);
    assign!(p.border; border, input, table_row_border, title_bar_border, status_bar_border, sidebar_border, window_border);
    assign!(p.hover; accent, button_hover, button_secondary_hover, secondary_hover, list_hover, table_hover, scrollbar_thumb_hover);
    assign!(p.text; accent_foreground);
    assign!(p.active; button_active, button_secondary_active, secondary_active, tab_active, scrollbar_thumb);
    assign!(p.selection; selection, list_active, table_active, sidebar_accent, drop_target);
    assign!(p.selection_text; sidebar_accent_foreground);
    assign!(p.accent; primary, primary_hover, primary_active, button_primary, button_primary_hover, button_primary_active, caret, ring, drag_border, list_active_border, table_active_border, sidebar_primary, progress_bar, slider_thumb, switch_thumb);
    assign!(p.accent_text; primary_foreground, button_primary_foreground, sidebar_primary_foreground);
    assign!(p.link; link, link_hover, link_active);
    assign!(p.error; danger, danger_hover, danger_active, button_danger, button_danger_hover, button_danger_active, red, chart_bearish);
    assign!(p.warning; warning, warning_hover, warning_active, button_warning, button_warning_hover, button_warning_active, yellow);
    assign!(p.success; success, success_hover, success_active, button_success, button_success_hover, button_success_active, green, chart_bullish);
    assign!(p.info; info, info_hover, info_active, button_info, button_info_hover, button_info_active, blue);
    assign!(p.text.readable(&[p.error], 4.5); danger_foreground, button_danger_foreground);
    assign!(p.text.readable(&[p.warning], 4.5); warning_foreground, button_warning_foreground);
    assign!(p.text.readable(&[p.success], 4.5); success_foreground, button_success_foreground);
    assign!(p.text.readable(&[p.info], 4.5); info_foreground, button_info_foreground);
    assign!(p.overlay; overlay);
    assign!(p.border; chart_grid);
    assign!(p.accent; chart_1);
    assign!(p.info; chart_2);
    assign!(p.success; chart_3);
    assign!(p.warning; chart_4);
    assign!(p.terminal_ansi[5]; chart_5, magenta);
    assign!(p.terminal_ansi[6]; cyan);
    assign!(p.terminal_ansi[9]; red_light);
    assign!(p.terminal_ansi[10]; green_light);
    assign!(p.terminal_ansi[11]; yellow_light);
    assign!(p.terminal_ansi[12]; blue_light);
    assign!(p.terminal_ansi[13]; magenta_light);
    assign!(p.terminal_ansi[14]; cyan_light);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn app_alpha_readability_and_key_precedence_match_swift() {
        let mut theme = Theme::native(Scheme::Light);
        theme
            .colors
            .insert("editor.background".into(), Color::hex("#00000080").unwrap());
        theme
            .colors
            .insert("foreground".into(), Color::hex("#777777").unwrap());
        let palette = AppPalette::from_theme(&theme);
        assert_eq!(
            palette.background,
            Color::hex("#00000080").unwrap().over(Color::WHITE)
        );
        assert_eq!(palette.text.alpha, 1.);
        // Readability moves toward the best neutral endpoint if no endpoint
        // can satisfy all deliberately conflicting surfaces simultaneously.
        assert!(palette.text.is_valid());
        let mut sparse = Theme::native(Scheme::Dark);
        sparse.colors.clear();
        sparse
            .colors
            .insert("editor.background".into(), Color::hex("#121212").unwrap());
        sparse
            .colors
            .insert("editor.foreground".into(), Color::hex("#222222").unwrap());
        let palette = AppPalette::from_theme(&sparse);
        for surface in [
            palette.background,
            palette.panel,
            palette.window,
            palette.control,
            palette.sidebar,
        ] {
            assert!(palette.text.contrast(surface) >= 4.5);
            assert!(palette.secondary_text.contrast(surface) >= 4.5);
        }
    }
    #[test]
    fn independent_editor_style_retains_alpha_and_complete_font_traits() {
        let mut theme = Theme::native(Scheme::Dark);
        theme.token_rules[0].style.font_style = Some("bold italic underline strikethrough".into());
        let palette = EditorPalette::from_theme(&theme);
        let style = palette.input_style();
        assert_eq!(style.foreground.a, 217. / 255.);
        let keyword = style.highlight_styles.style("keyword").unwrap();
        assert_eq!(keyword.font_weight, Some(gpui_kit::FontWeight::BOLD));
        assert_eq!(keyword.font_style, Some(gpui_kit::FontStyle::Italic));
        assert!(keyword.underline.is_some());
        assert!(keyword.strikethrough.is_some());
        assert_eq!(
            style.highlight_styles.style("number").unwrap().color,
            theme
                .style(&["source.sql", "constant.numeric.sql"])
                .foreground
                .map(Color::hsla)
        );
    }
    #[test]
    fn all_kit_tokens_are_mapped_without_previous_scheme_leakage() {
        for scheme in [Scheme::Light, Scheme::Dark] {
            let palette = AppPalette::native(scheme);
            let mut colors = gpui_kit::component::theme::ThemeColor::default();
            map_application_colors(&palette, &mut colors);
            let value = serde_json::to_value(colors).unwrap();
            for (name, value) in value.as_object().unwrap() {
                assert!(
                    value
                        .as_str()
                        .and_then(Color::hex)
                        .is_some_and(|color| color.alpha > 0.),
                    "Unmapped token: {name}"
                );
            }
        }
    }
}
