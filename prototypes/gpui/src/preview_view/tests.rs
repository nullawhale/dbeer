//! Prepared production-callback cases; execute only at final integration.
use crate::changes_view::tests::{attach, client};
use crate::{
    CloseIntent, CommandId, CommandOrigin, backend, changes_view, tables, workspace_tests,
};
use gpui_kit::component::WindowExt;
use gpui_kit::test::TestWindowExt;
use gpui_kit::{AppContext, TestAppContext};
use std::sync::Arc;
#[gpui_kit::test]
fn every_async_boundary_rejects_mutable_context_keeps_original_drafts_and_no_requests(
    cx: &mut TestAppContext,
) {
    let original = client();
    let replacement = client();
    let (window, view) = workspace_tests::workspace(cx);
    for boundary in 0..7 {
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let (id, grid) = attach(this, &original, window, cx);
                grid.update(cx, |t, cx| {
                    let d = t.delegate_mut().draft.as_mut().unwrap();
                    let row = d.rows[0].id;
                    assert!(d.set(
                        row,
                        1,
                        backend::CellValue::Text("immutable pending value".into())
                    ));
                    cx.notify();
                });
                this.sync_changes_locks(id, cx);
                let capture = this.changes_capture(id, cx).unwrap();
                let batch = Arc::new(this.changes_batch(&capture, cx).unwrap());
                let exact = batch.request.clone();
                let calls = original.request_attempts_for_test();
                let (token, _) = this.reserve_changes_preview(batch.clone(), cx);
                assert!(this.preview_valid(token, cx));
                assert!(this.capture_table(id, tables::Action::Next, cx).is_err());
                this.changes_action(
                    capture.clone(),
                    changes_view::Action::Discard,
                    None,
                    window,
                    cx,
                );
                assert!(grid.read(cx).delegate().draft.as_ref().unwrap().pending() == 1);
                let profile = this.profile_index(&capture.owner.target.profile).unwrap();
                match boundary {
                    0 => this.profiles[profile].config.as_mut().unwrap().readonly = true, // credential prompt
                    1 => {
                        this.profiles[profile].config.as_mut().unwrap().host =
                            "changed-endpoint".into()
                    } // connect
                    2 => this.profiles[profile].session = Some("reconnected-service".into()), // preview
                    3 => grid.update(cx, |t, _| t.delegate_mut().draft.as_mut().unwrap().touch()), // assessment
                    4 => grid.update(cx, |t, _| t.delegate_mut().metadata[1].editable = false), // review
                    5 => this.backend = Some(replacement.clone()), // original helper replacement
                    _ => this.profiles[profile].generation += 1,
                }
                assert!(!this.preview_valid(token, cx));
                assert!(!this.changes_batch_valid(&batch, cx));
                assert!(batch.request == exact);
                this.stop_document(id, cx);
                assert!(this.changes_preview.as_ref().unwrap().cancel.cancelled());
                this.release_changes_preview(token, None, cx);
                assert!(this.changes_preview.is_none());
                assert!(grid.read(cx).delegate().draft.as_ref().unwrap().pending() == 1);
                assert!(original.request_attempts_for_test() == calls);
            })
        })
        .unwrap();
    }
}
#[gpui_kit::test]
fn close_and_old_stop_captures_cannot_remove_or_cancel_a_different_preview(
    cx: &mut TestAppContext,
) {
    let client = client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, grid) = attach(this, &client, window, cx);
            grid.update(cx, |t, _| {
                let d = t.delegate_mut().draft.as_mut().unwrap();
                let row = d.rows[0].id;
                d.set(row, 1, backend::CellValue::Null);
            });
            this.sync_changes_locks(id, cx);
            this.active = this.tabs.iter().position(|t| t.id == id).unwrap();
            let batch = Arc::new(
                this.changes_batch(&this.changes_capture(id, cx).unwrap(), cx)
                    .unwrap(),
            );
            let (first, _) = this.reserve_changes_preview(batch.clone(), cx);
            let stop = this
                .capture_command(CommandId::Stop, CommandOrigin::Menu, None, window, cx)
                .unwrap();
            this.request_close(CloseIntent::Tab(id), window, cx);
            assert!(this.closing && this.close_flow.is_some());
            let close = this.close_flow.as_ref().unwrap().token;
            this.cancel_close(&close, window, cx);
            assert!(this.tabs.iter().any(|t| t.id == id));
            window.close_dialog(cx);
            this.release_changes_preview(first, None, cx);
            let (second, _) = this.reserve_changes_preview(batch, cx);
            assert!(first != second);
            assert!(!this.capture_valid(&stop, cx));
            this.dispatch_command(stop, window, cx);
            assert!(!this.changes_preview.as_ref().unwrap().cancel.cancelled());
            this.finish_preview_review(second, window, cx);
            assert!(this.changes_preview.is_none());
            assert!(grid.read(cx).delegate().draft.as_ref().unwrap().pending() == 1);
            assert!(this.tabs[0].session.is_none());
        })
    })
    .unwrap();
    cx.update_window(window, |_, window, cx| window.press("escape", cx))
        .unwrap();
}
fn stage(
    this: &mut crate::Workspace,
    client: &crate::BackendClient,
    window: &mut gpui_kit::Window,
    cx: &mut gpui_kit::Context<crate::Workspace>,
) -> (crate::model::DocumentId, Arc<changes_view::ChangesBatch>) {
    let (id, grid) = attach(this, client, window, cx);
    grid.update(cx, |t, _| {
        let draft = t.delegate_mut().draft.as_mut().unwrap();
        let row = draft.rows[0].id;
        assert!(draft.set(
            row,
            1,
            backend::CellValue::Text("original immutable pending value".into())
        ));
    });
    this.sync_changes_locks(id, cx);
    let batch = Arc::new(
        this.changes_batch(&this.changes_capture(id, cx).unwrap(), cx)
            .unwrap(),
    );
    (id, batch)
}
fn committed() -> backend::QueryOutcome {
    backend::QueryOutcome {
        result_sets: vec![],
        duration_ms: 0.0,
        transaction_status: backend::TransactionStatus::Idle,
        command_tag: "APPLY 1".into(),
        row_count: 1,
        truncated: false,
        display_notice: String::new(),
        export: None,
    }
}
#[gpui_kit::test]
fn authoritative_commit_after_stop_or_stale_context_requires_reload_and_cannot_reapply(
    cx: &mut TestAppContext,
) {
    let client = client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, batch) = stage(this, &client, window, cx);
            let calls = client.request_attempts_for_test();
            let (token, cancel) =
                this.reserve_changes_flow(batch.clone(), crate::preview::Purpose::Apply, cx);
            this.apply_lock(id, true);
            // A late context change after enqueue does not erase COMMIT proof.
            let p = this
                .profile_index(&batch.capture.owner.target.profile)
                .unwrap();
            this.profiles[p].generation += 1;
            cancel.cancel();
            this.changes_preview.as_mut().unwrap().completion =
                Some(super::Completion::Apply(Ok(committed())));
            this.complete_changes_flow(token, window, cx);
            assert!(this.unknown_changes(id).is_none());
            assert!(this.changes_recovery_locked(id));
            assert!(
                batch
                    .capture
                    .grid
                    .read(cx)
                    .delegate()
                    .draft
                    .as_ref()
                    .unwrap()
                    .pending()
                    == 0
            );
            assert!(
                batch
                    .capture
                    .grid
                    .read(cx)
                    .delegate()
                    .edit_error
                    .as_ref()
                    .unwrap()
                    .contains("committed")
            );
            assert!(client.request_attempts_for_test() == calls); // no stale automatic reload
            let table = this
                .tabs
                .iter_mut()
                .find(|t| t.id == id)
                .unwrap()
                .catalog_document
                .as_mut()
                .unwrap()
                .table
                .as_mut()
                .unwrap();
            let request = table.begin(table.navigation.clone()).unwrap();
            table.fail(&request); // failed reload is distinct from unknown COMMIT
            assert!(table.recovery == tables::ChangesRecovery::ReloadRequired);
            this.start_changes_apply(batch.capture.clone(), window, cx);
            assert!(this.changes_preview.is_none());
            assert!(client.request_attempts_for_test() == calls);
            let table = this
                .tabs
                .iter_mut()
                .find(|t| t.id == id)
                .unwrap()
                .catalog_document
                .as_mut()
                .unwrap()
                .table
                .as_mut()
                .unwrap();
            let request = table.begin(table.navigation.clone()).unwrap();
            assert!(table.commit(&request, 2));
            assert!(table.recovery == tables::ChangesRecovery::Ready);
            assert!(this.tabs[0].session.is_none());
        });
    })
    .unwrap();
}
#[gpui_kit::test]
fn unknown_survives_disconnect_and_refuses_refresh_plain_discard_close_or_reapply(
    cx: &mut TestAppContext,
) {
    let client = client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, batch) = stage(this, &client, window, cx);
            let original = batch.capture.grid.read(cx).delegate().original.clone();
            let calls = client.request_attempts_for_test();
            let (token, _) =
                this.reserve_changes_flow(batch.clone(), crate::preview::Purpose::Apply, cx);
            let mut error =
                backend::BackendError::transport("Fixture lost COMMIT acknowledgement.");
            error.outcome_unknown = true;
            this.changes_preview.as_mut().unwrap().completion =
                Some(super::Completion::Apply(Err(error)));
            this.complete_changes_flow(token, window, cx);
            assert!(this.unknown_changes(id) == Some(false));
            this.backend = None; // disconnected Apply/helper cannot prove rollback
            assert!(this.unknown_changes(id) == Some(false));
            this.changes_action(
                batch.capture.clone(),
                changes_view::Action::Discard,
                None,
                window,
                cx,
            );
            this.discard_unknown_changes(id, window, cx);
            assert!(
                batch
                    .capture
                    .grid
                    .read(cx)
                    .delegate()
                    .draft
                    .as_ref()
                    .unwrap()
                    .pending()
                    == 1
            );
            assert!(batch.capture.grid.read(cx).delegate().original == original);
            assert!(this.capture_table(id, tables::Action::Refresh, cx).is_err());
            this.start_changes_apply(batch.capture.clone(), window, cx);
            assert!(this.changes_preview.is_none());
            this.request_close(CloseIntent::Tab(id), window, cx);
            assert!(this.close_flow.is_some() && this.tabs.iter().any(|t| t.id == id));
            let close = this.close_flow.as_ref().unwrap().token;
            window.close_dialog(cx);
            this.cancel_close(&close, window, cx);
            // An explicit successful inspection is necessary, then explicit
            // discard still leaves ReloadRequired while the service is absent.
            this.backend = Some(client.clone());
            let target = batch.capture.owner.target.clone();
            let inspection = this.new_catalog_document(target, true, window, cx).unwrap();
            let table = this
                .tabs
                .iter_mut()
                .find(|t| t.id == id)
                .unwrap()
                .catalog_document
                .as_mut()
                .unwrap()
                .table
                .as_mut()
                .unwrap();
            table.recovery = tables::ChangesRecovery::Unknown {
                inspection: Some(inspection),
                inspected: false,
            };
            this.complete_changes_inspection(inspection);
            assert!(this.unknown_changes(id) == Some(false)); // opening an empty tab is insufficient
            let tab = this.tabs.iter_mut().find(|t| t.id == inspection).unwrap();
            let doc = tab.catalog_document.as_mut().unwrap();
            doc.loading = false;
            doc.table.as_mut().unwrap().snapshot = 11;
            tab.result_sets = vec![original.clone()]; // simulate validated publication
            this.complete_changes_inspection(inspection);
            assert!(this.unknown_changes(id) == Some(true));
            this.backend = None;
            this.discard_unknown_changes(id, window, cx);
            assert!(this.unknown_changes(id) == Some(false)); // stale service proof refuses discard
            assert!(
                batch
                    .capture
                    .grid
                    .read(cx)
                    .delegate()
                    .draft
                    .as_ref()
                    .unwrap()
                    .pending()
                    == 1
            );
            this.backend = Some(client.clone());
            assert!(this.unknown_changes(id) == Some(true));
            let p = this
                .profile_index(&batch.capture.owner.target.profile)
                .unwrap();
            this.profiles[p].task =
                Some(cx.spawn(async |_, _| smol::future::pending::<()>().await));
            this.discard_unknown_changes(id, window, cx);
            assert!(this.unknown_changes(id).is_none());
            assert!(this.changes_recovery_locked(id));
            assert!(
                batch
                    .capture
                    .grid
                    .read(cx)
                    .delegate()
                    .draft
                    .as_ref()
                    .unwrap()
                    .pending()
                    == 0
            );
            assert!(client.request_attempts_for_test() == calls);
        });
    })
    .unwrap();
}
#[gpui_kit::test]
fn apply_review_stop_is_sticky_before_submission_and_stale_stop_cannot_cancel_later_flow(
    cx: &mut TestAppContext,
) {
    let client = client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, batch) = stage(this, &client, window, cx);
            this.active = this.tabs.iter().position(|t| t.id == id).unwrap();
            let calls = client.request_attempts_for_test();
            let (token, cancel) =
                this.reserve_changes_flow(batch.clone(), crate::preview::Purpose::Apply, cx);
            let stop = this
                .capture_command(CommandId::Stop, CommandOrigin::Menu, None, window, cx)
                .unwrap();
            let (sender, receiver) = async_channel::bounded(1);
            let flow = this.changes_preview.as_mut().unwrap();
            flow.phase = super::Phase::Reviewing;
            flow.review = Some(sender);
            assert!(this.stop_changes_preview(id, cx));
            assert!(cancel.cancelled());
            assert!(!receiver.try_recv().unwrap());
            this.finish_apply_review(token, true, window, cx);
            assert!(!this.preview_valid(token, cx));
            this.release_changes_preview(token, None, cx);
            let (_, latest_cancel) =
                this.reserve_changes_flow(batch, crate::preview::Purpose::Apply, cx);
            this.dispatch_command(stop, window, cx);
            assert!(!latest_cancel.cancelled());
            assert!(client.request_attempts_for_test() == calls);
        });
    })
    .unwrap();
}
#[gpui_kit::test]
fn loaded_export_capture_never_contains_projected_drafts_or_unreloaded_apply_rows(
    cx: &mut TestAppContext,
) {
    let client = client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, grid) = attach(this, &client, window, cx);
            let loaded = grid.read(cx).delegate().original.clone();
            let calls = client.request_attempts_for_test();
            // Confirmed loaded snapshots remain usable without a connection.
            this.backend = None;
            assert!(this.confirmed_loaded_table_snapshot(id, cx).unwrap() == loaded);
            grid.update(cx, |t, _| {
                let g = t.delegate_mut();
                let draft = g.draft.as_mut().unwrap();
                let row = draft.rows[0].id;
                draft.set(
                    row,
                    1,
                    backend::CellValue::Text("never export this projection".into()),
                );
                g.project_draft();
            });
            this.sync_changes_locks(id, cx);
            assert!(this.confirmed_loaded_table_snapshot(id, cx).is_none());
            let capture = this.changes_capture(id, cx).unwrap();
            this.changes_action(capture, changes_view::Action::Discard, None, window, cx);
            assert!(this.confirmed_loaded_table_snapshot(id, cx).unwrap() == loaded);
            let table = this
                .tabs
                .iter_mut()
                .find(|t| t.id == id)
                .unwrap()
                .catalog_document
                .as_mut()
                .unwrap()
                .table
                .as_mut()
                .unwrap();
            table.recovery = tables::ChangesRecovery::ReloadRequired;
            assert!(this.confirmed_loaded_table_snapshot(id, cx).is_none());
            let table = this
                .tabs
                .iter_mut()
                .find(|t| t.id == id)
                .unwrap()
                .catalog_document
                .as_mut()
                .unwrap()
                .table
                .as_mut()
                .unwrap();
            let request = table.begin(table.navigation.clone()).unwrap();
            assert!(this.confirmed_loaded_table_snapshot(id, cx).is_none());
            let table = this
                .tabs
                .iter_mut()
                .find(|t| t.id == id)
                .unwrap()
                .catalog_document
                .as_mut()
                .unwrap()
                .table
                .as_mut()
                .unwrap();
            table.fail(&request);
            assert!(this.confirmed_loaded_table_snapshot(id, cx).is_none());
            assert!(client.request_attempts_for_test() == calls);
        });
    })
    .unwrap();
}

#[gpui_kit::test]
fn close_apply_cleanup_failure_releases_common_review_but_keeps_terminal_and_drafts(
    cx: &mut TestAppContext,
) {
    let client = client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, batch) = stage(this, &client, window, cx);
            this.request_close(CloseIntent::Tab(id), window, cx);
            let close = this.close_flow.as_ref().unwrap().token;
            window.close_dialog(cx);
            this.close_flow.as_mut().unwrap().phase = crate::close::ClosePhase::ApplyingChanges(id);
            let (token, _) =
                this.reserve_changes_flow(batch.clone(), crate::preview::Purpose::Apply, cx);
            let f = this.changes_preview.as_mut().unwrap();
            f.close = Some(close);
            f.completion = Some(super::Completion::Apply(Ok(committed())));
            this.retain_changes_cleanup_failure(token, window, cx);
            assert!(!this.closing && this.close_flow.is_none());
            let f = this.changes_preview.as_ref().unwrap();
            assert!(f.close.is_none() && f.phase == super::Phase::CleanupFailed);
            assert!(matches!(
                f.completion,
                Some(super::Completion::Apply(Ok(_)))
            ));
            assert_eq!(
                batch
                    .capture
                    .grid
                    .read(cx)
                    .delegate()
                    .draft
                    .as_ref()
                    .unwrap()
                    .pending(),
                1
            );
            assert!(this.preview_blocks(id));
        })
    })
    .unwrap();
}
