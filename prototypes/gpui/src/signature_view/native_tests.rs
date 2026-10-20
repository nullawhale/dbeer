//! Prepared retained-editor render cases, not native desktop/IME/DPI evidence.
use super::*;
use crate::{
    appearance::{Preferences, Scheme},
    completion, controls,
};
use gpui_kit::{
    AppContext, Bounds, Context, Entity, Focusable, IntoElement, ParentElement, Point, Render,
    Styled, TestAppContext, Window, WindowBounds, WindowOptions,
    component::{ThemeMode, input::Editor},
    div, init, open_window, px, size,
    test::TestWindowExt,
};
use std::cell::Cell;

struct Harness {
    editor: Entity<EditorState>,
    signatures: Rc<model::Signatures>,
    selected: usize,
    palette: crate::appearance::EditorPalette,
    allowed: Rc<Cell<bool>>,
    builds: Rc<Cell<usize>>,
}
impl Render for Harness {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let selections = completion::selections(&self.editor, cx);
        let capture = EditorCapture::read(&self.editor, selections.as_ref(), window, cx);
        let editor = self.editor.clone();
        let allowed = self.allowed.clone();
        let builds = self.builds.clone();
        let owner = cx.entity().downgrade();
        let handler: PopupHandler = Rc::new(move |id, action, _, cx| {
            if id != PopupId(1) {
                return;
            }
            _ = owner.update(cx, |view, cx| {
                if action == PopupAction::Dismiss {
                    view.allowed.set(false);
                } else if let Some(selected) = view.signatures.navigate(view.selected, action) {
                    view.selected = selected;
                }
                cx.notify();
            });
        });
        let guard: PopupGuard = Rc::new(move |id, window, cx| {
            builds.set(builds.get() + 1);
            let selections = completion::selections(&editor, cx);
            id == PopupId(1)
                && allowed.get()
                && capture.is_some()
                && EditorCapture::read(&editor, selections.as_ref(), window, cx) == capture
        });
        div()
            .size_full()
            .child(Editor::new(&self.editor).h_full())
            .child(
                PopupPresentation::new(
                    PopupId(1),
                    self.editor.clone(),
                    self.signatures.clone(),
                    self.selected,
                )
                .render(self.palette.clone(), handler, guard),
            )
    }
}

#[gpui_kit::test]
fn above_caret_render_navigation_palette_and_dismiss_preserve_retained_undo(
    cx: &mut TestAppContext,
) {
    let (handle, view) = cx.update(|cx| {
        init(cx);
        crate::presentation::apply_theme(ThemeMode::Dark, None, cx);
        open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    Point::default(),
                    size(px(800.), px(600.)),
                ))),
                ..Default::default()
            },
            cx,
            |window, cx| {
                cx.new(|cx| Harness {
                    editor: cx.new(|cx| {
                        controls::sql_editor_state(
                            format!("{}SELECT f(", "-- header\n".repeat(14)),
                            window,
                            cx,
                        )
                    }),
                    signatures: Rc::new(
                        model::Signatures::new(
                            vec![
                                super::tests::signature(
                                    "f(value: integer) → integer",
                                    Some(0),
                                    &["value: integer"],
                                ),
                                super::tests::signature(
                                    "f(value: numeric, scale: integer = DEFAULT) → numeric",
                                    Some(1),
                                    &["value: numeric", "scale: integer = DEFAULT"],
                                ),
                                super::tests::signature(
                                    "f(VARIADIC values: text[]) → text",
                                    Some(0),
                                    &["VARIADIC values: text[]"],
                                ),
                            ],
                            1,
                        )
                        .unwrap(),
                    ),
                    selected: 1,
                    palette: Preferences::default().resolve(Scheme::Dark, &[]).editor,
                    allowed: Rc::new(Cell::new(false)),
                    builds: Rc::new(Cell::new(0)),
                })
            },
        )
        .unwrap()
    });
    crate::workspace_tests::prepare_test_window(cx, handle);
    let (editor, source, selection) = cx
        .update_window(handle, |_, window, cx| {
            let editor = view.read(cx).editor.clone();
            editor.update(cx, |state, cx| {
                let end = state.value().len();
                state.set_selected_range(end..end, cx);
                state.focus(window, cx);
            });
            window.render_frame(cx);
            window.input("1, ", cx);
            let source = editor.read(cx).value();
            let selection = editor.read(cx).selected_range();
            view.update(cx, |view, cx| {
                view.allowed.set(true);
                cx.notify();
            });
            (editor, source, selection)
        })
        .unwrap();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let popup = window.find(("dbeer-signature", 1_u64)).bounds();
        let geometry = editor.read(cx).prepaint_caret_geometry().unwrap();
        let caret_y = geometry.cursor_bounds().top() + geometry.scroll_offset().y;
        assert!(popup.bottom() < caret_y);
        assert!(popup.left() >= px(8.) && popup.right() <= window.viewport_size().width - px(8.));
        window.click(("dbeer-signature-next", 1_u64), cx);
        assert_eq!(view.read(cx).selected, 2);
        assert_eq!(editor.read(cx).value(), source);
        assert_eq!(editor.read(cx).selected_range(), selection);
        assert!(editor.read(cx).focus_handle(cx).is_focused(window));
    })
    .unwrap();
    for scheme in [Scheme::Light, Scheme::Dark] {
        cx.update_window(handle, |_, _, cx| {
            view.update(cx, |view, cx| {
                view.palette = Preferences::default().resolve(scheme, &[]).editor;
                cx.notify();
            });
        })
        .unwrap();
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            assert!(window.try_find(("dbeer-signature", 1_u64)).is_some());
            assert_eq!(editor.read(cx).value(), source);
            assert_eq!(editor.read(cx).selected_range(), selection);
        })
        .unwrap();
    }
    cx.update_window(handle, |_, window, cx| {
        let native = completion::selections(&editor, cx).unwrap();
        let captured = EditorCapture::read(&editor, Some(&native), window, cx).unwrap();
        editor.update(cx, |state, cx| {
            state.set_selected_range(0..0, cx);
            state.set_selected_range(selection.clone(), cx);
        });
        let native = completion::selections(&editor, cx).unwrap();
        assert!(EditorCapture::read(&editor, Some(&native), window, cx).unwrap() != captured);
        view.update(cx, |view, cx| {
            view.allowed.set(false);
            cx.notify();
        });
        window.render_frame(cx);
        assert!(window.try_find(("dbeer-signature", 1_u64)).is_none());
        assert!(view.read(cx).builds.get() > 0);
        window.press(&crate::platform::binding("z"), cx);
        assert_ne!(editor.read(cx).value(), source);
        assert!(editor.read(cx).value().ends_with("SELECT f("));
    })
    .unwrap();
}
