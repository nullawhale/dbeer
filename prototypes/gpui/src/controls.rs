//! Shared source editor policy. GPUI uses its own plain UTF-8 rope/input handler,
//! not an OS rich-text widget: no smart quotes/dashes, spell correction, or RTF
//! conversion is registered. Paste reads ClipboardItem::text only. IME remains
//! supported; no system input settings are changed.
use super::*;

/// Selectable plain data display; SQL/bindings remain separate exact text.
pub(super) fn plain_editor_state(
    text: String,
    window: &mut Window,
    cx: &mut Context<EditorState>,
) -> EditorState {
    EditorState::new(window, cx)
        .auto_close(false)
        .smart_indent(false)
        .default_value(text)
}

pub(super) fn sql_editor_state(
    sql: String,
    window: &mut Window,
    cx: &mut Context<EditorState>,
) -> EditorState {
    EditorState::new(window, cx)
        .language("sql")
        .line_number(true)
        .auto_close(false)
        .smart_indent(false)
        .default_value(sql)
}

/// Gutter marks read the editor's laid-out byte geometry, so wrapping, scroll,
/// folds, CRLF and non-BMP text share the editor's own line mapping. No editor
/// selection or Undo state is changed. Painting never connects or parses SQL.
pub(super) fn sql_editor_feedback(
    editor: &Entity<EditorState>,
    successful: Vec<std::ops::Range<usize>>,
    readonly: bool,
    palette: appearance::EditorPalette,
    guard: gpui_kit::component::input::InputAccessibilityGuard,
    document: DocumentId,
) -> impl IntoElement {
    let marker_editor = editor.clone();
    div()
        .relative()
        .size_full()
        .child(
            accessibility::retained_editor(
                editor,
                "SQL editor",
                readonly,
                false,
                guard,
                Some(palette.input_style()),
            )
            .h_full()
            .bordered(false)
            .on_paste(|item, _, _| item.text().is_none())
            .accessibility_id(format!("dbeer-sql-editor-{}", document.0)),
        )
        .child(
            canvas(
                |_, _, _| {},
                move |bounds, _, window, cx| {
                    let state = marker_editor.read(cx);
                    window.with_content_mask(Some(ContentMask { bounds }), |window| {
                        for range in &successful {
                            if let Some(line) = state.range_to_bounds(&(range.start..range.start)) {
                                let mark = Bounds::new(
                                    point(bounds.left() + px(3.), line.top() + px(5.)),
                                    size(px(4.), px(8.)),
                                );
                                window.paint_quad(fill(mark, cx.theme().primary));
                            }
                        }
                    });
                },
            )
            .absolute()
            .inset_0()
            .size_full(),
        )
}

/// A projection for retained SQL preview dialogs outside Workspace rendering.
/// Only the appearance owner publishes it; no preference or storage authority lives here.
struct EditorPresentation(appearance::EditorPalette);
impl Global for EditorPresentation {}
pub(super) fn publish_editor_palette(palette: appearance::EditorPalette, cx: &mut App) {
    cx.set_global(EditorPresentation(palette));
}
pub(super) fn preview_editor(editor: &Entity<EditorState>, cx: &App) -> Editor {
    let palette = cx
        .try_global::<EditorPresentation>()
        .map(|p| p.0.clone())
        .unwrap_or_else(|| {
            let scheme = if cx.theme().mode.is_dark() {
                appearance::Scheme::Dark
            } else {
                appearance::Scheme::Light
            };
            appearance::EditorPalette::from_theme(&appearance::Theme::native(scheme))
        });
    Editor::new(editor).editor_style(palette.input_style())
}

/// One guard is created with each original immutable review editor and retained
/// by that review's dialog builder. Replaced/cancelled owners cannot refocus it.
pub(super) fn review_guard(
    owner: WeakEntity<Workspace>,
    valid: impl Fn(&Workspace, &App) -> bool + 'static,
) -> gpui_kit::component::input::InputAccessibilityGuard {
    gpui_kit::component::input::InputAccessibilityGuard::default().with_owner(move |window, cx| {
        let modal = window.has_active_dialog(cx) && !window.has_active_prompt();
        modal
            && owner
                .upgrade()
                .is_some_and(|owner| valid(owner.read(cx), cx))
    })
}
