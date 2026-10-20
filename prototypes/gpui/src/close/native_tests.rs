//! Prepared production-graph cases. Execute only after final implementation.
use super::{CloseIntent, ClosePhase, DisconnectTarget, finalizers};
use crate::{Profile, ProfileId, backend, model, tables};
use crate::{changes_view, connections::ConnectionProfile, workspace_tests};
use gpui_kit::component::WindowExt;
use gpui_kit::test::TestWindowExt;
use gpui_kit::{AppContext, TestAppContext};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicU64, Ordering},
};

#[gpui_kit::test]
fn original_sql_helper_survives_success_cancel_error_and_same_id_replacement(
    cx: &mut TestAppContext,
) {
    let original = changes_view::tests::client();
    let replacement = changes_view::tests::client();
    for terminal in 0..3 {
        for tx in ["idle", "transaction", "failedTransaction"] {
            let (window, view) = workspace_tests::workspace(cx);
            cx.update_window(window, |_, window, cx| {
                view.update(cx, |this, cx| {
                    let mut settings = ConnectionProfile::new();
                    settings.readonly = false;
                    this.profiles.push(Profile::saved(settings.clone()));
                    this.tabs[0].profile = ProfileId::saved(&settings);
                    this.backend = Some(original.clone());
                    let tab = &mut this.tabs[0];
                    let source = tab.editor.read(cx).value().len();
                    let context = tab.begin(Some(settings), source).unwrap();
                    let context = tab
                        .attach(&context, "same-textual-session-id".into())
                        .unwrap();
                    tab.own_session(original.clone());
                    tab.operation_client = Some(original.clone());
                    tab.transaction = tx.into();
                    match terminal {
                        0 => this.finish_live(
                            &context,
                            backend::QueryOutcome {
                                result_sets: vec![],
                                duration_ms: 0.,
                                transaction_status: match tx {
                                    "transaction" => backend::TransactionStatus::Transaction,
                                    "failedTransaction" => {
                                        backend::TransactionStatus::FailedTransaction
                                    }
                                    _ => backend::TransactionStatus::Idle,
                                },
                                command_tag: "SELECT".into(),
                                row_count: 0,
                                truncated: false,
                                display_notice: String::new(),
                                export: None,
                            },
                            window,
                            cx,
                        ),
                        1 => this.finish_cancelled(&context, cx),
                        _ => {
                            let mut error =
                                backend::BackendError::transport("Synthetic known SQL failure.");
                            error.connected = true;
                            error.outcome_unknown = false;
                            this.fail_live(&context, error, window, cx);
                        }
                    }
                    assert!(!this.tabs[0].busy() && this.tabs[0].operation_client.is_none());
                    assert!(
                        this.tabs[0]
                            .session_client()
                            .unwrap()
                            .same_instance(&original)
                    );
                    this.backend = Some(replacement.clone());
                    let original_calls = original.request_attempts_for_test();
                    let replacement_calls = replacement.request_attempts_for_test();
                    let id = this.tabs[0].id;
                    // Explicit next SQL/control retains the original helper even
                    // though the replacement could reuse an identical session ID.
                    this.run_live(id, Some("ROLLBACK;".into()), None, window, cx);
                    assert!(
                        this.tabs[0]
                            .operation_client
                            .as_ref()
                            .unwrap()
                            .same_instance(&original)
                    );
                    let next = this.tabs[0].operation.clone().unwrap();
                    this.finish_cancelled(&next, cx); // Before the task can enqueue.
                    assert_eq!(original.request_attempts_for_test(), original_calls);
                    assert_eq!(replacement.request_attempts_for_test(), replacement_calls);
                    this.tabs[0].transaction = "transaction".into();
                    this.request_close(CloseIntent::Tab(id), window, cx);
                    let token = this.close_flow.as_ref().unwrap().token;
                    this.close_flow.as_mut().unwrap().phase = ClosePhase::Resolving(id);
                    assert!(
                        this.close_resolution_client(token, id)
                            .unwrap()
                            .same_instance(&original)
                    );
                    let target = DisconnectTarget {
                        document: Some((id, this.tabs[0].session_generation)),
                        profile: this.tabs[0].profile.clone(),
                        profile_generation: this.profile(&this.tabs[0].profile).generation,
                        session: this.tabs[0].session.clone().unwrap(),
                        settings: this.tabs[0].session_settings.clone(),
                        client: original.clone(),
                    };
                    assert!(this.disconnect_target_valid(&target));
                    let foreign = DisconnectTarget {
                        client: replacement.clone(),
                        ..target
                    };
                    assert!(!this.disconnect_target_valid(&foreign));
                    window.close_dialog(cx);
                    this.cancel_close(&token, window, cx);
                })
            })
            .unwrap();
        }
    }
}

#[gpui_kit::test]
fn dead_original_unknown_ack_closes_without_waiting_for_impossible_ack_or_touching_replacement(
    cx: &mut TestAppContext,
) {
    cx.update(|cx| cx.background_executor().allow_parking());
    let original = changes_view::tests::client();
    let replacement = changes_view::tests::client();
    let replacement_calls = replacement.request_attempts_for_test();
    let (window, view) = workspace_tests::workspace(cx);
    let id = cx
        .update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let settings = ConnectionProfile::new();
                this.profiles.push(Profile::saved(settings.clone()));
                let tab = &mut this.tabs[0];
                tab.profile = ProfileId::saved(&settings);
                tab.session = Some("dead-owned-session".into());
                tab.session_settings = Some(settings);
                tab.own_session(original.clone());
                tab.transaction = "transaction".into();
                let id = tab.id;
                original.fail_for_test();
                this.backend = Some(replacement.clone());
                this.request_close(CloseIntent::Tab(id), window, cx);
                assert_eq!(this.close_flow.as_ref().unwrap().phase, ClosePhase::Unknown);
                assert!(this.tabs[0].uncertain);
                id
            })
        })
        .unwrap();
    workspace_tests::await_workspace(cx, &view, |_| original.owned_process_exited());
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        window.click("acknowledge-unknown", cx);
    })
    .unwrap();
    workspace_tests::await_workspace(cx, &view, |this| !this.closing);
    cx.update(|cx| {
        let this = view.read(cx);
        assert!(!this.closing);
        assert!(this.tabs.iter().all(|t| t.id != id));
        assert_eq!(replacement.request_attempts_for_test(), replacement_calls);
    });
}

#[gpui_kit::test]
fn later_close_cancel_preserves_every_previously_reviewed_discard_and_inline_entity(
    cx: &mut TestAppContext,
) {
    let client = changes_view::tests::client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (first, one) = changes_view::tests::attach(this, &client, window, cx);
            let (second, two) = changes_view::tests::attach(this, &client, window, cx);
            for grid in [&one, &two] {
                grid.update(cx, |t, _| {
                    let d = t.delegate_mut().draft.as_mut().unwrap();
                    assert!(d.set(d.rows[0].id, 1, backend::CellValue::Null));
                });
            }
            this.sync_changes_locks(first, cx);
            this.sync_changes_locks(second, cx);
            this.request_close(CloseIntent::Window, window, cx);
            let token = this.close_flow.as_ref().unwrap().token;
            this.choose_close_discard(token, first, window, cx);
            assert_eq!(
                this.close_flow.as_ref().unwrap().phase,
                ClosePhase::Changes(second)
            );
            this.cancel_close_review(token, ClosePhase::Changes(second), window, cx);
            assert_eq!(one.read(cx).delegate().draft.as_ref().unwrap().pending(), 1);
            assert_eq!(two.read(cx).delegate().draft.as_ref().unwrap().pending(), 1);
            assert!(!this.closing);
        })
    })
    .unwrap();
}

#[gpui_kit::test]
fn finalization_awaits_latest_preference_revision_before_removing_original_document(
    cx: &mut TestAppContext,
) {
    let (window, view) = workspace_tests::workspace(cx);
    let revision = Arc::new(AtomicU64::new(1));
    let jobs = Arc::new(Mutex::new(Vec::new()));
    let (send, recv) = async_channel::unbounded::<()>();
    let id = cx
        .update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let id = this.tabs[0].id;
                let current = revision.clone();
                let prepare = revision.clone();
                let jobs = jobs.clone();
                assert!(this.register_close_finalizer(finalizers::Finalizer::new(
                    finalizers::FinalizerKind::TestPreference,
                    move |_, _| current.load(Ordering::SeqCst),
                    move |_, context, _| {
                        assert!(matches!(context.intent,CloseIntent::Tab(target) if target==id));
                        assert_eq!(context.documents, vec![id]);
                        let version = prepare.load(Ordering::SeqCst);
                        jobs.lock().unwrap().push((context.token, version));
                        let recv = recv.clone();
                        finalizers::FinalizationJob {
                            revision: version,
                            future: Box::pin(async move {
                                recv.recv()
                                    .await
                                    .map_err(|_| "Synthetic finalization failure.".to_owned())
                            }),
                        }
                    }
                )));
                this.request_close(CloseIntent::Tab(id), window, cx);
                id
            })
        })
        .unwrap();
    workspace_tests::await_workspace(cx, &view, |_| jobs.lock().unwrap().len() == 1);
    assert_eq!(jobs.lock().unwrap().len(), 1);
    revision.store(2, Ordering::SeqCst);
    send.try_send(()).unwrap();
    workspace_tests::await_workspace(cx, &view, |_| jobs.lock().unwrap().len() == 2);
    cx.update(|cx| assert!(view.read(cx).tabs.iter().any(|t| t.id == id)));
    assert_eq!(jobs.lock().unwrap().len(), 2);
    send.try_send(()).unwrap();
    workspace_tests::await_workspace(cx, &view, |this| this.tabs.iter().all(|tab| tab.id != id));
    cx.update(|cx| assert!(view.read(cx).tabs.iter().all(|t| t.id != id)));
    let jobs = jobs.lock().unwrap();
    assert_eq!(jobs[0].0, jobs[1].0);
    assert_eq!((jobs[0].1, jobs[1].1), (1, 2));
}

#[gpui_kit::test]
fn close_inline_apply_capture_projects_exact_input_without_touching_editor_or_draft(
    cx: &mut TestAppContext,
) {
    let client = changes_view::tests::client();
    let calls = client.request_attempts_for_test();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, grid) = changes_view::tests::attach(this, &client, window, cx);
            let capture = this.changes_capture(id, cx).unwrap();
            this.changes_action(capture, changes_view::Action::Edit(true), None, window, cx);
            let editor = grid
                .read(cx)
                .delegate()
                .inline
                .as_ref()
                .unwrap()
                .editor
                .clone();
            editor.update(cx, |e, cx| {
                e.set_value("exact inline NULL text\r\n", window, cx);
                e.set_selected_range(2..7, cx);
            });
            let capture = this.changes_capture(id, cx).unwrap();
            let revision = grid.read(cx).delegate().draft_revision();
            this.request_close(CloseIntent::Tab(id), window, cx);
            let token = this.close_flow.as_ref().unwrap().token;
            let batch = this.close_changes_batch(&capture, cx).unwrap();
            assert!(
                batch.request.changes[0].values[0].value
                    == backend::CellValue::Text("exact inline NULL text\r\n".into())
            );
            assert_eq!(
                grid.read(cx).delegate().draft.as_ref().unwrap().pending(),
                0
            );
            assert_eq!(grid.read(cx).delegate().draft_revision(), revision);
            this.cancel_close_review(token, ClosePhase::Changes(id), window, cx);
            let inline = grid.read(cx).delegate().inline.as_ref().unwrap();
            assert_eq!(inline.editor.entity_id(), editor.entity_id());
            assert_eq!(editor.read(cx).selected_range(), 2..7);
            assert_eq!(
                editor.read(cx).value().as_ref(),
                "exact inline NULL text\r\n"
            );
            assert_eq!(client.request_attempts_for_test(), calls);
        })
    })
    .unwrap();
}

#[gpui_kit::test]
fn unknown_apply_close_ack_with_dead_service_preserves_reapply_lock_on_retained_profile(
    cx: &mut TestAppContext,
) {
    let original = changes_view::tests::client();
    let replacement = changes_view::tests::client();
    let (window, view) = workspace_tests::workspace(cx);
    let (id, profile, grid) = cx
        .update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let (id, grid) = changes_view::tests::attach(this, &original, window, cx);
                grid.update(cx, |t, _| {
                    let d = t.delegate_mut().draft.as_mut().unwrap();
                    d.set(d.rows[0].id, 1, backend::CellValue::Null);
                });
                this.sync_changes_locks(id, cx);
                let tab = this.tabs.iter_mut().find(|t| t.id == id).unwrap();
                let table = tab
                    .catalog_document
                    .as_mut()
                    .unwrap()
                    .table
                    .as_mut()
                    .unwrap();
                table.recovery = tables::ChangesRecovery::Unknown {
                    inspection: None,
                    inspected: false,
                };
                table.locks.outcome_unknown = true;
                let profile = tab.profile.clone();
                let index = this.profile_index(&profile).unwrap();
                this.profiles[index].session_client = Some(original.clone());
                original.fail_for_test();
                this.backend = Some(replacement.clone());
                this.request_close(CloseIntent::Profile(profile.clone()), window, cx);
                assert_eq!(
                    this.close_flow.as_ref().unwrap().phase,
                    ClosePhase::UnknownChanges(id)
                );
                (id, profile, grid)
            })
        })
        .unwrap();
    workspace_tests::await_workspace(cx, &view, |_| original.owned_process_exited());
    cx.update_window(window, |_, window, cx| {
        window.render_frame(cx);
        window.click("discard-unknown-changes-close", cx);
    })
    .unwrap();
    workspace_tests::await_workspace(cx, &view, |this| !this.closing);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            assert!(!this.closing);
            assert!(this.profile(&profile).session.is_none());
            assert!(this.unknown_changes(id).is_some());
            assert!(this.changes_recovery_locked(id));
            assert_eq!(
                grid.read(cx).delegate().draft.as_ref().unwrap().pending(),
                0
            );
            assert!(this.capture_table(id, tables::Action::Refresh, cx).is_err());
            let capture = this.changes_capture(id, cx).unwrap();
            this.start_changes_apply(capture, window, cx);
            assert!(this.changes_preview.is_none());
        })
    })
    .unwrap();
}

#[gpui_kit::test]
fn tab_disconnect_refusal_preserves_other_profile_transaction_on_same_owned_helper(
    cx: &mut TestAppContext,
) {
    let client = changes_view::tests::client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update(|cx| cx.background_executor().allow_parking());
    let sibling = cx
        .update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                this.backend = Some(client.clone());
                for index in 0..2 {
                    let settings = ConnectionProfile::new();
                    this.profiles.push(Profile::saved(settings.clone()));
                    let id = if index == 0 {
                        this.tabs[0].profile = ProfileId::saved(&settings);
                        this.tabs[0].id
                    } else {
                        this.add_document_for_profile(
                            "Other profile".into(),
                            "SELECT 2;".into(),
                            ProfileId::saved(&settings),
                            model::DocumentKind::Sql,
                            window,
                            cx,
                        )
                        .unwrap()
                    };
                    let tab = this.tabs.iter_mut().find(|t| t.id == id).unwrap();
                    tab.session = Some(format!("synthetic-owned-session-{index}"));
                    tab.session_settings = Some(settings);
                    tab.own_session(client.clone());
                    if index == 1 {
                        tab.transaction = "transaction".into();
                    }
                }
                let sibling = this.tabs[1].id;
                this.request_close(CloseIntent::Tab(this.tabs[0].id), window, cx);
                assert_eq!(
                    this.close_flow.as_ref().unwrap().phase,
                    ClosePhase::Disconnecting
                );
                sibling
            })
        })
        .unwrap();
    workspace_tests::await_workspace(cx, &view, |this| !this.closing);
    cx.update(|cx| {
        let this = view.read(cx);
        let tab = this.tabs.iter().find(|t| t.id == sibling).unwrap();
        assert_eq!(tab.transaction, "transaction");
        assert!(tab.session.is_some());
        assert!(tab.session_client().unwrap().same_instance(&client));
        assert!(client.is_alive());
    });
}
