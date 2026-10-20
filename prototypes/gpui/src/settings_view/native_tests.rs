//! Prepared headless control tests only, never native platform acceptance.
use super::{Menu, MenuValue, Presentation, SettingsAction, SettingsEvent, SettingsView};
use crate::appearance::{Preferences, Scheme, StoreError, apply_application};
use gpui_kit::{
    AnyWindowHandle, AppContext, Bounds, Entity, Focusable, Point, TestAppContext, WindowBounds,
    WindowOptions,
    component::{IndexPath, select::SelectEvent},
    px, size,
    test::{TestAppContextExt, TestWindowExt},
};
use std::{cell::RefCell, rc::Rc, time::Duration};

fn settings(cx: &mut TestAppContext) -> (AnyWindowHandle, Entity<SettingsView>) {
    let result = cx.update(|cx| {
        gpui_kit::init(cx);
        gpui_kit::open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds {
                    origin: Point::default(),
                    size: size(px(680.), px(740.)),
                })),
                ..Default::default()
            },
            cx,
            |window, cx| {
                cx.new(|cx| {
                    SettingsView::new(
                        Presentation::new(
                            1,
                            &Preferences::default(),
                            Scheme::Light,
                            &crate::theme_library::builtin_themes().unwrap(),
                            super::super::PersistenceState::Saved,
                        ),
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
fn retained_preview_selection_focus_and_control_entities_survive_opposite_palettes(
    cx: &mut TestAppContext,
) {
    let (handle, view) = settings(cx);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let preview = view.read(cx).preview.clone();
        let app = view.read(cx).application.entity_id();
        let editor = view.read(cx).editor.entity_id();
        preview.update(cx, |state, cx| {
            state.set_selected_range(5..12, cx);
            state.focus(window, cx);
        });
        window.render_frame(cx);
        let source = preview.read(cx).value();
        let selection = preview.read(cx).selected_range();
        let scroll = preview.read(cx).scroll_offset();
        let themes = crate::theme_library::builtin_themes().unwrap();
        let mut preferences = Preferences::default();
        for (revision, app_id, editor_id) in [
            (2, "dark", "native-light"),
            (3, "light", "native-dark"),
            (4, "solarized-dark", "jetbrains-light"),
            (5, "system", "automatic"),
        ] {
            preferences.choose_application(app_id, &themes);
            preferences.choose_editor(editor_id, &themes);
            apply_application(
                &preferences.resolve(Scheme::Light, &themes),
                Some(window),
                cx,
            );
            view.update(cx, |this, cx| {
                this.set_presentation(
                    Presentation::new(
                        revision,
                        &preferences,
                        Scheme::Light,
                        &themes,
                        super::super::PersistenceState::Saved,
                    ),
                    window,
                    cx,
                );
            });
            window.render_frame(cx);
            assert_eq!(view.read(cx).preview.entity_id(), preview.entity_id());
            assert_eq!(view.read(cx).application.entity_id(), app);
            assert_eq!(view.read(cx).editor.entity_id(), editor);
            assert_eq!(preview.read(cx).value(), source);
            assert_eq!(preview.read(cx).selected_range(), selection);
            assert_eq!(preview.read(cx).scroll_offset(), scroll);
            assert!(preview.focus_handle(cx).is_focused(window));
            assert!(!preview.read(cx).is_editable());
        }
        window.input("this must not replace the sample", cx);
        assert_eq!(preview.read(cx).value(), source);
    })
    .unwrap();
}

#[gpui_kit::test]
async fn kit_menus_commit_typed_revision_events_and_escape_keeps_original_focus(
    cx: &mut TestAppContext,
) {
    let (handle, view) = settings(cx);
    let events = Rc::new(RefCell::new(Vec::<SettingsEvent>::new()));
    let _subscription = cx.update(|cx| {
        let events = events.clone();
        cx.subscribe(&view, move |_, event, _| {
            events.borrow_mut().push(event.clone())
        })
    });
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        view.focus_handle(cx).focus(window, cx);
        window.press("enter", cx);
        assert_eq!(window.find("appearanceTheme").expanded(), Some(true));
        window.press("escape", cx);
        assert_eq!(window.find("appearanceTheme").expanded(), Some(false));
        assert!(
            view.read(cx)
                .application
                .focus_handle(cx)
                .is_focused(window)
        );
        window.within("appearanceTheme").click("input", cx);
        window.press("down", cx);
        window.press("enter", cx);
    })
    .unwrap();
    cx.wait_for(handle, Duration::from_millis(100), |_, _| {
        !events.borrow().is_empty()
    })
    .await;
    let received = events.borrow();
    assert_eq!(received.len(), 1);
    assert_eq!(received[0].revision, 1);
    assert_eq!(
        received[0].action,
        SettingsAction::ChooseApplication("light".into())
    );
}

#[gpui_kit::test]
fn retry_reload_done_and_stale_callbacks_use_only_current_typed_owner_actions(
    cx: &mut TestAppContext,
) {
    let (handle, view) = settings(cx);
    let events = Rc::new(RefCell::new(Vec::<SettingsEvent>::new()));
    let _subscription = cx.update(|cx| {
        let events = events.clone();
        cx.subscribe(&view, move |_, event, _| {
            events.borrow_mut().push(event.clone())
        })
    });
    cx.update_window(handle, |_, window, cx| {
        let themes = crate::theme_library::builtin_themes().unwrap();
        view.update(cx, |this, cx| {
            this.set_presentation(
                Presentation::new(
                    2,
                    &Preferences::default(),
                    Scheme::Dark,
                    &themes,
                    super::super::PersistenceState::SaveFailed(StoreError::Write),
                ),
                window,
                cx,
            );
            this.emit_at(1, SettingsAction::RetrySave, cx);
            this.emit_at(1, SettingsAction::Reload, cx);
        });
        window.render_frame(cx);
        assert!(events.borrow().is_empty());
        window.click("retryAppearanceSave", cx);
        window.click("reloadAppearance", cx);
        window.click("closeAppearanceSettings", cx);
        view.update(cx, |this, cx| {
            this.set_presentation(
                Presentation::new(
                    3,
                    &Preferences::default(),
                    Scheme::Dark,
                    &themes,
                    super::super::PersistenceState::ReadOnlyFallback,
                ),
                window,
                cx,
            );
            this.emit_at(3, SettingsAction::RetrySave, cx);
            this.emit_at(2, SettingsAction::ChooseEditor("native-light".into()), cx);
        });
        window.render_frame(cx);
        window.click("reloadAppearance", cx);
    })
    .unwrap();
    let received = events.borrow();
    assert_eq!(received.len(), 4);
    assert_eq!(received[0].action, SettingsAction::RetrySave);
    assert_eq!(received[1].action, SettingsAction::Reload);
    assert_eq!(received[2].action, SettingsAction::Close);
    assert_eq!(received[3].action, SettingsAction::Reload);
    assert_eq!(received[3].revision, 3);
}

#[gpui_kit::test]
fn stale_menu_confirmation_restores_authoritative_display_and_rejects_old_publication(
    cx: &mut TestAppContext,
) {
    let (handle, view) = settings(cx);
    let events = Rc::new(RefCell::new(Vec::<SettingsEvent>::new()));
    let _subscription = cx.update(|cx| {
        let events = events.clone();
        cx.subscribe(&view, move |_, event, _| {
            events.borrow_mut().push(event.clone())
        })
    });
    cx.update_window(handle, |_, window, cx| {
        let themes = crate::theme_library::builtin_themes().unwrap();
        view.update(cx, |this, cx| {
            assert!(this.set_presentation(
                Presentation::new(
                    2,
                    &Preferences::default(),
                    Scheme::Dark,
                    &themes,
                    super::super::PersistenceState::Saved,
                ),
                window,
                cx,
            ));
            assert!(!this.set_presentation(
                Presentation::new(
                    1,
                    &Preferences::default(),
                    Scheme::Light,
                    &themes,
                    super::super::PersistenceState::Saved,
                ),
                window,
                cx,
            ));
        });
        let application = view.read(cx).application.clone();
        application.update(cx, |state, cx| {
            state.set_selected_index(Some(IndexPath::new(1)), window, cx);
            cx.emit(SelectEvent::<Menu>::Confirm(Some(MenuValue {
                revision: 1,
                id: "light".into(),
            })));
        });
    })
    .unwrap();
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        assert_eq!(window.find("appearanceTheme").value(), Some("System"));
        assert_eq!(view.read(cx).presentation.revision(), 2);
    })
    .unwrap();
    assert!(events.borrow().is_empty());
}
