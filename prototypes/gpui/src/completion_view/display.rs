use super::PopupId;
use crate::{appearance::EditorPalette, language_service::CompletionItem, shortcuts};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::{component::input::EditorState, *};
use std::{ops::Range, rc::Rc};
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PopupAction {
    Previous,
    Next,
    First,
    Last,
    Accept,
    Choose(usize),
    Dismiss,
}
impl PopupAction {
    /// Call synchronously from the original focused native key callback, after
    /// reading its real marked text and shared Task 28/29 native input evidence.
    /// Unknown, composing, AltGr and character-priority events pass through.
    /// These are popup actions, not SQL/backend commands or global bindings.
    pub fn from_native(event: &KeyDownEvent, safety: shortcuts::InputSafety) -> Option<Self> {
        if event.prefer_character_input
            || safety.marked_text != shortcuts::Evidence::Clear
            || safety.dead_key != shortcuts::Evidence::Clear
            || event.keystroke.modifiers != Modifiers::default()
        {
            return None;
        }
        match event.keystroke.key.as_str() {
            "up" => Some(Self::Previous),
            "down" => Some(Self::Next),
            "home" => Some(Self::First),
            "end" => Some(Self::Last),
            "enter" | "tab" if !event.is_held => Some(Self::Accept),
            "escape" if !event.is_held => Some(Self::Dismiss),
            _ => None,
        }
    }
}

/// The handler must re-enter State::act with current selection/context evidence.
/// No insertion happens in a deferred popup task or stale render closure.
pub type PopupHandler = Rc<dyn Fn(PopupId, PopupAction, &mut Window, &mut App)>;
pub type PopupGuard = Rc<dyn Fn(PopupId, &mut Window, &mut App) -> bool>;

/// A transient display capture, never Debug/Serialize/logged. Theme changes
/// restyle Go's existing ranges without a new request or text edit.
pub struct PopupPresentation {
    id: PopupId,
    editor: Entity<EditorState>,
    items: Vec<Rc<CompletionItem>>,
    selected: usize,
    incomplete: bool,
    scroll: UniformListScrollHandle,
}
impl PopupPresentation {
    pub(super) fn new(
        id: PopupId,
        editor: Entity<EditorState>,
        items: Vec<Rc<CompletionItem>>,
        selected: usize,
        incomplete: bool,
        scroll: UniformListScrollHandle,
    ) -> Self {
        Self {
            id,
            editor,
            items,
            selected,
            incomplete,
            scroll,
        }
    }
    pub fn id(&self) -> PopupId {
        self.id
    }
    pub fn selected_index(&self) -> usize {
        self.selected
    }
    pub fn item_count(&self) -> usize {
        self.items.len()
    }
    pub fn render(
        self,
        palette: EditorPalette,
        handler: PopupHandler,
        guard: PopupGuard,
    ) -> AnyElement {
        let editor = self.editor.downgrade();
        let preferred = size(px(520.), px(26. * self.items.len().min(9) as f32 + 8.));
        deferred(EditorPopup::new(
            editor,
            preferred,
            move |bounds, window, cx| {
                let id = self.id;
                if !guard(id, window, cx) {
                    return div().into_any_element();
                }
                let dismiss = handler.clone();
                div()
                    .id(("dbeer-completion", id.0))
                    .occlude()
                    .w(bounds.size.width)
                    .p_1()
                    .bg(palette.popup.hsla())
                    .text_color(palette.popup_text.hsla())
                    .border_1()
                    .border_color(palette.border.hsla())
                    .rounded_md()
                    .shadow_md()
                    .child(self.rows(&palette, &handler, bounds.size.height - px(8.)))
                    .on_mouse_down_out(move |_, window, cx| {
                        dismiss(id, PopupAction::Dismiss, window, cx)
                    })
                    .into_any_element()
            },
        ))
        .into_any_element()
    }
    fn rows(&self, palette: &EditorPalette, handler: &PopupHandler, height: Pixels) -> AnyElement {
        let id = self.id;
        let items = self.items.clone();
        let selected = self.selected;
        let palette = palette.clone();
        let handler = handler.clone();
        uniform_list(
            ("dbeer-completion-rows", id.0),
            items.len(),
            move |range, _, _| {
                range
                    .map(|ix| {
                        let item = &items[ix];
                        let active = ix == selected;
                        let foreground = if active {
                            palette.popup_selection_text
                        } else {
                            palette.popup_text
                        };
                        // Missing focused highlight inherits the actual selected
                        // foreground. It cannot fall back to an unreadable unselected
                        // scheme color merely because the application theme differs.
                        let match_color = if active {
                            if palette
                                .theme
                                .colors
                                .contains_key("editorSuggestWidget.focusHighlightForeground")
                            {
                                palette.popup_focus_match
                            } else {
                                palette.popup_selection_text
                            }
                        } else {
                            palette.popup_match
                        };
                        let highlights = grapheme_ranges(&item.label, &item.match_ranges)
                            .into_iter()
                            .map(|range| {
                                (
                                    range,
                                    HighlightStyle {
                                        color: Some(match_color.hsla()),
                                        font_weight: Some(FontWeight::BOLD),
                                        ..Default::default()
                                    },
                                )
                            })
                            .collect::<Vec<_>>();
                        let callback = handler.clone();
                        div()
                            .id(("dbeer-completion-row", ix))
                            .flex()
                            .overflow_hidden()
                            .items_center()
                            .gap_3()
                            .h(px(26.))
                            .px_2()
                            .text_xs()
                            .text_color(foreground.hsla())
                            .when(active, |row| row.bg(palette.popup_selection.hsla()))
                            .hover(|row| {
                                row.bg(palette.popup_selection.hsla())
                                    .text_color(palette.popup_selection_text.hsla())
                            })
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_ellipsis()
                                    .overflow_hidden()
                                    .child(
                                        StyledText::new(item.label.clone())
                                            .with_highlights(highlights),
                                    ),
                            )
                            .when_some(item.detail.clone(), |row, detail| {
                                row.child(
                                    div()
                                        .min_w_0()
                                        .text_ellipsis()
                                        .overflow_hidden()
                                        .child(detail),
                                )
                            })
                            .on_mouse_down(MouseButton::Left, move |_, window, cx| {
                                window.prevent_default();
                                cx.stop_propagation();
                                callback(id, PopupAction::Choose(ix), window, cx);
                            })
                    })
                    .collect::<Vec<_>>()
            },
        )
        .track_scroll(&self.scroll)
        .h(height)
        .into_any_element()
    }
}

/// Expand matching spans only for display, using whole composed characters.
/// Malformed spans are ignored as a group; insertion and Go order stay intact.
pub(super) fn grapheme_ranges(label: &str, ranges: &[Range<usize>]) -> Vec<Range<usize>> {
    let mut previous = 0;
    if ranges.len() > 64
        || ranges.iter().any(|range| {
            let invalid = range.start < previous
                || range.start >= range.end
                || range.end > label.len()
                || !label.is_char_boundary(range.start)
                || !label.is_char_boundary(range.end);
            previous = range.end;
            invalid
        })
    {
        return Vec::new();
    }
    let graphemes = label
        .grapheme_indices(true)
        .map(|(start, value)| start..start + value.len())
        .collect::<Vec<_>>();
    let mut expanded: Vec<Range<usize>> = Vec::new();
    for range in ranges {
        let Some(first) = graphemes.iter().find(|g| g.end > range.start) else {
            continue;
        };
        let Some(last) = graphemes.iter().rev().find(|g| g.start < range.end) else {
            continue;
        };
        let next = first.start..last.end;
        if let Some(previous) = expanded
            .last_mut()
            .filter(|previous| previous.end >= next.start)
        {
            previous.end = previous.end.max(next.end);
        } else {
            expanded.push(next);
        }
    }
    expanded
}

/// Shared placement seam for editor-owned popups. Read geometry only from the
/// original editor's CURRENT prepaint inside deferred(); cached render-time
/// caret bounds cannot establish this contract.
pub(super) fn caret_popup_bounds(
    geometry: gpui_kit::component::input::PrepaintCaretGeometry,
    viewport: Size<Pixels>,
    preferred: Size<Pixels>,
) -> Option<Bounds<Pixels>> {
    popup_bounds(geometry, viewport, preferred, false)
}
pub(super) fn caret_popup_bounds_above(
    geometry: gpui_kit::component::input::PrepaintCaretGeometry,
    viewport: Size<Pixels>,
    preferred: Size<Pixels>,
) -> Option<Bounds<Pixels>> {
    popup_bounds(geometry, viewport, preferred, true)
}
fn popup_bounds(
    geometry: gpui_kit::component::input::PrepaintCaretGeometry,
    viewport: Size<Pixels>,
    preferred: Size<Pixels>,
    force_above: bool,
) -> Option<Bounds<Pixels>> {
    let margin = px(8.);
    let width = preferred.width.min(viewport.width - margin * 2.);
    let caret_y = geometry.cursor_bounds().origin.y + geometry.scroll_offset().y;
    let below = caret_y + geometry.line_height() + px(4.);
    let available_below = (viewport.height - below - margin).max(px(0.));
    let available_above = (caret_y - margin - px(4.)).max(px(0.));
    let above =
        force_above || (available_below < preferred.height && available_above > available_below);
    let height = preferred.height.min(if above {
        available_above
    } else {
        available_below
    });
    if width < px(120.) || height < px(34.) {
        return None;
    }
    Some(Bounds::new(
        point(
            (geometry.cursor_bounds().origin.x - px(4.))
                .clamp(margin, viewport.width - width - margin),
            if above {
                caret_y - height - px(4.)
            } else {
                below
            },
        ),
        size(width, height),
    ))
}

/// Uses the real retained editor's fresh PREPAINT geometry. This application
/// element is necessary because the pinned component's caret popup is private.
/// It follows the same deferred layout seam, with viewport clamping/flipping.
pub struct EditorPopup {
    editor: WeakEntity<EditorState>,
    preferred: Size<Pixels>,
    above: bool,
    build: Box<PopupBuilder>,
    content: Option<AnyElement>,
}
type PopupBuilder = dyn Fn(Bounds<Pixels>, &mut Window, &mut App) -> AnyElement;
impl EditorPopup {
    /// Always wrap in deferred(). `build` receives fresh window-coordinate
    /// placement bounds, and must return the actual visual popup at that size.
    /// Keep context/source validation in the retained owner's presentation and
    /// original action paths; a render closure never authorizes an insertion.
    pub fn new(
        editor: WeakEntity<EditorState>,
        preferred: Size<Pixels>,
        build: impl Fn(Bounds<Pixels>, &mut Window, &mut App) -> AnyElement + 'static,
    ) -> Self {
        Self {
            editor,
            preferred,
            above: false,
            build: Box::new(build),
            content: None,
        }
    }
    /// Signature help uses the native above-caret placement independently of
    /// a completion menu below. It clips to available space above the caret.
    pub fn above_caret(mut self) -> Self {
        self.above = true;
        self
    }
}
impl Element for EditorPopup {
    type RequestLayoutState = ();
    type PrepaintState = ();
    fn id(&self) -> Option<ElementId> {
        None
    }
    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        None
    }
    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        (window.request_layout(Style::default(), [], cx), ())
    }
    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) {
        self.content = None;
        let Some(editor) = self.editor.upgrade() else {
            return;
        };
        if !window.is_window_active() || !editor.read(cx).focus_handle(cx).is_focused(window) {
            return;
        }
        let Some(geometry) = editor.read(cx).prepaint_caret_geometry() else {
            return;
        };
        let Some(bounds) =
            popup_bounds(geometry, window.viewport_size(), self.preferred, self.above)
        else {
            return;
        };
        let mut popup = (self.build)(bounds, window, cx);
        popup.layout_as_root(
            size(
                AvailableSpace::Definite(bounds.size.width),
                AvailableSpace::Definite(bounds.size.height),
            ),
            window,
            cx,
        );
        popup.prepaint_at(bounds.origin, window, cx);
        self.content = Some(popup);
    }
    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut (),
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) {
        if let Some(content) = &mut self.content {
            content.paint(window, cx);
        }
    }
}
impl IntoElement for EditorPopup {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}
