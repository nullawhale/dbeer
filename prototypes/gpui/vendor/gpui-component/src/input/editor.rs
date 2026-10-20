use std::rc::Rc;

use gpui::{
    App, DefiniteLength, Entity, IntoElement, RenderOnce, SharedString, StyleRefinement, Styled,
    Window, prelude::FluentBuilder as _, relative,
};

use super::{EditorState, Input};
use crate::native_menu::NativeMenu;
use crate::{ActiveTheme as _, RoleOverride, StyledExt as _};

/// A code editor takes its rows from the font, so that a smaller or larger
/// font keeps its leading in proportion.
const EDITOR_LINE_HEIGHT: f32 = 1.5;

/// A styled source-code editor.
#[derive(IntoElement)]
pub struct Editor {
    state: Entity<EditorState>,
    style: StyleRefinement,
    height: Option<DefiniteLength>,
    appearance: bool,
    bordered: bool,
    disabled: bool,
    readonly: bool,
    tab_index: isize,
    role: RoleOverride,
    aria_label: Option<SharedString>,
    accessibility_id: Option<SharedString>,
    editor_style: Option<gpui_base::input::InputEditorStyle>,
    accessibility_guard: Option<super::InputAccessibilityGuard>,

    /// An optional context menu builder to allow a custom context menu.
    ///
    /// If set, this overrides the built-in context menu.
    context_menu_builder: Option<Rc<dyn Fn(NativeMenu, &mut Window, &mut App) -> NativeMenu>>,

    paste_handler: Option<Rc<dyn Fn(&gpui::ClipboardItem, &mut Window, &mut App) -> bool>>,
}

impl Editor {
    pub fn new(state: &Entity<EditorState>) -> Self {
        Self {
            state: state.clone(),
            style: StyleRefinement::default(),
            height: None,
            appearance: true,
            bordered: true,
            disabled: false,
            readonly: false,
            tab_index: 0,
            role: RoleOverride::default(),
            aria_label: None,
            accessibility_id: None,
            editor_style: None,
            accessibility_guard: None,
            context_menu_builder: None,
            paste_handler: None,
        }
    }

    pub fn h(mut self, height: impl Into<DefiniteLength>) -> Self {
        self.height = Some(height.into());
        self
    }

    pub fn appearance(mut self, appearance: bool) -> Self {
        self.appearance = appearance;
        self
    }

    pub fn bordered(mut self, bordered: bool) -> Self {
        self.bordered = bordered;
        self
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }

    /// Set the editor to read-only, default is `false`.
    ///
    /// Unlike [`Self::disabled`], a read-only editor keeps the normal appearance
    /// and still can be focused, selected and copied, it only rejects the changes
    /// made by the user.
    pub fn readonly(mut self, readonly: bool) -> Self {
        self.readonly = readonly;
        self
    }

    pub fn tab_index(mut self, index: isize) -> Self {
        self.tab_index = index;
        self
    }

    pub fn role(mut self, role: impl Into<RoleOverride>) -> Self {
        self.role = role.into();
        self
    }

    pub fn aria_label(mut self, label: impl Into<SharedString>) -> Self {
        self.aria_label = Some(label.into());
        self
    }

    /// Stable public automation identifier, independent of capture generations.
    pub fn accessibility_id(mut self, id: impl Into<SharedString>) -> Self {
        self.accessibility_id = Some(id.into());
        self
    }

    /// Use an application-owned palette without replacing the retained editor,
    /// its text, Undo, input/IME, highlighter, or context-menu state.
    pub fn editor_style(mut self, style: gpui_base::input::InputEditorStyle) -> Self {
        self.editor_style = Some(style);
        self
    }

    /// Invalidate before changing document/source/modal ownership. Native text
    /// actions from a previous capture then refuse rather than retargeting.
    pub fn accessibility_guard(mut self, guard: super::InputAccessibilityGuard) -> Self {
        self.accessibility_guard = Some(guard);
        self
    }

    /// Replace the built-in context menu shown on right-click.
    ///
    /// The closure receives an empty menu and returns the one to show, so it
    /// decides entirely what appears — the default items are not added. It
    /// shows only while the state's context menu is enabled, which is the
    /// default.
    pub fn context_menu(
        mut self,
        f: impl Fn(NativeMenu, &mut Window, &mut App) -> NativeMenu + 'static,
    ) -> Self {
        self.context_menu_builder = Some(Rc::new(f));
        self
    }

    /// Intercept paste payloads (images, files) before the default text insertion.
    ///
    /// `true` consumes the paste so nothing is inserted, `false` falls through
    /// to `clipboard.text()`. Copied files arrive as `ExternalPaths` through
    /// the same hook. On web the clipboard reads `None`; image paste needs
    /// async clipboard access and is out of scope.
    pub fn on_paste(
        mut self,
        handler: impl Fn(&gpui::ClipboardItem, &mut Window, &mut App) -> bool + 'static,
    ) -> Self {
        self.paste_handler = Some(Rc::new(handler));
        self
    }
}

impl Styled for Editor {
    fn style(&mut self) -> &mut StyleRefinement {
        &mut self.style
    }
}

impl RenderOnce for Editor {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        Input::from_state(self.state.clone())
            // Source code wants a monospace font at a code size, and rows that
            // follow that size. These come first so that a text style set on
            // this editor refines over them: `.text_sm()` and `.font_family()`
            // keep working.
            .font_family(cx.theme().mono_font_family.clone())
            .text_size(cx.theme().mono_font_size)
            .line_height(relative(EDITOR_LINE_HEIGHT))
            .appearance(self.appearance)
            .bordered(self.bordered)
            .focus_bordered(false)
            .disabled(self.disabled)
            .readonly(self.readonly)
            .tab_index(self.tab_index)
            .role(self.role)
            .when_some(self.editor_style, |this, style| this.editor_style(style))
            .when_some(self.accessibility_guard, |this, guard| {
                this.accessibility_guard(guard)
            })
            .when_some(self.height, |this, height| this.h(height))
            .when_some(self.aria_label, |this, label| this.aria_label(label))
            .when_some(self.accessibility_id, |this, id| this.accessibility_id(id))
            .when_some(self.context_menu_builder, |this, build| {
                this.context_menu(move |menu, window, cx| build(menu, window, cx))
            })
            .when_some(self.paste_handler, |this, handler| {
                this.on_paste(move |item, window, cx| handler(item, window, cx))
            })
            .refine_style(&self.style)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::EditorState;
    use gpui::{
        AppContext as _, Context, ParentElement as _, Pixels, Render, TestAppContext,
        VisualTestContext, div, px,
    };

    struct Harness {
        state: Entity<EditorState>,
        /// A text size set on the editor, as `.text_sm()` would.
        text_size: Option<Pixels>,
    }

    impl Render for Harness {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div().size_full().child(
                Editor::new(&self.state)
                    .when_some(self.text_size, |this, size| this.text_size(size)),
            )
        }
    }

    /// The row height the editor laid out with, which follows its font size.
    fn line_height(cx: &mut TestAppContext, text_size: Option<Pixels>) -> Pixels {
        cx.update(crate::init);
        let mut state = None;
        let (_, cx) = cx.add_window_view(|window, cx| {
            let editor = cx.new(|cx| EditorState::new(window, cx).default_value("fn main() {}"));
            state = Some(editor.clone());
            Harness {
                state: editor,
                text_size,
            }
        });
        let state = state.unwrap();
        VisualTestContext::update(cx, |window, cx| window.draw(cx).clear(cx));

        cx.read(|cx| {
            state
                .read(cx)
                .line_height()
                .expect("the editor must lay out")
        })
    }

    #[gpui::test]
    fn the_rows_follow_the_font_size(cx: &mut TestAppContext) {
        // With nothing set, the theme's monospace size, not the ambient one.
        assert_eq!(line_height(cx, None), px(20.));
        // A text style set on the editor refines over that, rows and all.
        assert_eq!(line_height(cx, Some(px(24.))), px(36.));
        assert_eq!(line_height(cx, Some(px(40.))), px(60.));
    }
    #[gpui::test]
    fn language_config_works_without_render_sync(cx: &mut TestAppContext) {
        use crate::input::{AutoClosingPair, language_config::LanguageConfig, set_language_config};
        use gpui::EntityInputHandler as _;
        cx.update(crate::init);
        let mut state = None;
        let (_, cx) = cx.add_window_view(|window, cx| {
            let editor = cx.new(|cx| EditorState::new(window, cx).language("plaintext"));
            // Plain-text defaults apply before the first render.
            editor.update(cx, |state, cx| {
                state.replace_text_in_range(None, "(", window, cx);
                assert_eq!(state.text().to_string(), "(");
                state.set_value("", window, cx);
                state.set_highlighter("json", cx);
                state.replace_text_in_range(None, "[", window, cx);
                assert_eq!(state.text().to_string(), "[]");
            });
            state = Some(editor.clone());
            Harness {
                state: editor,
                text_size: None,
            }
        });
        let state = state.unwrap();
        VisualTestContext::update(cx, |_, cx| {
            set_language_config(
                "json",
                LanguageConfig::default().auto_closing_pairs([AutoClosingPair::new("«", "»")]),
                cx,
            );
        });
        // A styled render must preserve the registered configuration.
        VisualTestContext::update(cx, |window, cx| window.draw(cx).clear(cx));
        VisualTestContext::update(cx, |window, cx| {
            state.update(cx, |state, cx| {
                state.set_value("", window, cx);
                state.replace_text_in_range(None, "«", window, cx);
                assert_eq!(state.text().to_string(), "«»");
                state.set_value("if enabled:", window, cx);
                state.set_selected_range(11..11, cx);
                state.set_highlighter("python", cx);
                state.focus(window, cx);
            });
        });
        VisualTestContext::update(cx, |window, cx| window.draw(cx).clear(cx));
        cx.simulate_keystrokes("enter");
        cx.read(|cx| assert_eq!(state.read(cx).text().to_string(), "if enabled:\n  "));
    }

    #[gpui::test]
    fn aliases_share_config_even_when_registered_before_init(cx: &mut TestAppContext) {
        use crate::input::{AutoClosingPair, language_config::LanguageConfig, set_language_config};
        use gpui::EntityInputHandler as _;
        cx.update(|cx| {
            set_language_config(
                "py",
                LanguageConfig::default().auto_closing_pairs([AutoClosingPair::new("«", "»")]),
                cx,
            )
        });
        cx.update(crate::init);
        cx.add_window_view(|window, cx| {
            let editor = cx.new(|cx| EditorState::new(window, cx).language("PYTHON"));
            editor.update(cx, |state, cx| {
                state.replace_text_in_range(None, "«", window, cx);
                assert_eq!(state.text().to_string(), "«»");
            });
            set_language_config("pyi", LanguageConfig::default().auto_closing_pairs([]), cx);
            editor.update(cx, |state, cx| {
                state.set_value("", window, cx);
                state.set_highlighter("py", cx);
                state.replace_text_in_range(None, "(", window, cx);
                assert_eq!(state.text().to_string(), "(");
            });
            Harness {
                state: editor,
                text_size: None,
            }
        });
    }

    #[cfg(all(feature = "tree-sitter-python", feature = "tree-sitter-rust"))]
    #[gpui::test]
    fn syntax_follows_language_before_first_render_and_after_switch(cx: &mut TestAppContext) {
        use gpui::EntityInputHandler as _;
        cx.update(crate::init);
        cx.add_window_view(|window, cx| {
            let editor = cx.new(|cx| {
                EditorState::new(window, cx)
                    .language("python")
                    .default_value("\"hello world\"")
            });
            editor.update(cx, |state, cx| {
                state.set_selected_range(6..6, cx);
                state.replace_text_in_range(None, "(", window, cx);
                assert_eq!(state.text().to_string(), "\"hello( world\"");
                state.set_value("# comment ", window, cx);
                state.set_selected_range(10..10, cx);
                state.replace_text_in_range(None, "(", window, cx);
                assert_eq!(state.text().to_string(), "# comment (");
                state.set_value("# comment ", window, cx);
                state.set_selected_range(10..10, cx);
                state.set_highlighter("rust", cx);
                state.replace_text_in_range(None, "(", window, cx);
                assert_eq!(state.text().to_string(), "# comment ()");
            });
            Harness {
                state: editor,
                text_size: None,
            }
        });
    }

    #[cfg(feature = "tree-sitter-python")]
    #[gpui::test]
    fn python_pairing_uses_pre_edit_context(cx: &mut TestAppContext) {
        use gpui::EntityInputHandler as _;
        cx.update(crate::init);
        for (before, cursor, typed, expected) in [
            ("x = ", 4, "\"", "x = \"\""),
            ("x = f\"{value}\"", 12, "(", "x = f\"{value()}\""),
            ("x = \"value\"", 7, "(", "x = \"va(lue\""),
            ("x = \"value\"", 5, "(", "x = \"(value\""),
            ("x = \"value\"", 10, "(", "x = \"value(\""),
        ] {
            let mut state = None;
            let (_, cx) = cx.add_window_view(|window, cx| {
                let editor = cx.new(|cx| EditorState::new(window, cx).default_value(before));
                state = Some(editor.clone());
                Harness {
                    state: editor,
                    text_size: None,
                }
            });
            let state = state.unwrap();
            VisualTestContext::update(cx, |window, cx| {
                state.update(cx, |state, cx| {
                    state.set_highlighter("python", cx);
                    state.set_selected_range(cursor..cursor, cx);
                    state.replace_text_in_range(None, typed, window, cx);
                    assert_eq!(state.text().to_string(), expected);
                });
            });
        }
    }
    #[cfg(feature = "tree-sitter-rust")]
    #[gpui::test]
    fn generated_comment_closer_survives_syntax_changes(cx: &mut TestAppContext) {
        use crate::input::{AutoClosingPair, SyntaxContext, language_config::LanguageConfig};
        use gpui::EntityInputHandler as _;
        cx.update(crate::init);
        cx.update(|cx| {
            crate::input::set_language_config(
                "rust",
                LanguageConfig::default().auto_closing_pairs([AutoClosingPair::new("/*", "*/")
                    .not_in([SyntaxContext::String, SyntaxContext::Comment])]),
                cx,
            )
        });
        let mut state = None;
        let (_, cx) = cx.add_window_view(|window, cx| {
            let editor = cx.new(|cx| EditorState::new(window, cx).language("rust"));
            state = Some(editor.clone());
            Harness {
                state: editor,
                text_size: None,
            }
        });
        let state = state.unwrap();
        VisualTestContext::update(cx, |window, cx| {
            state.update(cx, |state, cx| {
                state.set_highlighter("rust", cx);

                for text in ["/", "*", "x", "*", "/"] {
                    state.replace_text_in_range(None, text, window, cx);
                }
                assert_eq!(state.text().to_string(), "/*x*/");
                state.replace_text_in_range(None, "!", window, cx);
                assert_eq!(state.text().to_string(), "/*x*/!");
            });
        });
    }

    #[gpui::test]
    fn test_on_paste_builder(cx: &mut TestAppContext) {
        use gpui::{AppContext as _, Render};

        struct PasteProbe;
        impl Render for PasteProbe {
            fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
                div()
            }
        }

        cx.update(crate::init);
        let _ = cx.add_window_view(|window, cx| {
            let state = cx.new(|cx| EditorState::new(window, cx));
            assert!(Editor::new(&state).paste_handler.is_none());
            let editor = Editor::new(&state).on_paste(|_, _, _| true);
            assert!(editor.paste_handler.is_some());
            PasteProbe
        });
    }
}

#[cfg(test)]
mod dbeer_palette_tests {
    use super::*;
    use gpui::{
        AppContext as _, Context, Hsla, ParentElement as _, Render, TestAppContext,
        VisualTestContext, div, px,
    };
    struct Harness {
        state: Entity<EditorState>,
        guard: super::super::InputAccessibilityGuard,
        palette: gpui_base::input::InputEditorStyle,
    }
    impl Render for Harness {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div().size_full().child(
                Editor::new(&self.state)
                    .aria_label("SQL editor")
                    .accessibility_guard(self.guard.clone())
                    .editor_style(self.palette.clone()),
            )
        }
    }
    #[gpui::test]
    fn dbeer_repeated_independent_palette_render_keeps_original_editor_state(
        cx: &mut TestAppContext,
    ) {
        cx.update(crate::init);
        let mut original = None;
        let (_, cx) = cx.add_window_view(|window, cx| {
            let state =
                cx.new(|cx| EditorState::new(window, cx).default_value("select 1;\nselect 2;"));
            original = Some(state.clone());
            let palette = gpui_base::input::InputEditorStyle {
                foreground: Hsla::from(gpui::rgb(0xffffff)),
                background: Hsla::from(gpui::rgb(0x111111)),
                selection: Hsla::from(gpui::rgb(0x996622)),
                ..Default::default()
            };
            Harness {
                state,
                guard: super::super::InputAccessibilityGuard::default(),
                palette,
            }
        });
        let original = original.unwrap();
        let identity = original.entity_id();
        VisualTestContext::update(cx, |window, cx| {
            original.update(cx, |state, cx| {
                state.set_selected_range(2..7, cx);
                state.set_scroll_offset(gpui::point(px(0.), px(-2.)), cx);
            });
            window.draw(cx).clear(cx);
            let before_selection = original.read(cx).selected_range();
            let before_text = original.read(cx).text().to_string();
            window.draw(cx).clear(cx);
            window.draw(cx).clear(cx);
            assert_eq!(original.entity_id(), identity);
            assert_eq!(original.read(cx).selected_range(), before_selection);
            assert_eq!(original.read(cx).text().to_string(), before_text);
        });
    }
}

#[cfg(test)]
mod dbeer_live_capture_tests {
    use super::*;
    use gpui::{
        AppContext as _, ParentElement as _, Render, TestAppContext, VisualTestContext, div,
    };
    use std::{cell::Cell, rc::Rc};
    struct Harness {
        state: Entity<EditorState>,
        guard: super::super::InputAccessibilityGuard,
    }
    impl Render for Harness {
        fn render(&mut self, _: &mut Window, _: &mut gpui::Context<Self>) -> impl IntoElement {
            div()
                .size_full()
                .child(Editor::new(&self.state).accessibility_guard(self.guard.clone()))
        }
    }
    #[gpui::test]
    fn dbeer_native_guard_revalidates_live_owner_and_actual_selection_epoch(
        cx: &mut TestAppContext,
    ) {
        cx.update(crate::init);
        let valid = Rc::new(Cell::new(true));
        let guard = super::super::InputAccessibilityGuard::default().with_owner({
            let valid = valid.clone();
            move |_, _| valid.get()
        });
        let mut original = None;
        let (_, cx) = cx.add_window_view(|window, cx| {
            let state =
                cx.new(|cx| EditorState::new(window, cx).default_value("select 1;\r\nselect 2;"));
            original = Some(state.clone());
            Harness {
                state,
                guard: guard.clone(),
            }
        });
        let state = original.unwrap();
        VisualTestContext::update(cx, |window, cx| {
            window.draw(cx).clear(cx);
            assert!(guard.allows(window, cx));
            let first = state.read(cx).completion_selection_snapshot().unwrap();
            state.update(cx, |state, cx| state.set_selected_range(2..5, cx));
            state.update(cx, |state, cx| state.set_selected_range(0..0, cx));
            let second = state.read(cx).completion_selection_snapshot().unwrap();
            assert_eq!(first.document_revision, second.document_revision);
            assert_ne!(first.selection_revision, second.selection_revision);
            valid.set(false);
            assert!(!guard.allows(window, cx));
            valid.set(true);
            let old = guard.epoch();
            guard.invalidate();
            assert_ne!(guard.epoch(), old);
            assert_eq!(state.read(cx).text().to_string(), "select 1;\r\nselect 2;");
        });
    }
}
