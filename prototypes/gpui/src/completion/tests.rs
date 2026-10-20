//! Prepared retained-view cases. Execution remains deferred to final integration.
use super::Invocation;
use gpui_kit::AppContext;

#[gpui::test]
fn retained_native_selection_focus_and_modal_owners_invalidate_pending_completion(
    cx: &mut gpui::TestAppContext,
) {
    let (window, view) = crate::workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let editor = this.tabs[this.active].editor.clone();
            editor.update(cx, |state, cx| {
                state.set_value("SELECT order_name", window, cx);
                state.set_selected_range(17..17, cx);
                state.focus(window, cx);
            });
            let (_, _, _, stamp) = this.completion_editor(window, cx).unwrap();
            this.completion.stamp = Some(stamp);
            let original_revision = editor.read(cx).accessibility_document_revision();
            editor.update(cx, |state, cx| {
                state.set_selected_range(10..10, cx);
                state.set_selected_range(17..17, cx);
            });
            assert_eq!(
                editor.read(cx).accessibility_document_revision(),
                original_revision
            );
            this.completion_selection_changed(window, cx);
            assert!(this.completion.stamp.is_none());
            let (_, _, _, stamp) = this.completion_editor(window, cx).unwrap();
            this.completion.stamp = Some(stamp);
            this.search.update(cx, |state, cx| state.focus(window, cx));
            this.completion_selection_changed(window, cx);
            assert!(this.completion.stamp.is_none());
            assert_eq!(this.tabs[this.active].editor, editor);
            editor.update(cx, |state, cx| state.focus(window, cx));
            this.closing = true;
            assert!(this.completion_editor(window, cx).is_none());
            this.closing = false;
            assert!(!this.tabs[this.active].error);
        });
    })
    .unwrap();
}

#[gpui::test]
fn source_programmatic_changes_preserve_execution_namespace_and_do_not_auto_complete(
    cx: &mut gpui::TestAppContext,
) {
    let (window, view) = crate::workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let index = this.active;
            let id = this.tabs[index].id;
            let editor = this.tabs[index].editor.clone();
            this.tabs[index].status = "Original execution status".into();
            this.tabs[index].error = true;
            this.dismiss_completion();
            this.refresh_syntax_diagnostics(cx);
            assert_eq!(this.tabs[index].status, "Original execution status");
            assert!(this.tabs[index].error);
            editor.update(cx, |state, cx| state.set_value("SELECT 42", window, cx));
            this.completion_source_changed(id, cx);
            assert!(this.completion.task.is_none());
            assert!(this.completion.stamp.is_none());
            assert_eq!(this.tabs[index].editor, editor);
            this.completion.epoch = Some(u64::MAX);
            this.dismiss_completion();
            assert!(this.completion.epoch.is_none());
            this.start_completion(id, Invocation::Manual, window, cx);
            assert!(this.completion.task.is_none());
            assert_eq!(editor.read(cx).value(), "SELECT 42");
        });
    })
    .unwrap();
}

#[gpui::test]
fn connection_cancel_success_failed_save_and_old_callbacks_restore_assistance(
    cx: &mut gpui::TestAppContext,
) {
    use gpui_kit::{component::WindowExt, test::TestWindowExt};
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../build/gpui/quality-profile-assistance-tests")
        .join(uuid::Uuid::new_v4().to_string());
    let store = crate::connections::ProfileStore::acquire(root.join("connections.json")).unwrap();
    let profile = crate::connections::ConnectionProfile::new();
    store.save(std::slice::from_ref(&profile)).unwrap();
    let (window, view) = crate::workspace_tests::workspace(cx);
    cx.update(|cx| cx.background_executor().allow_parking());
    let old = cx
        .update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.profile_store = Some(store.clone());
                this.profiles = vec![crate::workspace::Profile::saved(profile.clone())];
                this.tabs[this.active].profile = crate::model::ProfileId::saved(&profile);
                this.edit_profile(Some(0), window, cx);
                assert!(this.completion_editor(window, cx).is_none());
                this.profile_editor.clone().unwrap()
            })
        })
        .unwrap();
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        window.click("connection-cancel", cx);
        view.update(cx, |this, cx| {
            let editor = this.tabs[this.active].editor.clone();
            editor.update(cx, |state, cx| {
                state.set_value("SELECT f(", window, cx);
                state.set_selected_range(9..9, cx);
                state.focus(window, cx);
            });
            assert!(this.completion_editor(window, cx).is_some());
            this.edit_profile(Some(0), window, cx);
        });
        old.update(cx, |old, cx| old.cancel(window, cx));
        assert!(
            window.has_active_dialog(cx),
            "An old cancelled form closed its replacement."
        );
        window.render_frame(cx);
        window.click("connection-save", cx);
    })
    .unwrap();
    crate::workspace_tests::await_workspace(cx, &view, |this| !this.closing);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.tabs[this.active]
                .editor
                .update(cx, |state, cx| state.focus(window, cx));
            assert!(this.completion_editor(window, cx).is_some());
            for invocation in [super::Invocation::Manual, super::Invocation::Automatic] {
                this.start_completion(this.tabs[this.active].id, invocation, window, cx);
                assert!(this.completion.task.is_some());
                this.dismiss_completion();
            }
            this.start_signatures(
                this.tabs[this.active].id,
                crate::signature_view::Invocation::Manual,
                window,
                cx,
            );
            assert!(this.signature_escape(false, window, cx));
            this.edit_profile(Some(0), window, cx);
        })
    })
    .unwrap();
    std::fs::write(root.join("connections.json"), b"corrupt synthetic metadata").unwrap();
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        window.click("connection-save", cx);
    })
    .unwrap();
    crate::workspace_tests::await_workspace(cx, &view, |this| !this.closing);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            assert!(this.profile_editor.as_ref().unwrap().read(cx).is_active());
            assert!(this.completion_editor(window, cx).is_none());
        });
        window.render_frame(cx);
        window.click("connection-cancel", cx);
        view.update(cx, |this, cx| {
            this.tabs[this.active]
                .editor
                .update(cx, |state, cx| state.focus(window, cx));
            assert!(this.completion_editor(window, cx).is_some());
            assert!(this.backend.is_none());
        });
    })
    .unwrap();
    assert_recovered_fake_assistance(cx, window, &view);
    drop(store);
    _ = std::fs::remove_dir_all(root);
}

// Exercises both retained popup publication paths after the real modal callbacks.
pub(crate) fn assert_recovered_fake_assistance(
    cx: &mut gpui::TestAppContext,
    window: gpui_kit::AnyWindowHandle,
    view: &gpui_kit::Entity<crate::Workspace>,
) {
    let path = crate::signature_view::fixture("normal");
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.tabs[this.active].editor.update(cx, |state, cx| {
                state.set_value("SELECT f(", window, cx);
                state.set_selected_range(9..9, cx);
                state.focus(window, cx);
            });
            this.assistance_fixture(path, cx);
        })
    })
    .unwrap();
    crate::workspace_tests::await_workspace(cx, view, |this| {
        this.assistance_process_generation(this.tabs[this.active].id)
            .is_some()
    });
    for invocation in [super::Invocation::Manual, super::Invocation::Automatic] {
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let id = this.tabs[this.active].id;
                this.start_completion(id, invocation, window, cx);
                this.start_signatures(id, crate::signature_view::Invocation::Manual, window, cx);
            })
        })
        .unwrap();
        crate::workspace_tests::await_window(
            cx,
            window,
            std::time::Duration::from_secs(10),
            |window, cx| {
                view.update(cx, |this, cx| {
                    this.completion_overlay(window, cx).is_some()
                        && this.signature_overlay(window, cx).is_some()
                })
            },
        );
        cx.update_window(window, |_, _, cx| {
            view.update(cx, |this, _| {
                this.dismiss_completion();
                this.dismiss_signatures();
            })
        })
        .unwrap();
    }
}

fn popup_workspace(
    cx: &mut gpui::TestAppContext,
) -> (
    gpui_kit::AnyWindowHandle,
    gpui_kit::Entity<crate::Workspace>,
) {
    let (window, view) = crate::workspace_tests::workspace(cx);
    cx.update(crate::commands::install_keys);
    cx.update_window(window, |_, _, cx| {
        view.update(cx, |this, cx| {
            // The actual bundled Go LSP is offline: this creates no database
            // backend, credential request, or SQL session.
            this.assistance_fixture(crate::platform::helper_path(), cx);
        });
    })
    .unwrap();
    crate::workspace_tests::await_workspace(cx, &view, |this| {
        this.assistance_process_generation(this.tabs[this.active].id)
            .is_some()
    });
    (window, view)
}
fn prepare_popup(
    cx: &mut gpui::TestAppContext,
    handle: gpui_kit::AnyWindowHandle,
    view: &gpui_kit::Entity<crate::Workspace>,
) {
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.dismiss_completion();
            this.tabs[this.active].editor.update(cx, |state, cx| {
                use gpui_kit::EntityInputHandler;
                state.unmark_text(window, cx);
                state.set_value("", window, cx);
                // set_value is silent; this existing nonsilent edit publishes
                // the real Change that advances the owner's source generation.
                state.replace_all("SELECT ", window, cx);
                state.set_selected_range(7..7, cx);
                state.focus(window, cx);
            });
        });
    })
    .unwrap();
    // The keyboard test begins only once the sole real LSP actor owns this
    // exact source/context; synthetic test-clock advancement is not I/O proof.
    crate::workspace_tests::await_window(
        cx,
        handle,
        std::time::Duration::from_secs(10),
        |_, cx| {
            view.update(cx, |this, cx| {
                this.assistance_request(this.tabs[this.active].id, cx)
                    .is_some()
            })
        },
    );
    cx.update_window(handle, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.start_completion(this.tabs[this.active].id, Invocation::Manual, window, cx);
        });
    })
    .unwrap();
    crate::workspace_tests::await_window(
        cx,
        handle,
        std::time::Duration::from_secs(10),
        |window, cx| view.update(cx, |this, cx| this.completion_overlay(window, cx).is_some()),
    );
}
fn popup_position(
    this: &mut crate::Workspace,
    window: &mut gpui_kit::Window,
    cx: &mut gpui_kit::Context<crate::Workspace>,
) -> (usize, usize) {
    let (_, _, native, _) = this.completion_editor(window, cx).unwrap();
    let mut popup = std::mem::take(&mut this.completion.popup);
    let presentation = popup
        .presentation(Some(&native), window, cx, |capture, cx| {
            this.assistance_capture_current(capture, cx)
        })
        .unwrap();
    let result = (presentation.selected_index(), presentation.item_count());
    this.completion.popup = popup;
    result
}
fn no_query_authority(this: &crate::Workspace) {
    assert!(this.backend.is_none());
    assert!(this.tabs.iter().all(|tab| tab.session.is_none()
        && tab.query_id.is_none()
        && !tab.busy()
        && tab.executions.is_empty()));
}

#[gpui::test]
fn original_popup_keys_navigate_accept_and_dismiss_without_moving_caret_or_sql_authority(
    cx: &mut gpui::TestAppContext,
) {
    use gpui_kit::{Focusable, test::TestWindowExt};
    let (handle, view) = popup_workspace(cx);
    prepare_popup(cx, handle, &view);
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
        let editor = view.read(cx).tabs[0].editor.clone();
        let original = editor.read(cx).value();
        let selection = editor.read(cx).selected_range();
        let count = view.update(cx, |this, cx| popup_position(this, window, cx).1);
        assert!(
            count > 1,
            "The actual offline service must offer multiple navigation rows."
        );
        for (key, expected) in [
            ("down", 1),
            ("end", count - 1),
            ("up", count - 2),
            ("home", 0),
        ] {
            window.press(key, cx);
            assert_eq!(
                view.update(cx, |this, cx| popup_position(this, window, cx).0),
                expected
            );
            assert!(editor.read(cx).value() == original);
            assert_eq!(editor.read(cx).selected_range(), selection);
            assert!(editor.focus_handle(cx).is_focused(window));
            no_query_authority(view.read(cx));
        }
        window.press("escape", cx);
        assert!(!view.read(cx).completion.visible);
        assert!(editor.read(cx).value() == original);
        assert_eq!(editor.read(cx).selected_range(), selection);
    })
    .unwrap();
    for key in ["tab", "enter"] {
        prepare_popup(cx, handle, &view);
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            let editor = view.read(cx).tabs[0].editor.clone();
            let original = editor.read(cx).value();
            let selection = editor.read(cx).selected_range();
            window.press(key, cx);
            assert!(!view.read(cx).completion.visible);
            assert!(editor.read(cx).value() != original);
            assert!(!editor.read(cx).value().contains(['\n', '\t']));
            assert!(editor.focus_handle(cx).is_focused(window));
            no_query_authority(view.read(cx));
            window.press(&crate::platform::binding("z"), cx);
            assert!(
                editor.read(cx).value() == original,
                "Completion must remain one native undo edit."
            );
            assert_eq!(editor.read(cx).selected_range(), selection);
        })
        .unwrap();
    }
}

#[gpui::test]
fn stale_popup_tags_delegate_all_original_input_aliases_without_acceptance(
    cx: &mut gpui::TestAppContext,
) {
    use gpui_kit::{EntityInputHandler, test::TestWindowExt};
    let (handle, view) = popup_workspace(cx);
    for key in ["enter", "tab", "up", "down", "home", "end", "escape"] {
        let mut baseline = None;
        for stale_tag in [false, true] {
            prepare_popup(cx, handle, &view);
            cx.update_window(handle, |_, window, cx| {
                window.render_frame(cx);
                view.update(cx, |this, _| this.dismiss_completion());
                if !stale_tag {
                    window.render_frame(cx);
                }
                assert_eq!(
                    window
                        .context_stack()
                        .iter()
                        .any(|c| c.contains("DBeerCompletionKeys")),
                    stale_tag
                );
                window.press(key, cx);
                let editor = view.read(cx).tabs[0].editor.clone();
                let snapshot = (
                    editor.read(cx).value(),
                    editor.read(cx).selected_range(),
                    editor.update(cx, |state, cx| state.marked_text_range(window, cx)),
                );
                if let Some(native) = &baseline {
                    assert!(
                        snapshot == *native,
                        "A stale popup tag changed the original Input alias: {key}"
                    );
                } else {
                    baseline = Some(snapshot);
                }
                assert!(!view.read(cx).completion.visible);
                no_query_authority(view.read(cx));
            })
            .unwrap();
        }
    }
}

#[gpui::test]
fn held_marked_and_character_priority_popup_events_preserve_native_input_baseline(
    cx: &mut gpui::TestAppContext,
) {
    use gpui_kit::{
        EntityInputHandler, InputEvent, KeyDownEvent, KeyUpEvent, Keystroke, test::TestWindowExt,
    };
    let (handle, view) = popup_workspace(cx);
    for refusal in ["held", "marked", "character"] {
        let keys: &[&str] = if refusal == "held" {
            &["enter", "tab", "escape"]
        } else {
            &["enter", "tab", "up", "down", "home", "end", "escape"]
        };
        for key in keys {
            let mut baseline = None;
            for offered in [false, true] {
                prepare_popup(cx, handle, &view);
                cx.update_window(handle, |_, window, cx| {
                    let editor = view.read(cx).tabs[0].editor.clone();
                    if !offered {
                        view.update(cx, |this, _| this.dismiss_completion());
                    }
                    window.render_frame(cx);
                    if refusal == "marked" {
                        editor.update(cx, |state, cx| {
                            state.replace_and_mark_text_in_range(
                                None,
                                "compose",
                                Some(7..7),
                                window,
                                cx,
                            )
                        });
                        // Composition begins after the genuine popup render.
                        // The original marked input and rendered tag coexist at
                        // the event boundary; no further render is requested.
                        assert!(editor.update(cx, |state, cx| {
                            state.marked_text_range(window, cx).is_some()
                        }));
                    }
                    assert_eq!(
                        window
                            .context_stack()
                            .iter()
                            .any(|c| c.contains("DBeerCompletionKeys")),
                        offered
                    );
                    let keystroke = Keystroke::parse(key).unwrap();
                    window.dispatch_event(
                        KeyDownEvent {
                            keystroke: keystroke.clone(),
                            is_held: refusal == "held",
                            prefer_character_input: refusal == "character",
                        }
                        .to_platform_input(),
                        cx,
                    );
                    window.dispatch_event(KeyUpEvent { keystroke }.to_platform_input(), cx);
                    let snapshot = (
                        editor.read(cx).value(),
                        editor.read(cx).selected_range(),
                        editor.update(cx, |state, cx| state.marked_text_range(window, cx)),
                    );
                    if let Some(native) = &baseline {
                        assert!(
                            snapshot == *native,
                            "A refused popup event changed original Input behavior: {refusal}/{key}"
                        );
                    } else {
                        baseline = Some(snapshot);
                    }
                    no_query_authority(view.read(cx));
                })
                .unwrap();
            }
        }
    }
}
