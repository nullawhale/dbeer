//! Prepared real retained-control/headless cases, not native desktop acceptance.
use super::{
    Action, ConfigurableCommand, Edit, Event, Presentation, RecordingToken, ShortcutSettingsView,
};
use crate::{
    shortcut_settings_view::PersistenceState,
    shortcuts::{NativePlatform, Preferences, StoreError},
};
use gpui_kit::test::TestWindowExt;
use gpui_kit::{
    AnyWindowHandle, App, AppContext, Bounds, Entity, EntityInputHandler, Focusable, Point,
    TestAppContext, Window, WindowBounds, WindowOptions, px, size,
};
use std::{cell::RefCell, rc::Rc};

fn settings(cx: &mut TestAppContext) -> (AnyWindowHandle, Entity<ShortcutSettingsView>) {
    let result = cx.update(|cx| {
        gpui_kit::init(cx);
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Point::default(),
                    size: size(px(880.), px(1100.)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| {
                cx.new(|cx| {
                    ShortcutSettingsView::new(
                        Presentation::new(
                            1,
                            &Preferences::default(),
                            NativePlatform::current(),
                            PersistenceState::Saved,
                        )
                        .unwrap(),
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
fn begin_first(
    view: &Entity<ShortcutSettingsView>,
    window: &mut Window,
    cx: &mut App,
) -> RecordingToken {
    view.update(cx, |this, cx| {
        this.begin(
            this.state.scope(),
            ConfigurableCommand::RunCurrent,
            window,
            cx,
        );
        this.state.token().unwrap()
    })
}

#[gpui_kit::test]
fn actual_record_cancel_and_clear_controls_keep_the_authoritative_mapping_until_projection(
    cx: &mut TestAppContext,
) {
    let (handle, view) = settings(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click(("record-shortcut", 0usize), cx);
        let first = view.read(cx).state.token().unwrap();
        assert!(
            view.read(cx).inputs[0]
                .input
                .focus_handle(cx)
                .is_focused(window)
        );
        window.click(("record-shortcut", 0usize), cx);
        assert!(view.read(cx).state.token().is_none());
        window.click(("record-shortcut", 0usize), cx);
        assert_ne!(view.read(cx).state.token().unwrap(), first);
        window.click(("clear-shortcut", 0usize), cx);
        assert!(view.read(cx).state.token().is_none());
        let request = view.read(cx).state.pending.clone().unwrap();
        assert_eq!(
            request.action,
            Action::Edit(Edit::Clear(ConfigurableCommand::RunCurrent))
        );
        assert!(
            view.read(cx)
                .presentation()
                .rows()
                .next()
                .unwrap()
                .current
                .is_some()
        );
        let next = view
            .read(cx)
            .presentation()
            .candidate(&Edit::Clear(ConfigurableCommand::RunCurrent))
            .unwrap();
        view.update(cx, |this, cx| {
            this.set_presentation(
                Presentation::new(2, &next, NativePlatform::current(), PersistenceState::Saved)
                    .unwrap(),
                window,
                cx,
            );
        });
        window.render_frame(cx);
        assert_eq!(
            view.read(cx).presentation().rows().next().unwrap().source,
            crate::shortcut_settings_view::MappingSource::Unbound
        );
        window.click(("restore-shortcut", 0usize), cx);
        assert_eq!(
            view.read(cx).state.pending.as_ref().unwrap().action,
            Action::Edit(Edit::RestoreDefault(ConfigurableCommand::RunCurrent))
        );
    })
    .unwrap();
}

#[gpui_kit::test]
fn retained_original_input_focus_blur_aba_and_dismiss_invalidate_recorders(
    cx: &mut TestAppContext,
) {
    let (handle, view) = settings(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let input = view.read(cx).inputs[0].input.clone();
        let identity = input.entity_id();
        let first = begin_first(&view, window, cx);
        window.render_frame(cx);
        assert!(input.focus_handle(cx).is_focused(window));
        assert!(input.read(cx).is_editable());
        window.blur(cx);
        window.render_frame(cx);
        view.update(cx, |this, cx| this.focus_lost(first, window, cx));
        assert!(view.read(cx).state.token().is_none());
        let second = begin_first(&view, window, cx);
        view.update(cx, |this, cx| {
            this.focus_lost(first, window, cx);
            this.capture_traversal(first, false, window, cx);
        });
        assert_eq!(view.read(cx).state.token(), Some(second));
        window.blur(cx);
        view.update(cx, |this, cx| {
            this.capture_traversal(second, false, window, cx)
        });
        assert_eq!(view.read(cx).state.token(), Some(second));
        input.focus_handle(cx).focus(window, cx);
        view.update(cx, |this, cx| {
            this.set_presentation(
                Presentation::new(
                    2,
                    &Preferences::default(),
                    NativePlatform::current(),
                    PersistenceState::Saved,
                )
                .unwrap(),
                window,
                cx,
            );
        });
        assert_eq!(view.read(cx).inputs[0].input.entity_id(), identity);
        assert!(input.focus_handle(cx).is_focused(window));
        assert!(!input.read(cx).is_editable());
        let last = begin_first(&view, window, cx);
        view.update(cx, |this, cx| {
            this.dismiss(window, cx);
            this.begin(last.scope, last.command, window, cx);
        });
        assert!(view.read(cx).state.token().is_none());
    })
    .unwrap();
}

#[gpui_kit::test]
fn original_marked_input_and_altgr_keep_the_mapping_and_recording_intact(cx: &mut TestAppContext) {
    let (handle, view) = settings(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let token = begin_first(&view, window, cx);
        let input = view.read(cx).inputs[0].input.clone();
        input.update(cx, |input, cx| {
            input.replace_and_mark_text_in_range(None, "compose", Some(7..7), window, cx)
        });
        assert!(input.update(cx, |input, cx| {
            input.marked_text_range(window, cx).is_some()
        }));
        window.render_frame(cx);
        window.press("ctrl-f8", cx);
        assert_eq!(view.read(cx).state.token(), Some(token));
        assert!(view.read(cx).state.pending.is_none());
        assert_eq!(
            view.read(cx).presentation().rows().next().unwrap().current,
            Preferences::default()
                .menu_label(ConfigurableCommand::RunCurrent, NativePlatform::current())
        );
        input.update(cx, |input, cx| input.unmark_text(window, cx));
        window.press("ctrl-alt-f8", cx);
        assert_eq!(view.read(cx).state.token(), Some(token));
        assert!(view.read(cx).state.pending.is_none());
    })
    .unwrap();
}

#[cfg(not(target_os = "linux"))]
#[gpui_kit::test]
fn native_named_escape_and_tab_cancel_using_the_actual_control_tab_graph(cx: &mut TestAppContext) {
    let (handle, view) = settings(cx);
    for key in ["escape", "tab", "shift-tab"] {
        let (token, input) = cx
            .update_window(handle, |_, window, cx| {
                window.render_frame(cx);
                let token = begin_first(&view, window, cx);
                (token, view.read(cx).inputs[0].input.clone())
            })
            .unwrap();
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            assert!(input.focus_handle(cx).is_focused(window));
            window.press(key, cx);
            assert!(
                view.read(cx).state.token().is_none(),
                "Recording did not cancel for {key}."
            );
            assert!(view.read(cx).state.pending.is_none());
            assert_eq!(input.focus_handle(cx).is_focused(window), key == "escape");
            view.update(cx, |this, cx| this.cancel(token, window, cx));
        })
        .unwrap();
    }
}

#[cfg(target_os = "linux")]
#[gpui_kit::test]
fn synthetic_linux_key_without_original_native_dispatch_evidence_cannot_bind(
    cx: &mut TestAppContext,
) {
    let (handle, view) = settings(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let token = begin_first(&view, window, cx);
        window.render_frame(cx);
        window.press("ctrl-f8", cx);
        assert_eq!(view.read(cx).state.token(), Some(token));
        assert!(view.read(cx).state.pending.is_none());
    })
    .unwrap();
}

#[gpui_kit::test]
fn actual_footer_buttons_emit_typed_requests_and_readonly_recovery_has_no_edit_authority(
    cx: &mut TestAppContext,
) {
    let (handle, view) = settings(cx);
    let events = Rc::new(RefCell::new(Vec::<Event>::new()));
    let _subscription = cx.update(|cx| {
        let events = events.clone();
        cx.subscribe(&view, move |_, event, _| {
            events.borrow_mut().push(event.clone())
        })
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("reset-all-shortcuts", cx);
    })
    .unwrap();
    assert_eq!(
        events.borrow().last().unwrap().action,
        Action::Edit(Edit::ResetAll)
    );
    let initial = events.borrow()[0].clone();
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.set_presentation(
                Presentation::new(
                    2,
                    &Preferences::default(),
                    NativePlatform::current(),
                    PersistenceState::SaveFailed(StoreError::Write),
                )
                .unwrap(),
                window,
                cx,
            );
            this.request(initial.scope, Action::Edit(Edit::ResetAll), window, cx);
        });
        window.render_frame(cx);
        window.click("retry-shortcuts", cx);
    })
    .unwrap();
    assert_eq!(events.borrow().last().unwrap().action, Action::RetrySave);
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.set_presentation(
                Presentation::new(
                    3,
                    &Preferences::default(),
                    NativePlatform::current(),
                    PersistenceState::ReadOnlyFallback(StoreError::InvalidBindings),
                )
                .unwrap(),
                window,
                cx,
            );
        });
    })
    .unwrap();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("reset-all-shortcuts").disabled(), Some(true));
        window.click("recover-shortcuts", cx);
    })
    .unwrap();
    assert_eq!(
        events.borrow().last().unwrap().action,
        Action::RecoverDefaults
    );
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.set_presentation(
                Presentation::new(
                    4,
                    &Preferences::default(),
                    NativePlatform::current(),
                    PersistenceState::ReadOnlyFallback(StoreError::Read),
                )
                .unwrap(),
                window,
                cx,
            );
        });
    })
    .unwrap();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        window.click("reload-shortcuts", cx);
    })
    .unwrap();
    assert_eq!(events.borrow().last().unwrap().action, Action::Reload);
    assert_eq!(events.borrow().len(), 4);
}

#[gpui_kit::test]
fn marked_tab_preserves_native_input_traversal_and_cannot_publish_a_binding(
    cx: &mut TestAppContext,
) {
    for key in ["tab", "shift-tab"] {
        let (handle, view) = settings(cx);
        let events = Rc::new(RefCell::new(Vec::<Event>::new()));
        let _subscription = cx.update(|cx| {
            let events = events.clone();
            cx.subscribe(&view, move |_, event, _| {
                events.borrow_mut().push(event.clone())
            })
        });
        let (input, current) = cx
            .update_window(handle, |_, window, cx| {
                window.render_frame(cx);
                begin_first(&view, window, cx);
                let input = view.read(cx).inputs[0].input.clone();
                input.update(cx, |input, cx| {
                    input.replace_and_mark_text_in_range(None, "compose", Some(7..7), window, cx)
                });
                let current = view
                    .read(cx)
                    .presentation()
                    .rows()
                    .next()
                    .unwrap()
                    .current
                    .clone();
                (input, current)
            })
            .unwrap();
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            assert!(input.focus_handle(cx).is_focused(window));
            assert!(input.update(cx, |input, cx| {
                input.marked_text_range(window, cx).is_some()
            }));
            window.press(key, cx);
            // The unmodified Input action retains authority while composing.
            // It naturally traverses; the recorder must not bind or consume it.
            assert!(!input.focus_handle(cx).is_focused(window));
            assert!(view.read(cx).state.pending.is_none());
            assert_eq!(
                view.read(cx).presentation().rows().next().unwrap().current,
                current
            );
        })
        .unwrap();
        cx.run_until_parked();
        cx.update(|cx| {
            assert!(view.read(cx).state.token().is_none());
            assert!(view.read(cx).state.pending.is_none());
        });
        assert!(events.borrow().is_empty());
    }
}
