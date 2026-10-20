//! Prepared command coverage. Runtime execution is deferred to final integration.
use super::{CommandContext, CommandFocus, CommandId, availability};
use crate::model::DocumentId;

fn ready() -> CommandContext {
    CommandContext {
        document: Some(DocumentId(1)),
        focus: CommandFocus::Editor,
        modal: false,
        closing: false,
        composing: false,
        busy: false,
        uncertain: false,
        snapshot_locked: false,
        settings_match: true,
        sql_document: true,
        catalog_document: false,
        has_grid: false,
        has_results: false,
        saved_profile: true,
        profile_busy: false,
        can_store: true,
        has_exports: true,
        transfer_pending: false,
        edit_available: false,
    }
}
#[test]
fn execution_refuses_fields_modal_busy_unknown_changed_settings_and_composition() {
    assert!(availability(CommandId::RunCurrent, &ready()).is_ok());
    assert!(availability(CommandId::RunScript, &ready()).is_ok());
    for changed in [
        CommandContext {
            focus: CommandFocus::TextInput,
            ..ready()
        },
        CommandContext {
            modal: true,
            ..ready()
        },
        CommandContext {
            busy: true,
            ..ready()
        },
        CommandContext {
            uncertain: true,
            ..ready()
        },
        CommandContext {
            settings_match: false,
            ..ready()
        },
        CommandContext {
            composing: true,
            ..ready()
        },
        CommandContext {
            transfer_pending: true,
            ..ready()
        },
        CommandContext {
            document: None,
            ..ready()
        },
    ] {
        assert!(availability(CommandId::RunCurrent, &changed).is_err());
        assert!(availability(CommandId::RunScript, &changed).is_err());
    }
    // Keeping a transaction/session snapshot is intentional: execution remains
    // on its own captured session, while rebinding goes through close guards.
    assert!(
        availability(
            CommandId::RunCurrent,
            &CommandContext {
                snapshot_locked: true,
                ..ready()
            }
        )
        .is_ok()
    );
}
#[test]
fn declared_future_commands_are_explicitly_unavailable() {
    assert!(CommandId::History.unavailable_reason().is_none());
    assert!(availability(CommandId::History, &ready()).is_ok());
    assert!(availability(CommandId::Appearance, &ready()).is_ok());
    assert!(CommandId::RunToJson.unavailable_reason().is_none());
    assert!(CommandId::RunToCsv.unavailable_reason().is_none());
    assert!(availability(CommandId::ShortcutSettings, &ready()).is_ok());
    assert!(CommandId::ExportResultsTsv.unavailable_reason().is_some());
    assert!(availability(CommandId::ExportResultsTsv, &ready()).is_err());
}

#[test]
fn selection_copy_is_available_only_for_idle_grid_context_and_sql_stays_out_of_grid() {
    assert!(
        availability(
            CommandId::NextResult,
            &CommandContext {
                has_results: true,
                has_grid: false,
                ..ready()
            }
        )
        .is_ok()
    );
    let grid = CommandContext {
        focus: CommandFocus::Grid,
        has_grid: true,
        ..ready()
    };
    assert!(availability(CommandId::GridCopy, &grid).is_ok());
    assert!(availability(CommandId::RunCurrent, &grid).is_err());
    assert!(availability(CommandId::RunScript, &grid).is_err());
    for blocked in [
        CommandContext {
            focus: CommandFocus::TextInput,
            ..grid.clone()
        },
        CommandContext {
            busy: true,
            ..grid.clone()
        },
        CommandContext {
            closing: true,
            ..grid.clone()
        },
        CommandContext {
            modal: true,
            ..grid.clone()
        },
        CommandContext {
            has_grid: false,
            ..grid.clone()
        },
        CommandContext {
            transfer_pending: true,
            ..grid.clone()
        },
    ] {
        assert!(availability(CommandId::GridCopy, &blocked).is_err());
    }
    assert!(
        availability(
            CommandId::Copy,
            &CommandContext {
                focus: CommandFocus::TextInput,
                edit_available: true,
                ..grid
            }
        )
        .is_ok()
    );
}
#[test]
fn focused_native_edit_and_stop_use_their_own_availability() {
    assert!(availability(CommandId::Stop, &ready()).is_err());
    assert!(
        availability(
            CommandId::Stop,
            &CommandContext {
                busy: true,
                uncertain: true,
                ..ready()
            }
        )
        .is_ok()
    );
    for command in [
        CommandId::Undo,
        CommandId::Redo,
        CommandId::Cut,
        CommandId::Copy,
        CommandId::Paste,
        CommandId::SelectAll,
    ] {
        assert!(command.edit_action().is_some());
        assert!(availability(command, &ready()).is_err());
        assert!(
            availability(
                command,
                &CommandContext {
                    edit_available: true,
                    modal: true,
                    focus: CommandFocus::TextInput,
                    ..ready()
                }
            )
            .is_ok()
        );
    }
}

#[test]
fn primary_query_bindings_preserve_altgr_plain_enter_and_other_modifiers() {
    use gpui_kit::{KeybindingKeystroke, Keystroke};
    for modifier in ["ctrl", "cmd"] {
        let target = KeybindingKeystroke::from_keystroke(
            Keystroke::parse(&format!("{modifier}-enter")).unwrap(),
        );
        assert!(
            Keystroke::parse(&format!("{modifier}-enter"))
                .unwrap()
                .should_match(&target)
        );
        for key in [
            "enter".to_string(),
            format!("{modifier}-alt-enter"),
            format!("{modifier}-shift-enter"),
        ] {
            assert!(!Keystroke::parse(&key).unwrap().should_match(&target));
        }
    }
    let query = super::DEFAULT_SHORTCUTS
        .iter()
        .filter(|(_, command, _)| matches!(command, CommandId::RunCurrent | CommandId::RunScript))
        .collect::<Vec<_>>();
    assert_eq!(query.len(), 2);
    assert!(
        query
            .iter()
            .all(|(_, _, context)| *context == "DBeerSqlEditor > Input")
    );
    assert!(
        !super::DEFAULT_SHORTCUTS
            .iter()
            .any(|(_, command, _)| *command == CommandId::Stop)
    );
}

#[cfg(feature = "native-smoke")]
mod headless {
    use super::*;
    use crate::commands::CommandOrigin;
    use crate::commands::install_keys;
    use crate::{Workspace, apply_theme, model, platform};
    use gpui_kit::component::{ThemeMode, WindowExt};
    use gpui_kit::test::TestWindowExt;
    use gpui_kit::{
        AnyWindowHandle, AppContext, Entity, EntityInputHandler, TestAppContext, WindowOptions,
        init, open_window,
    };
    fn workspace(cx: &mut TestAppContext) -> (AnyWindowHandle, Entity<Workspace>) {
        let result = cx.update(|cx| {
            init(cx);
            install_keys(cx);
            apply_theme(ThemeMode::Dark, None, cx);
            open_window(WindowOptions::default(), cx, |window, cx| {
                cx.new(|cx| {
                    Workspace::new(
                        None,
                        crate::product_identity::StartupPolicy::new(
                            crate::product_identity::Platform::MacDevelopment,
                            true,
                        ),
                        window,
                        cx,
                    )
                })
            })
            .unwrap()
        });
        crate::workspace_tests::prepare_test_window(cx, result.0);
        result
    }
    #[gpui_kit::test]
    fn fresh_product_new_tab_uses_independent_unbound_documents_without_connection_authority(
        cx: &mut TestAppContext,
    ) {
        let (window, view) = crate::workspace_tests::workspace_with_policy(
            cx,
            crate::product_identity::StartupPolicy::new(
                crate::product_identity::Platform::Linux,
                false,
            ),
        );
        cx.update_window(window, |_, window, cx| {
            window.render_frame(cx);
            view.update(cx, |this, cx| {
                assert!(this.profiles.is_empty());
                let original = this.tabs[0].id;
                let editor = this.tabs[0].editor.entity_id();
                for origin in [
                    CommandOrigin::Button,
                    CommandOrigin::Menu,
                    CommandOrigin::Shortcut,
                ] {
                    let before = this.tabs.len();
                    let capture = this
                        .capture_command(CommandId::NewTab, origin, None, window, cx)
                        .unwrap();
                    assert!(capture.profile.is_none());
                    this.dispatch_command(capture, window, cx);
                    assert_eq!(this.tabs.len(), before + 1);
                    let tab = &this.tabs[this.active];
                    assert_ne!(tab.id, original);
                    assert_ne!(tab.editor.entity_id(), editor);
                    assert_eq!(tab.profile, model::ProfileId::unbound());
                    assert!(tab.editor.read(cx).value().is_empty());
                }
                let ids = this
                    .tabs
                    .iter()
                    .map(|tab| tab.id)
                    .collect::<std::collections::HashSet<_>>();
                let editors = this
                    .tabs
                    .iter()
                    .map(|tab| tab.editor.entity_id())
                    .collect::<std::collections::HashSet<_>>();
                assert_eq!(ids.len(), this.tabs.len());
                assert_eq!(editors.len(), this.tabs.len());
                let snapshot = this.document_snapshot(cx);
                assert_eq!(snapshot.documents.len(), this.tabs.len());
                let persistent_ids = snapshot
                    .documents
                    .iter()
                    .map(|doc| &doc.id)
                    .collect::<std::collections::HashSet<_>>();
                assert_eq!(persistent_ids.len(), this.tabs.len());
                assert!(
                    snapshot
                        .documents
                        .iter()
                        .all(|doc| doc.profile_id.is_none() && doc.text.is_empty())
                );
                assert!(this.backend.is_none() && this.profile_store.is_none());
                assert!(this.tabs.iter().all(|tab| tab.session.is_none()
                    && tab.session_owner.is_none()
                    && tab.operation_client.is_none()
                    && tab.task.is_none()
                    && tab.operation.is_none()
                    && tab.result_sets.is_empty()
                    && tab.executions.is_empty()));
                // An explicitly profile-scoped command retains its own gate.
                let before = this.tabs.len();
                if let Ok(capture) = this.capture_command(
                    CommandId::NewProfileTab,
                    CommandOrigin::Button,
                    None,
                    window,
                    cx,
                ) {
                    this.dispatch_command(capture, window, cx);
                }
                assert_eq!(this.tabs.len(), before);
            });
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn new_tab_retains_captured_saved_or_demo_profile_and_refuses_stale_modal_or_close(
        cx: &mut TestAppContext,
    ) {
        let (window, view) = workspace(cx);
        cx.update_window(window, |_, window, cx| {
            window.render_frame(cx);
            view.update(cx, |this, cx| {
                let saved = crate::connections::ConnectionProfile::new();
                this.profiles.push(crate::workspace::Profile::saved(saved));
                let saved_index = this.profiles.len() - 1;
                for index in [0, saved_index] {
                    this.selected_profile = index;
                    let expected = this.profiles[index].id.clone();
                    let demo = this.profiles[index].demo;
                    let capture = this
                        .capture_command(CommandId::NewTab, CommandOrigin::Menu, None, window, cx)
                        .unwrap();
                    this.selected_profile = if index == 0 { saved_index } else { 0 };
                    this.dispatch_command(capture, window, cx);
                    let tab = &this.tabs[this.active];
                    assert_eq!(tab.profile, expected);
                    assert_eq!(tab.editor.read(cx).value().is_empty(), !demo);
                }
                this.selected_profile = saved_index;
                let stale = this
                    .capture_command(CommandId::NewTab, CommandOrigin::Button, None, window, cx)
                    .unwrap();
                this.profiles[saved_index].config.as_mut().unwrap().host = "changed.invalid".into();
                let before = this.tabs.len();
                assert!(!this.capture_valid(&stale, cx));
                this.dispatch_command(stale, window, cx);
                assert_eq!(this.tabs.len(), before);
                let modal = this
                    .capture_command(CommandId::NewTab, CommandOrigin::Menu, None, window, cx)
                    .unwrap();
                window.open_dialog(cx, |dialog, _, _| {
                    dialog
                        .title("New tab gate")
                        .accessibility_label("New tab gate")
                });
                assert!(
                    this.capture_command(
                        CommandId::NewTab,
                        CommandOrigin::Shortcut,
                        None,
                        window,
                        cx
                    )
                    .is_err()
                );
                this.dispatch_command(modal, window, cx);
                assert_eq!(this.tabs.len(), before);
                window.close_dialog(cx);
                let closing = this
                    .capture_command(CommandId::NewTab, CommandOrigin::Button, None, window, cx)
                    .unwrap();
                this.closing = true;
                assert!(
                    this.capture_command(
                        CommandId::NewTab,
                        CommandOrigin::Shortcut,
                        None,
                        window,
                        cx
                    )
                    .is_err()
                );
                this.dispatch_command(closing, window, cx);
                assert_eq!(this.tabs.len(), before);
                this.closing = false;
                assert!(this.backend.is_none());
                assert!(
                    this.tabs
                        .iter()
                        .all(|tab| tab.session.is_none() && tab.operation_client.is_none())
                );
            });
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn actual_last_profile_deletion_preserves_drafts_and_new_tab_remains_disconnected(
        cx: &mut TestAppContext,
    ) {
        use std::{fs, path::PathBuf, sync::Arc};
        cx.update(|cx| cx.background_executor().allow_parking());
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/new-tab-command-tests")
            .join(crate::restoration::new_uuid());
        let store = crate::connections::synthetic_profile_store(root.join("connections.json"));
        let saved = crate::connections::ConnectionProfile::new();
        store.save_profile(&saved, None, None).unwrap();
        let (window, view) = crate::workspace_tests::workspace_with_policy(
            cx,
            crate::product_identity::StartupPolicy::new(
                crate::product_identity::Platform::Linux,
                false,
            ),
        );
        let (document, editor, persistent, profile) = cx
            .update_window(window, |_, window, cx| {
                window.render_frame(cx);
                view.update(cx, |this, cx| {
                    this.profile_store = Some(store.clone());
                    this.profiles
                        .push(crate::workspace::Profile::saved(saved.clone()));
                    this.selected_profile = 0;
                    this.tabs[0].profile = model::ProfileId::saved(&saved);
                    this.tabs[0].editor.update(cx, |editor, cx| {
                        editor.set_value("retained local draft\r\n", window, cx);
                    });
                    let retained = (
                        this.tabs[0].id,
                        this.tabs[0].editor.entity_id(),
                        this.tabs[0].persistent_id.clone(),
                        this.tabs[0].profile.clone(),
                    );
                    // The document has no session or pending decision; invoke the
                    // actual post-review deletion route with the existing fake store.
                    this.commit_profile_mutation(
                        Arc::new(crate::profiles::ProfileMutation {
                            change: crate::profiles::ProfileChange::Delete(Box::new(saved.clone())),
                            editor: None,
                            startup: false,
                        }),
                        window,
                        cx,
                    );
                    retained
                })
            })
            .unwrap();
        crate::workspace_tests::await_workspace(cx, &view, |this| {
            !this.closing && this.closing_task.is_none()
        });
        assert!(store.load_library().unwrap().connections.is_empty());
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                // Deletion deliberately retains a missing binding; it does not
                // empty the live profile vector or retarget existing SQL drafts.
                assert_eq!(this.profiles.len(), 1);
                assert!(this.profiles[0].config.is_none());
                assert_eq!(this.tabs[0].id, document);
                assert_eq!(this.tabs[0].editor.entity_id(), editor);
                assert_eq!(this.tabs[0].persistent_id, persistent);
                assert_eq!(this.tabs[0].profile, profile);
                assert_eq!(
                    this.tabs[0].editor.read(cx).value().as_ref(),
                    "retained local draft\r\n"
                );
                let capture = this
                    .capture_command(CommandId::NewTab, CommandOrigin::Shortcut, None, window, cx)
                    .unwrap();
                this.dispatch_command(capture, window, cx);
                assert_eq!(this.tabs.len(), 2);
                let new = &this.tabs[this.active];
                assert_ne!(new.id, document);
                assert_ne!(new.editor.entity_id(), editor);
                assert_eq!(new.profile, profile);
                assert!(new.editor.read(cx).value().is_empty());
                assert!(this.backend.is_none());
                assert!(this.tabs.iter().all(|tab| tab.session.is_none()
                    && tab.session_owner.is_none()
                    && tab.operation_client.is_none()
                    && tab.task.is_none()));
                let snapshot = this.document_snapshot(cx);
                assert_eq!(snapshot.documents.len(), 2);
                assert_eq!(snapshot.documents[0].text, "retained local draft\r\n");
                assert!(snapshot.documents[1].text.is_empty());
                assert!(
                    snapshot
                        .documents
                        .iter()
                        .all(|doc| doc.profile_id.as_deref() == Some(saved.id.as_str()))
                );
                // Model boundary: when no selected entry exists, the same actual
                // command reaches the established unbound constructor.
                this.profiles.clear();
                let capture = this
                    .capture_command(CommandId::NewTab, CommandOrigin::Menu, None, window, cx)
                    .unwrap();
                this.dispatch_command(capture, window, cx);
                assert_eq!(this.tabs.len(), 3);
                assert_eq!(this.tabs[this.active].profile, model::ProfileId::unbound());
                assert!(this.backend.is_none());
            });
        })
        .unwrap();
        drop(view);
        drop(store);
        let _ = fs::remove_dir_all(root);
    }
    #[gpui_kit::test]
    fn button_menu_shortcut_capture_identical_sql_and_target(cx: &mut TestAppContext) {
        let (window, view) = workspace(cx);
        cx.update_window(window, |_, window, cx| {
            window.render_frame(cx);
            view.update(cx, |this, cx| {
                this.tabs[0].editor.update(cx, |editor, cx| {
                    editor.set_value("SELECT 1;\r\nSELECT 'smile \u{1f642}';", window, cx);
                    editor.set_selected_range(11..11, cx);
                    editor.focus(window, cx);
                });
                let captures = [
                    CommandOrigin::Button,
                    CommandOrigin::Menu,
                    CommandOrigin::Shortcut,
                ]
                .map(|origin| {
                    this.capture_command(CommandId::RunCurrent, origin, None, window, cx)
                        .unwrap()
                });
                for capture in &captures {
                    assert_eq!(capture.context.document, Some(this.tabs[0].id));
                    assert!(
                        capture
                            .fragment
                            .as_ref()
                            .unwrap()
                            .source_sql()
                            .contains("smile")
                    );
                    assert_eq!(
                        capture.fragment.as_ref().unwrap().span(),
                        captures[0].fragment.as_ref().unwrap().span()
                    );
                }
                let original = captures[0].context.document.unwrap();
                this.add_sql_tab("Other.sql".into(), "SELECT 2;".into(), window, cx);
                assert!(this.capture_valid(&captures[0], cx));
                this.dispatch_command(captures[0].clone(), window, cx);
                assert!(this.tabs.iter().find(|t| t.id == original).unwrap().busy());
                assert!(!this.tabs[this.active].busy());
                this.stop_document(original, cx);
            });
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn stale_source_session_and_operation_captures_never_start_or_stop_new_work(
        cx: &mut TestAppContext,
    ) {
        let (window, view) = workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let capture = this
                    .capture_command(CommandId::RunCurrent, CommandOrigin::Menu, None, window, cx)
                    .unwrap();
                this.tabs[0].generation += 1;
                assert!(!this.capture_valid(&capture, cx));
                this.dispatch_command(capture, window, cx);
                assert!(!this.tabs[0].busy());
                let capture = this
                    .capture_command(
                        CommandId::RunCurrent,
                        CommandOrigin::Button,
                        None,
                        window,
                        cx,
                    )
                    .unwrap();
                this.tabs[0].session_generation += 1;
                assert!(!this.capture_valid(&capture, cx));
                let first = this.tabs[0].begin(None, 1).unwrap();
                let stop = this
                    .capture_command(CommandId::Stop, CommandOrigin::Menu, None, window, cx)
                    .unwrap();
                this.tabs[0].end(&first, model::ExecutionState::Cancelled, 0);
                let next = this.tabs[0].begin(None, 1).unwrap();
                assert!(!this.capture_valid(&stop, cx));
                this.dispatch_command(stop, window, cx);
                assert!(this.tabs[0].owns(&next));
            });
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn text_fields_dialogs_parse_failures_and_ime_start_no_helper(cx: &mut TestAppContext) {
        let (window, view) = workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.search.update(cx, |state, cx| state.focus(window, cx));
            });
            window.render_frame(cx);
            window.press(&platform::binding("enter"), cx);
            view.update(cx, |this, cx| {
                assert!(
                    this.capture_command(
                        CommandId::RunCurrent,
                        CommandOrigin::Button,
                        None,
                        window,
                        cx
                    )
                    .is_err()
                );
                this.tabs[0].editor.update(cx, |editor, cx| {
                    editor.set_value("SELECT 'unfinished", window, cx);
                    editor.focus(window, cx);
                });
                let capture = this
                    .capture_command(CommandId::RunCurrent, CommandOrigin::Menu, None, window, cx)
                    .unwrap();
                this.dispatch_command(capture, window, cx);
                assert!(!this.tabs[0].busy());
                assert!(this.backend.is_none());
                this.tabs[0].editor.update(cx, |editor, cx| {
                    editor.replace_and_mark_text_in_range(None, "compose", Some(0..7), window, cx)
                });
                assert!(
                    this.capture_command(
                        CommandId::RunCurrent,
                        CommandOrigin::Shortcut,
                        None,
                        window,
                        cx
                    )
                    .is_err()
                );
                window.open_dialog(cx, |dialog, _, _| {
                    dialog
                        .title("Settings test")
                        .accessibility_label("Settings test")
                });
                assert!(
                    this.capture_command(
                        CommandId::RunCurrent,
                        CommandOrigin::Menu,
                        None,
                        window,
                        cx
                    )
                    .is_err()
                );
                assert!(this.backend.is_none());
            });
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn exact_primary_shortcut_runs_editor_but_not_altgr_or_filter(cx: &mut TestAppContext) {
        let (window, view) = workspace(cx);
        cx.update_window(window, |_, window, cx| {
            let editor = view.read(cx).tabs[0].editor.clone();
            editor.update(cx, |editor, cx| {
                editor.set_value("SELECT 1;", window, cx);
                editor.set_selected_range(9..9, cx);
                editor.focus(window, cx);
            });
        })
        .unwrap();
        cx.update_window(window, |_, window, cx| {
            window.render_frame(cx);
            window.press(&platform::binding("alt-enter"), cx);
            assert!(!view.read(cx).tabs[0].busy());
            window.press(&platform::binding("enter"), cx);
            assert!(view.read(cx).tabs[0].busy());
            view.update(cx, |this, cx| {
                let id = this.tabs[0].id;
                this.stop_document(id, cx);
                this.tabs[0]
                    .filter
                    .update(cx, |state, cx| state.focus(window, cx));
            });
            window.render_frame(cx);
            window.press(&platform::binding("enter"), cx);
            assert!(!view.read(cx).tabs[0].busy());
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn cleared_and_rebound_primary_enter_keep_native_editing_and_current_mapping_authority(
        cx: &mut TestAppContext,
    ) {
        use crate::shortcuts::{ConfigurableCommand, Modifiers, Shortcut};
        let (window, view) = workspace(cx);
        for redraw in [false, true] {
            for rebound in [false, true] {
                let editor = cx
                    .update_window(window, |_, window, cx| {
                        view.update(cx, |this, cx| {
                            this.shortcuts
                                .preferences
                                .restore_default(
                                    ConfigurableCommand::RunCurrent,
                                    crate::shortcuts::NativePlatform::current(),
                                )
                                .unwrap();
                            let editor = this.tabs[0].editor.clone();
                            editor.update(cx, |state, cx| {
                                state.set_value("SELECT 1;", window, cx);
                                state.set_selected_range(9..9, cx);
                                state.focus(window, cx);
                            });
                            cx.notify();
                            editor
                        })
                    })
                    .unwrap();
                cx.update_window(window, |_, window, cx| {
                    window.render_frame(cx);
                    // This mutation deliberately does not invalidate the frame.
                    // The first branch retains the old NoAction context while
                    // the raw callback consults the CURRENT mapping.
                    view.update(cx, |this, _| {
                        this.shortcuts
                            .preferences
                            .clear(
                                ConfigurableCommand::RunCurrent,
                                crate::shortcuts::NativePlatform::current(),
                            )
                            .unwrap();
                        if rebound {
                            this.shortcuts
                                .preferences
                                .set(
                                    ConfigurableCommand::RunCurrent,
                                    crate::shortcuts::BindingChoice::Bound(Shortcut::new(
                                        "f9",
                                        Modifiers {
                                            control: true,
                                            ..Default::default()
                                        },
                                    )),
                                    crate::shortcuts::NativePlatform::current(),
                                )
                                .unwrap();
                        }
                    });
                    if redraw {
                        window.render_frame(cx);
                    }
                    assert_eq!(
                        window
                            .context_stack()
                            .iter()
                            .any(|c| c.contains("DBeerCapturePrimaryEnter")),
                        !redraw
                    );
                    window.press(&platform::binding("enter"), cx);
                    assert!(!view.read(cx).tabs[0].busy());
                    assert!(view.read(cx).backend.is_none());
                    assert!(
                        editor.read(cx).value() == "SELECT 1;\n",
                        "Native Enter editing was lost after a mapping edit."
                    );
                    assert_eq!(editor.read(cx).selected_range(), 10..10);
                    if rebound {
                        window.press("ctrl-f9", cx);
                        assert!(view.read(cx).tabs[0].busy());
                        view.update(cx, |this, cx| this.stop_document(this.tabs[0].id, cx));
                    }
                })
                .unwrap();
            }
        }
    }

    #[gpui_kit::test]
    fn refused_bound_primary_enter_matches_original_native_input_for_held_marked_and_unknown(
        cx: &mut TestAppContext,
    ) {
        use crate::shortcuts::ConfigurableCommand;
        use gpui_kit::{InputEvent, KeyDownEvent, KeyUpEvent, Keystroke};
        let (window, view) = workspace(cx);
        for refusal in ["held", "marked", "unknown", "character"] {
            let mut baseline = None;
            for bound in [false, true] {
                let editor = cx
                    .update_window(window, |_, window, cx| {
                        view.update(cx, |this, cx| {
                            if bound {
                                this.shortcuts
                                    .preferences
                                    .restore_default(
                                        ConfigurableCommand::RunCurrent,
                                        crate::shortcuts::NativePlatform::current(),
                                    )
                                    .unwrap();
                            } else {
                                this.shortcuts
                                    .preferences
                                    .clear(
                                        ConfigurableCommand::RunCurrent,
                                        crate::shortcuts::NativePlatform::current(),
                                    )
                                    .unwrap();
                            }
                            this.tabs[0].uncertain = refusal == "unknown";
                            let editor = this.tabs[0].editor.clone();
                            editor.update(cx, |state, cx| {
                                state.unmark_text(window, cx);
                                state.set_value("SELECT 1;", window, cx);
                                state.set_selected_range(9..9, cx);
                                state.focus(window, cx);
                                if refusal == "marked" {
                                    state.replace_and_mark_text_in_range(
                                        None,
                                        "compose",
                                        Some(7..7),
                                        window,
                                        cx,
                                    );
                                }
                            });
                            cx.notify();
                            editor
                        })
                    })
                    .unwrap();
                cx.update_window(window, |_, window, cx| {
                    window.render_frame(cx);
                    let keystroke = Keystroke::parse(&platform::binding("enter")).unwrap();
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
                    let this = view.read(cx);
                    assert!(!this.tabs[0].busy() && this.backend.is_none());
                    assert!(this.tabs[0].executions.is_empty());
                    let state = (
                        editor.read(cx).value(),
                        editor.read(cx).selected_range(),
                        editor.update(cx, |state, cx| state.marked_text_range(window, cx)),
                    );
                    if let Some(original) = &baseline {
                        assert!(
                            state == *original,
                            "A refused bound shortcut changed the native input behavior: {refusal}"
                        );
                    } else {
                        baseline = Some(state);
                    }
                })
                .unwrap();
            }
        }
    }

    #[gpui_kit::test]
    fn default_primary_shift_enter_reviews_original_whole_source_without_execution(
        cx: &mut TestAppContext,
    ) {
        let (window, view) = workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.read(cx).tabs[0]
                .editor
                .clone()
                .update(cx, |state, cx| {
                    state.set_value("SELECT 1; SELECT 2;", window, cx);
                    state.set_selected_range(0..0, cx);
                    state.focus(window, cx);
                });
        })
        .unwrap();
        cx.update_window(window, |_, window, cx| {
            window.render_frame(cx);
            window.press(&platform::binding("shift-enter"), cx);
            assert!(window.has_active_dialog(cx));
            let this = view.read(cx);
            assert_eq!(
                this.tabs[0].phase,
                Some(crate::model::OperationPhase::Reviewing)
            );
            assert!(this.tabs[0].editor.read(cx).value() == "SELECT 1; SELECT 2;");
            assert!(
                this.backend.is_none()
                    && this.tabs[0].session.is_none()
                    && this.tabs[0].query_id.is_none()
            );
            assert_eq!(this.tabs[0].executions.len(), 2);
            assert!(this.tabs[0].executions.iter().all(|e| e.state
                == model::ExecutionState::Pending
                && e.started_at.is_none()
                && !e.history_recorded
                && e.results.is_empty()));
            window.press("escape", cx);
        })
        .unwrap();
        crate::workspace_tests::await_workspace(cx, &view, |this| !this.tabs[0].busy());
        cx.update(|cx| {
            let this = view.read(cx);
            assert!(
                this.backend.is_none()
                    && this.tabs[0].session.is_none()
                    && this.tabs[0].query_id.is_none()
            );
            assert!(
                this.tabs[0].result_sets.is_empty() && this.tabs[0].successful_ranges.is_empty()
            );
            assert_eq!(this.tabs[0].executions.len(), 2);
            assert!(
                this.tabs[0]
                    .executions
                    .iter()
                    .all(|e| e.started_at.is_none()
                        && e.results.is_empty()
                        && matches!(
                            e.state,
                            model::ExecutionState::Cancelled | model::ExecutionState::Skipped
                        ))
            );
        });
    }
}

#[test]
fn file_commands_preserve_session_independence_and_respect_sql_dialog_and_close_gates() {
    for command in [CommandId::OpenSql, CommandId::SaveSql, CommandId::SaveSqlAs] {
        assert!(availability(command, &ready()).is_ok());
        assert!(
            availability(
                command,
                &CommandContext {
                    busy: true,
                    uncertain: true,
                    settings_match: false,
                    ..ready()
                }
            )
            .is_ok()
        );
        for context in [
            CommandContext {
                modal: true,
                ..ready()
            },
            CommandContext {
                closing: true,
                ..ready()
            },
            CommandContext {
                transfer_pending: true,
                ..ready()
            },
        ] {
            assert!(availability(command, &context).is_err());
        }
    }
    for command in [CommandId::SaveSql, CommandId::SaveSqlAs] {
        assert!(
            availability(
                command,
                &CommandContext {
                    sql_document: false,
                    ..ready()
                }
            )
            .is_err()
        );
        assert!(
            availability(
                command,
                &CommandContext {
                    document: None,
                    ..ready()
                }
            )
            .is_err()
        );
    }
}
