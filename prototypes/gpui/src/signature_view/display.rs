use super::{PopupId, model::Signatures};
use crate::{appearance::EditorPalette, completion_view::EditorPopup, shortcuts};
use gpui_kit::{
    component::{ActiveTheme, input::EditorState},
    prelude::FluentBuilder,
    *,
};
use std::rc::Rc;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PopupAction {
    PreviousOverload,
    NextOverload,
    ChooseOverload(usize),
    Dismiss,
}
impl PopupAction {
    /// Signature help leaves ordinary arrows, Return, Tab and Undo to the
    /// retained editor. Overloads use their pointer/common-command actions.
    pub fn from_native(event: &KeyDownEvent, safety: shortcuts::InputSafety) -> Option<Self> {
        (event.keystroke.key == "escape"
            && !event.is_held
            && !event.prefer_character_input
            && event.keystroke.modifiers == Modifiers::default()
            && safety.marked_text == shortcuts::Evidence::Clear
            && safety.dead_key == shortcuts::Evidence::Clear)
            .then_some(Self::Dismiss)
    }
}

/// Every callback must re-enter State::act with CURRENT context/selections.
pub type PopupHandler = Rc<dyn Fn(PopupId, PopupAction, &mut Window, &mut App)>;
/// Re-enter the current Workspace owner at fresh prepaint. Require this popup
/// id, valid assistance capture, actual selections, active tab, no modal and
/// current native focus/IME. A stale render closure must return false.
pub type PopupGuard = Rc<dyn Fn(PopupId, &mut Window, &mut App) -> bool>;

/// Transient, nonserializable presentation. Use the selected editor's independent
/// palette on EVERY render; theme and DPI changes need no service/DB request.
pub struct PopupPresentation {
    id: PopupId,
    editor: Entity<EditorState>,
    signatures: Rc<Signatures>,
    selected: usize,
}
impl PopupPresentation {
    pub(super) fn new(
        id: PopupId,
        editor: Entity<EditorState>,
        signatures: Rc<Signatures>,
        selected: usize,
    ) -> Self {
        Self {
            id,
            editor,
            signatures,
            selected,
        }
    }
    pub fn id(&self) -> PopupId {
        self.id
    }
    pub fn selected_index(&self) -> usize {
        self.selected
    }
    pub fn overload_count(&self) -> usize {
        self.signatures.rows.len()
    }
    pub fn render(
        self,
        palette: EditorPalette,
        handler: PopupHandler,
        guard: PopupGuard,
    ) -> AnyElement {
        let editor = self.editor.downgrade();
        let height = px((28. + self.signatures.rows.len().min(8) as f32 * 40.).min(220.));
        deferred(
            EditorPopup::new(editor, size(px(540.), height), move |bounds, window, cx| {
                if !guard(self.id, window, cx) {
                    return div().into_any_element();
                }
                self.content(bounds.size, &palette, &handler, cx)
            })
            .above_caret(),
        )
        .into_any_element()
    }

    fn content(
        &self,
        bounds: Size<Pixels>,
        palette: &EditorPalette,
        handler: &PopupHandler,
        cx: &App,
    ) -> AnyElement {
        let id = self.id;
        let dismiss = handler.clone();
        let header = div()
            .flex()
            .items_center()
            .justify_between()
            .gap_2()
            .h(px(24.))
            .text_xs()
            .child("Function signatures")
            .when(self.signatures.rows.len() > 1, |header| {
                let previous = handler.clone();
                let next = handler.clone();
                header.child(
                    div()
                        .flex()
                        .items_center()
                        .gap_1()
                        .child(navigation(
                            ("dbeer-signature-previous", id.0),
                            "Previous",
                            self.selected > 0,
                            palette,
                            move |window, cx| {
                                previous(id, PopupAction::PreviousOverload, window, cx)
                            },
                        ))
                        .child(format!(
                            "{} of {}",
                            self.selected + 1,
                            self.signatures.rows.len()
                        ))
                        .child(navigation(
                            ("dbeer-signature-next", id.0),
                            "Next",
                            self.selected + 1 < self.signatures.rows.len(),
                            palette,
                            move |window, cx| next(id, PopupAction::NextOverload, window, cx),
                        )),
                )
            });
        let rows = self
            .signatures
            .order(self.selected)
            .into_iter()
            .map(|index| {
                let row = &self.signatures.rows[index];
                let choose = handler.clone();
                let active = index == self.selected;
                let highlights = row.active_range.clone().map(|range| {
                    (
                        range,
                        HighlightStyle {
                            color: Some(palette.popup_selection_text.hsla()),
                            background_color: Some(palette.popup_selection.hsla()),
                            font_weight: Some(FontWeight::SEMIBOLD),
                            ..Default::default()
                        },
                    )
                });
                div()
                    .id(("dbeer-signature-row", index))
                    .w_full()
                    .py_1()
                    .px_1()
                    .text_xs()
                    .font_family(cx.theme().mono_font_family.clone())
                    .text_color(palette.popup_text.hsla())
                    .when(active, |row| {
                        row.border_l_2().border_color(palette.border.hsla())
                    })
                    .child(StyledText::new(row.label.to_string()).with_highlights(highlights))
                    .on_mouse_down(MouseButton::Left, move |_, window, cx| {
                        window.prevent_default();
                        cx.stop_propagation();
                        choose(id, PopupAction::ChooseOverload(index), window, cx);
                    })
            });
        div()
            .id(("dbeer-signature", id.0))
            .test_support()
            .occlude()
            .flex()
            .flex_col()
            .w(bounds.width)
            .h(bounds.height)
            .px_2()
            .pb_1()
            .bg(palette.popup.hsla())
            .text_color(palette.popup_text.hsla())
            .border_1()
            .border_color(palette.border.hsla())
            .rounded_md()
            .shadow_md()
            .child(header)
            .child(
                div()
                    .id(("dbeer-signature-scroll", id.0))
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .children(rows),
            )
            .on_mouse_down_out(move |_, window, cx| dismiss(id, PopupAction::Dismiss, window, cx))
            .into_any_element()
    }
}

/// A popup mouse target deliberately has no focus handle and prevents the
/// native default mouse focus action before re-entering the original owner.
fn navigation(
    id: (&'static str, u64),
    title: &'static str,
    enabled: bool,
    palette: &EditorPalette,
    action: impl Fn(&mut Window, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .id(id)
        .test_support()
        .px_1()
        .rounded_sm()
        .when(enabled, |button| {
            button.cursor_pointer().hover(|style| {
                style
                    .bg(palette.popup_selection.hsla())
                    .text_color(palette.popup_selection_text.hsla())
            })
        })
        .when(!enabled, |button| button.opacity(0.45))
        .child(title)
        .on_mouse_down(MouseButton::Left, move |_, window, cx| {
            window.prevent_default();
            cx.stop_propagation();
            if enabled {
                action(window, cx);
            }
        })
}
