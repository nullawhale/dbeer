//! Prepared headless chooser/staleness/terminal ownership cases; not native evidence.
use super::{
    CloseIntent, CommandId, CommandOrigin, ConnectionProfile, Context, DocumentId, Window,
    Workspace,
};
use crate::{model, workspace};
use gpui_kit::component::WindowExt;
use gpui_kit::{AppContext, TestAppContext};
fn saved(this: &mut Workspace, window: &mut Window, cx: &mut Context<Workspace>) -> DocumentId {
    let mut settings = ConnectionProfile::new();
    settings.environment = "production".into();
    settings.readonly = false;
    let profile = workspace::Profile::saved(settings);
    let profile_id = profile.id.clone();
    this.profiles.push(profile);
    this.add_document_for_profile(
        "Owned SQL".into(),
        "SELECT 1;".into(),
        profile_id,
        model::DocumentKind::Sql,
        window,
        cx,
    )
    .unwrap()
}
#[gpui_kit::test]
fn choosing_cancel_stale_source_and_profile_never_start_helper_or_change_sql_file(
    cx: &mut TestAppContext,
) {
    for boundary in 0..3 {
        let (window, view) = crate::workspace_tests::workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let id = saved(this, window, cx);
                this.command(
                    CommandId::RunToJson,
                    CommandOrigin::Button,
                    None,
                    window,
                    cx,
                );
                let token = this.run_file.as_ref().unwrap().token;
                let editor = this
                    .tabs
                    .iter()
                    .find(|t| t.id == id)
                    .unwrap()
                    .editor
                    .clone();
                let entity = editor.entity_id();
                this.request_close(CloseIntent::Tab(id), window, cx);
                assert!(this.closing && this.close_flow.is_some());
                let close = this.close_flow.as_ref().unwrap().token;
                this.cancel_close(&close, window, cx);
                if boundary == 1 {
                    editor.update(cx, |e, cx| e.set_value("SELECT 2;", window, cx));
                    assert!(!this.run_file_valid(token, cx))
                }
                if boundary == 2 {
                    let profile = this
                        .tabs
                        .iter()
                        .find(|t| t.id == id)
                        .unwrap()
                        .profile
                        .clone();
                    let index = this.profile_index(&profile).unwrap();
                    this.profiles[index].generation += 1;
                    assert!(!this.run_file_valid(token, cx))
                }
                this.cancel_run_file(token, cx);
                window.close_dialog(cx);
                assert!(this.run_file.is_none());
                assert!(this.backend.is_none());
                let tab = this.tabs.iter().find(|t| t.id == id).unwrap();
                assert_eq!(tab.editor.entity_id(), entity);
                assert!(
                    tab.file.binding.is_none() && tab.session.is_none() && tab.operation.is_none()
                );
            })
        })
        .unwrap();
    }
}
#[gpui_kit::test]
fn picker_callback_keeps_original_document_and_token_and_stale_source_refuses_connect(
    cx: &mut TestAppContext,
) {
    let (window, view) = crate::workspace_tests::workspace(cx);
    let id = cx
        .update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let id = saved(this, window, cx);
                let capture = this
                    .capture_command(CommandId::RunToCsv, CommandOrigin::Menu, None, window, cx)
                    .unwrap();
                this.add_sql_tab("Other".into(), "SELECT 2;".into(), window, cx);
                this.dispatch_command(capture, window, cx);
                let token = this.run_file.as_ref().unwrap().token;
                this.choose_run_file(token, "\\N".into(), window, cx);
                assert!(
                    this.run_file
                        .as_ref()
                        .unwrap()
                        .capture
                        .document
                        .as_ref()
                        .unwrap()
                        .id
                        == id
                );
                id
            })
        })
        .unwrap();
    assert!(cx.did_prompt_for_new_path());
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let editor = this
                .tabs
                .iter()
                .find(|t| t.id == id)
                .unwrap()
                .editor
                .clone();
            editor.update(cx, |e, cx| e.set_value("SELECT 3;", window, cx))
        })
    })
    .unwrap();
    cx.simulate_new_path_selection(|_| {
        Some(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../build/gpui/never-execute.json"),
        )
    });
    cx.run_until_parked();
    cx.update(|cx| {
        let this = view.read(cx);
        assert!(this.backend.is_none() && this.run_file.is_none());
        assert!(this.tabs.iter().all(|t| t.session.is_none() && !t.busy()))
    });
}

fn submitted(
    this: &mut Workspace,
    window: &mut Window,
    cx: &mut Context<Workspace>,
) -> (
    DocumentId,
    crate::OperationContext,
    crate::backend::ExportRequest,
) {
    let id = saved(this, window, cx);
    this.command(
        CommandId::RunToJson,
        CommandOrigin::Button,
        None,
        window,
        cx,
    );
    window.close_dialog(cx);
    let fragment = this
        .run_file
        .as_ref()
        .unwrap()
        .capture
        .fragment
        .as_ref()
        .unwrap()
        .clone();
    let client = crate::changes_view::tests::client();
    this.backend = Some(client.clone());
    let tab = this.tabs.iter_mut().find(|t| t.id == id).unwrap();
    let settings = this
        .profiles
        .iter()
        .find(|p| p.id == tab.profile)
        .unwrap()
        .config
        .clone();
    tab.operation_client = Some(client);
    tab.session = Some("original-physical-sql".into());
    tab.session_settings = settings.clone();
    tab.transaction = "transaction".into();
    let context = tab.begin(settings, fragment.source().text().len()).unwrap();
    tab.prepare_batch(fragment);
    assert!(tab.started(&context, "original-query".into()));
    let export = crate::backend::ExportRequest {
        path: std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/full-owned.json")
            .to_str()
            .unwrap()
            .into(),
        format: crate::backend::ExportFormat::Json,
        null_marker: None,
        destination: None,
    };
    let flow = this.run_file.as_mut().unwrap();
    flow.phase = super::Phase::Executing;
    flow.operation = Some(context.clone());
    flow.export = Some(export.clone());
    (id, context, export)
}
#[gpui_kit::test]
fn late_stop_and_stale_source_terminal_reconcile_original_tab_and_one_history_entry(
    cx: &mut TestAppContext,
) {
    let (window, view) = crate::workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, context, export) = submitted(this, window, cx);
            let editor = this
                .tabs
                .iter()
                .find(|t| t.id == id)
                .unwrap()
                .editor
                .clone();
            let entity = editor.entity_id();
            editor.update(cx, |e, cx| e.set_value("SELECT 2;", window, cx));
            this.add_sql_tab("Other".into(), "SELECT 99;".into(), window, cx);
            let original_client = this
                .tabs
                .iter()
                .find(|t| t.id == id)
                .unwrap()
                .operation_client
                .clone()
                .unwrap();
            let replacement = crate::changes_view::tests::client();
            this.backend = Some(replacement.clone());
            let active = this.tabs[this.active].id;
            this.request_close(CloseIntent::Tab(id), window, cx);
            assert!(this.closing && this.close_flow.is_some());
            let close = this.close_flow.as_ref().unwrap().token;
            this.cancel_close(&close, window, cx);
            window.close_dialog(cx);
            this.stop_document(id, cx);
            assert!(this.tabs.iter().find(|t| t.id == id).unwrap().busy());
            assert!(this.run_file.is_some());
            let outcome = crate::backend::QueryOutcome {
                result_sets: vec![],
                duration_ms: 1.,
                transaction_status: crate::backend::TransactionStatus::Transaction,
                command_tag: "EXPORT".into(),
                row_count: 9001,
                truncated: true,
                display_notice: String::new(),
                export: Some(crate::backend::ExportOutcome {
                    path: export.path,
                    format: export.format,
                    row_count: 9001,
                }),
            };
            this.finish_live(&context, outcome.clone(), window, cx);
            this.finish_live(&context, outcome, window, cx);
            let tab = this.tabs.iter().find(|t| t.id == id).unwrap();
            assert!(!tab.busy() && !tab.uncertain && tab.transaction == "transaction");
            assert_eq!(tab.editor.entity_id(), entity);
            assert!(tab.file.binding.is_none());
            assert!(
                tab.run_file_recovery.as_ref().unwrap().publication
                    == crate::run_to_file::Publication::Published
            );
            assert!(
                tab.run_file_recovery
                    .as_ref()
                    .unwrap()
                    .client
                    .as_ref()
                    .unwrap()
                    .same_instance(&original_client)
            );
            assert!(
                !tab.run_file_recovery
                    .as_ref()
                    .unwrap()
                    .client
                    .as_ref()
                    .unwrap()
                    .same_instance(&replacement)
            );
            assert!(tab.status.contains("9001"));
            assert!(this.run_file.is_none());
            assert_eq!(this.tabs[this.active].id, active);
            assert_eq!(this.restoration.snapshot.history.len(), 1);
            assert!(this.restoration.snapshot.history[0].sql == "SELECT 1");
        })
    })
    .unwrap();
}
#[gpui_kit::test]
fn known_sql_publication_failure_and_lost_terminal_keep_distinct_original_recovery(
    cx: &mut TestAppContext,
) {
    for unknown in [false, true] {
        let (window, view) = crate::workspace_tests::workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let (id, context, _) = submitted(this, window, cx);
                let mut error = crate::backend::BackendError::transport("Fixed terminal fixture.");
                error.category = if unknown { "connection" } else { "export" }.into();
                error.connected = !unknown;
                error.outcome_unknown = unknown;
                error.sql_completed = !unknown;
                error.export_publication =
                    (!unknown).then_some(crate::backend::ExportPublication::NotPublished);
                error.transaction_status =
                    (!unknown).then_some(crate::backend::TransactionStatus::Transaction);
                this.fail_live(&context, error, window, cx);
                let tab = this.tabs.iter().find(|t| t.id == id).unwrap();
                assert!(!tab.busy());
                assert_eq!(tab.uncertain, unknown);
                let recovery = tab.run_file_recovery.as_ref().unwrap();
                assert_eq!(recovery.sql_completed, !unknown);
                assert_eq!(recovery.outcome_unknown, unknown);
                assert!(recovery.query.as_deref() == Some("original-query"));
                assert!(recovery.session.as_deref() == Some("original-physical-sql"));
                assert!(recovery.operation == context.operation);
                assert_eq!(this.restoration.snapshot.history.len(), 1);
                assert!(this.run_file.is_none());
            })
        })
        .unwrap()
    }
}

#[gpui_kit::test]
fn stop_while_native_picker_is_pending_keeps_its_original_future_until_callback(
    cx: &mut TestAppContext,
) {
    let (window, view) = crate::workspace_tests::workspace(cx);
    let token = cx
        .update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let id = saved(this, window, cx);
                this.command(
                    CommandId::RunToJson,
                    CommandOrigin::Button,
                    None,
                    window,
                    cx,
                );
                let token = this.run_file.as_ref().unwrap().token;
                this.choose_run_file(token, String::new(), window, cx);
                this.cancel_run_file(token, cx);
                assert!(
                    this.run_file
                        .as_ref()
                        .is_some_and(|f| f.token == token && f.cancelled)
                );
                assert!(this.run_file_task.is_some());
                assert!(this.tabs.iter().any(|t| t.id == id));
                token
            })
        })
        .unwrap();
    cx.simulate_new_path_selection(|_| None);
    cx.run_until_parked();
    cx.update(|cx| {
        let this = view.read(cx);
        assert!(this.run_file.as_ref().is_none_or(|f| f.token != token));
        assert!(this.run_file_task.is_none());
        assert!(this.backend.is_none());
    });
}
