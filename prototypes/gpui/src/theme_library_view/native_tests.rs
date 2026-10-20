//! Prepared retained Kit cases. These are not target-native accessibility proof.
use super::{
    ImportMode, LibraryAccess, LibraryAction, LibraryEvent, Menu, MenuValue, Presentation,
    ThemeLibraryView, Workflow,
};
use crate::{
    appearance::{Scheme, Theme},
    theme_library_view::{ImportRequest, ImportReview, PreviewToken},
};
use gpui_kit::{
    AnyWindowHandle, AppContext, Bounds, Entity, Focusable, Point, TestAppContext, WindowBounds,
    WindowOptions,
    component::{IndexPath, select::SelectEvent},
    px, size,
    test::TestWindowExt,
};
use std::{cell::RefCell, rc::Rc};

fn themes() -> Vec<Theme> {
    crate::theme_library::builtin_themes().unwrap()
}
fn presentation(revision: u64, id: &str, workflow: Workflow) -> Presentation {
    Presentation::new(
        revision,
        &themes(),
        Some(id),
        Scheme::Light,
        LibraryAccess::Writable,
        workflow,
    )
}
fn review() -> ImportReview {
    let request = ImportRequest::new(1, 21, ImportMode::Standard).unwrap();
    let preview = crate::theme_library::preview_import(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("fixtures/settings-theme-library/import.jsonc")
            .as_path(),
    )
    .unwrap();
    ImportReview::new(PreviewToken::new(request, 31).unwrap(), &preview)
}
fn library(cx: &mut TestAppContext) -> (AnyWindowHandle, Entity<ThemeLibraryView>) {
    let result = cx.update(|cx| {
        gpui_kit::init(cx);
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Point::default(),
                    size: size(px(760.), px(640.)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| {
                cx.new(|cx| {
                    ThemeLibraryView::new(
                        presentation(1, "native-light", Workflow::Idle),
                        window,
                        cx,
                    )
                })
            },
        )
        .unwrap()
    });
    crate::workspace_tests::prepare_test_window(cx, result.0);
    result
}

#[gpui_kit::test]
fn retained_preview_survives_browsing_review_cancel_and_opposite_palettes(cx: &mut TestAppContext) {
    let (handle, view) = library(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let preview = view.read(cx).preview.clone();
        let browse = view.read(cx).browse.entity_id();
        preview.update(cx, |state, cx| {
            state.set_selected_range(5..12, cx);
            state.focus(window, cx);
        });
        window.render_frame(cx);
        let source = preview.read(cx).value();
        let selection = preview.read(cx).selected_range();
        let scroll = preview.read(cx).scroll_offset();
        for (revision, id, workflow) in [
            (2, "native-dark", Workflow::Idle),
            (3, "native-dark", Workflow::Review(review())),
            (4, "solarized-light", Workflow::Idle),
        ] {
            view.update(cx, |this, cx| {
                assert!(this.set_presentation(presentation(revision, id, workflow), window, cx));
            });
            window.render_frame(cx);
            assert_eq!(view.read(cx).preview.entity_id(), preview.entity_id());
            assert_eq!(view.read(cx).browse.entity_id(), browse);
            assert_eq!(preview.read(cx).value(), source);
            assert_eq!(preview.read(cx).selected_range(), selection);
            assert_eq!(preview.read(cx).scroll_offset(), scroll);
            assert!(preview.focus_handle(cx).is_focused(window));
            assert!(!preview.read(cx).is_editable());
        }
        window.input("this must not replace the sample", cx);
        assert_eq!(preview.read(cx).value(), source);
        assert_eq!(
            view.read(cx).presentation.preview_theme().id,
            "solarized-light"
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn visible_review_buttons_emit_only_current_original_preview_tokens(cx: &mut TestAppContext) {
    let (handle, view) = library(cx);
    let events = Rc::new(RefCell::new(Vec::<LibraryEvent>::new()));
    let _subscription = cx.update(|cx| {
        let events = events.clone();
        cx.subscribe(&view, move |_, event, _| {
            events.borrow_mut().push(event.clone())
        })
    });
    let review = review();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("dbeer.settings.themes.import", cx);
        view.update(cx, |this, cx| {
            this.set_presentation(
                presentation(2, "native-light", Workflow::Review(review.clone())),
                window,
                cx,
            );
            this.emit_at(1, LibraryAction::CommitImport(review.token()), cx);
        });
        window.render_frame(cx);
        window.click("dbeer.settings.themes.commit", cx);
        window.click("dbeer.settings.themes.cancel", cx);
        view.update(cx, |this, cx| {
            this.set_presentation(presentation(3, "native-light", Workflow::Idle), window, cx);
            this.emit_at(3, LibraryAction::CommitImport(review.token()), cx);
            this.emit_at(
                2,
                LibraryAction::CancelImport {
                    request: review.token().request(),
                    preview: Some(review.token()),
                },
                cx,
            );
        });
    })
    .unwrap();
    let events = events.borrow();
    assert_eq!(events.len(), 3);
    assert_eq!(events[0].action, LibraryAction::RequestImport);
    assert_eq!(
        events[1],
        LibraryEvent {
            revision: 2,
            action: LibraryAction::CommitImport(review.token())
        }
    );
    assert_eq!(
        events[2],
        LibraryEvent {
            revision: 2,
            action: LibraryAction::CancelImport {
                request: review.token().request(),
                preview: Some(review.token())
            }
        }
    );
}

#[gpui_kit::test]
fn stale_menu_confirmation_restores_current_browse_and_closed_owner_refuses_work(
    cx: &mut TestAppContext,
) {
    let (handle, view) = library(cx);
    let events = Rc::new(RefCell::new(Vec::<LibraryEvent>::new()));
    let _subscription = cx.update(|cx| {
        let events = events.clone();
        cx.subscribe(&view, move |_, event, _| {
            events.borrow_mut().push(event.clone())
        })
    });
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |this, cx| {
            assert!(this.set_presentation(
                presentation(2, "native-dark", Workflow::Idle),
                window,
                cx
            ));
            assert!(!this.set_presentation(
                presentation(1, "native-light", Workflow::Idle),
                window,
                cx
            ));
            assert!(!this.set_presentation(
                presentation(2, "solarized-dark", Workflow::Idle),
                window,
                cx
            ));
        });
        let browse = view.read(cx).browse.clone();
        browse.update(cx, |state, cx| {
            state.set_selected_index(Some(IndexPath::new(0)), window, cx);
            cx.emit(SelectEvent::<Menu>::Confirm(Some(MenuValue {
                revision: 1,
                id: "native-light".into(),
            })));
        });
    })
    .unwrap();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(
            window.find("themeLibraryScheme").value(),
            Some("DBeer Dark")
        );
        view.update(cx, |this, cx| {
            this.invalidate(cx);
            this.emit_at(2, LibraryAction::RequestImport, cx);
            assert!(!this.set_presentation(
                presentation(3, "native-light", Workflow::Idle),
                window,
                cx
            ));
        });
    })
    .unwrap();
    assert!(events.borrow().is_empty());
}
