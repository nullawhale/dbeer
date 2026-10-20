//! Prepared headless command/dialog callbacks; no tests run during implementation.
use super::{
    Arc, CloseIntent, CommandId, CommandOrigin, Context, DocumentId, ExportError, ExportRequest,
    Format, PathBuf, Phase, PreparedExport, Window, Workspace, backend, exports, files, tables,
};
use crate::{
    changes_view::tests::{attach, client},
    workspace_tests,
};
use gpui_kit::component::WindowExt;
use gpui_kit::{AppContext, TestAppContext};
use std::fs;
fn fixture() -> PathBuf {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../build/gpui/export-ui-tests")
        .join(uuid::Uuid::new_v4().to_string());
    fs::create_dir_all(&root).unwrap();
    fs::canonicalize(root).unwrap()
}
fn loaded(this: &mut Workspace, window: &mut Window, cx: &mut Context<Workspace>) -> DocumentId {
    let id = this.tabs[this.active].id;
    this.tabs[this.active].result_sets = vec![backend::ResultSet {
        columns: vec![backend::Column {
            index: 0,
            name: "x".into(),
            engine: "postgresql".into(),
            native_type: "text".into(),
            type_oid: 25,
            encoding: None,
        }],
        rows: vec![
            vec![Some("first".into())],
            vec![Some("last\r\n\u{1f642}".into())],
        ],
        command_tag: "SELECT 1000".into(),
        row_count: 1000,
        displayed_row_count: 2,
        truncated: true,
        ..Default::default()
    }];
    this.render_live_result(id, window, cx);
    id
}
#[gpui_kit::test]
fn command_menu_button_capture_exports_physical_original_rows_across_tab_filter_selection_switch(
    cx: &mut TestAppContext,
) {
    let root = fixture();
    let path = root.join("loaded.json");
    let (window, view) = workspace_tests::workspace(cx);
    let first = cx
        .update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let first = loaded(this, window, cx);
                let capture = this
                    .capture_command(
                        CommandId::ExportResultsJson,
                        CommandOrigin::Menu,
                        None,
                        window,
                        cx,
                    )
                    .unwrap();
                let grid = this.tabs[0].grid.clone().unwrap();
                grid.update(cx, |t, _| t.delegate_mut().set_filter("last"));
                this.add_sql_tab("Other".into(), "SELECT 2".into(), window, cx);
                this.dispatch_command(capture, window, cx);
                let token = this.export_request.as_ref().unwrap().token;
                assert!(this.loaded_export_valid(token, cx));
                assert!(this.choose_loaded_export(token, "", window, cx).is_ok());
                first
            })
        })
        .unwrap();
    assert!(cx.did_prompt_for_new_path());
    cx.simulate_new_path_selection(|_| Some(path.clone()));
    cx.run_until_parked();
    let json: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(json["resultSets"][0]["rows"].as_array().unwrap().len(), 2);
    assert_eq!(json["resultSets"][0]["rows"][0][0], "first");
    assert_eq!(json["resultSets"][0]["metadata"]["truncated"], true);
    cx.update(|cx| {
        let this = view.read(cx);
        assert!(this.backend.is_none());
        assert!(
            this.tabs
                .iter()
                .all(|t| t.session.is_none() && t.operation.is_none() && t.file.binding.is_none())
        );
        assert!(
            this.tabs
                .iter()
                .find(|t| t.id == first)
                .unwrap()
                .file
                .saved_source
                .is_none()
        );
        assert!(this.export_request.is_none());
    });
    fs::remove_dir_all(root).unwrap();
}
#[gpui_kit::test]
fn cancellation_close_guard_colliding_marker_and_stale_origin_keep_file_binding_and_no_queries(
    cx: &mut TestAppContext,
) {
    let root = fixture();
    let path = root.join("original.csv");
    fs::write(&path, "original").unwrap();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let id = loaded(this, window, cx);
            this.command(
                CommandId::ExportResultsCsv,
                CommandOrigin::Button,
                None,
                window,
                cx,
            );
            let token = this.export_request.as_ref().unwrap().token;
            assert_eq!(
                this.choose_loaded_export(token, "first", window, cx),
                Err(ExportError::NullCollision)
            );
            assert!(this.export_request.is_some());
            assert!(
                this.choose_loaded_export(token, "__NULL__", window, cx)
                    .is_ok()
            );
            this.request_close(CloseIntent::Tab(id), window, cx);
            assert!(this.closing && this.close_flow.is_some());
            let close = this.close_flow.as_ref().unwrap().token;
            this.cancel_close(&close, window, cx);
            assert_eq!(this.export_request.as_ref().unwrap().token, token);
        })
    })
    .unwrap();
    cx.simulate_new_path_selection(|_| None);
    cx.run_until_parked();
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            window.close_dialog(cx);
            this.command(
                CommandId::ExportResultsJson,
                CommandOrigin::Button,
                None,
                window,
                cx,
            );
            let token = this.export_request.as_ref().unwrap().token;
            this.choose_loaded_export(token, "", window, cx).unwrap();
            this.profiles[0].generation += 1;
        })
    })
    .unwrap();
    cx.simulate_new_path_selection(|_| Some(path.clone()));
    cx.run_until_parked();
    assert_eq!(fs::read_to_string(&path).unwrap(), "original");
    cx.update(|cx| {
        let this = view.read(cx);
        assert!(this.export_request.is_none());
        assert!(this.backend.is_none());
        assert_eq!(this.tabs[0].file.revision, 0);
    });
    fs::remove_dir_all(root).unwrap();
}
#[gpui_kit::test]
fn every_boundary_rejects_new_grid_result_source_profile_session_and_request_owner(
    cx: &mut TestAppContext,
) {
    let root = fixture();
    let path = root.join("existing.json");
    fs::write(&path, "original").unwrap();
    let (window, view) = workspace_tests::workspace(cx);
    for boundary in 0..8 {
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                window.close_dialog(cx);
                this.export_request = None;
                this.active = 0;
                loaded(this, window, cx);
                let capture = Arc::new(this.capture_loaded_export(Format::Json, cx).unwrap());
                this.next_export_request += 1;
                let token = this.next_export_request;
                let bytes = exports::encode(&capture.loaded, Format::Json, "").unwrap();
                let destination = files::CapturedDestination::capture(&path).unwrap();
                let prepared = PreparedExport::prepare(bytes.clone(), &path, &destination).unwrap();
                this.export_request = Some(ExportRequest {
                    cancelled: false,
                    phase: Phase::Writing,
                    token,
                    capture,
                    target: Some(path.clone()),
                    bytes: Some(bytes),
                });
                match boundary {
                    0 => this.tabs[0].generation += 1,
                    1 => this.tabs[0].session_generation += 1,
                    2 => this.profiles[0].generation += 1,
                    3 => this.tabs[0].selected_result += 1,
                    4 => this.tabs[0]
                        .grid
                        .as_ref()
                        .unwrap()
                        .update(cx, |g, _| g.delegate_mut().snapshot += 1),
                    5 => this.tabs[0].result_sets[0].rows[0][0] = Some("changed".into()),
                    6 => this.export_request.as_mut().unwrap().token += 1,
                    _ => this.tabs[0].uncertain = true,
                }
                this.finish_loaded_export(token, Ok(prepared), cx);
                assert_eq!(fs::read_to_string(&path).unwrap(), "original");
                if boundary == 6 {
                    assert!(this.export_request.is_some());
                }
                this.tabs[0].selected_result = 0;
                this.tabs[0].uncertain = false;
            })
        })
        .unwrap();
    }
    fs::remove_dir_all(root).unwrap();
}
#[gpui_kit::test]
fn table_edits_browse_review_apply_cleanup_and_sibling_unknown_or_reload_block_export_zero_calls(
    cx: &mut TestAppContext,
) {
    let backend = client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, grid) = attach(this, &backend, window, cx);
            let index = this.tabs.iter().position(|t| t.id == id).unwrap();
            this.active = index;
            this.tabs[index].result_sets[0].row_count = 2;
            this.tabs[index].result_sets[0].displayed_row_count = 2;
            this.tabs[index].grid_views.clear();
            this.tabs[index].grid = None;
            this.render_live_result(id, window, cx);
            let calls = backend.request_attempts_for_test();
            assert!(this.capture_loaded_export(Format::Json, cx).is_ok());
            for state in 0..7 {
                let table = this.tabs[index]
                    .catalog_document
                    .as_mut()
                    .unwrap()
                    .table
                    .as_mut()
                    .unwrap();
                match state {
                    0 => table.locks.inline_draft = true,
                    1 => table.locks.staged_changes = 1,
                    2 => table.locks.previewing = true,
                    3 => table.locks.applying = true,
                    4 => table.recovery = tables::ChangesRecovery::ReloadRequired,
                    5 => {
                        table.recovery = tables::ChangesRecovery::Unknown {
                            inspection: None,
                            inspected: false,
                        }
                    }
                    _ => {
                        table.pending = Some(tables::Request {
                            revision: table.revision,
                            snapshot: table.snapshot,
                            navigation: table.navigation.clone(),
                        })
                    }
                }
                assert!(this.capture_loaded_export(Format::Json, cx).is_err());
                let table = this.tabs[index]
                    .catalog_document
                    .as_mut()
                    .unwrap()
                    .table
                    .as_mut()
                    .unwrap();
                table.locks = tables::ReplacementLocks::default();
                table.recovery = tables::ChangesRecovery::Ready;
                table.pending = None;
            }
            let original = this.tabs[index].catalog_document.as_ref().unwrap();
            let target = original.target.clone();
            let columns = original.columns.clone();
            let profile = this.tabs[index].profile.clone();
            let kind = this.tabs[index].kind.clone();
            let sibling = this
                .add_document_for_profile(
                    "Sibling".into(),
                    String::new(),
                    profile,
                    kind,
                    window,
                    cx,
                )
                .unwrap();
            let mut sibling_table = tables::TableDocument::new(window, cx);
            sibling_table.recovery = tables::ChangesRecovery::Unknown {
                inspection: None,
                inspected: false,
            };
            this.tabs
                .iter_mut()
                .find(|t| t.id == sibling)
                .unwrap()
                .catalog_document = Some(crate::catalog::CatalogDocument {
                target,
                columns,
                structure: None,
                definition: None,
                loading: false,
                table: Some(sibling_table),
            });
            this.active = index;
            for recovery in [
                tables::ChangesRecovery::Unknown {
                    inspection: None,
                    inspected: false,
                },
                tables::ChangesRecovery::ReloadRequired,
            ] {
                this.tabs
                    .iter_mut()
                    .find(|t| t.id == sibling)
                    .unwrap()
                    .catalog_document
                    .as_mut()
                    .unwrap()
                    .table
                    .as_mut()
                    .unwrap()
                    .recovery = recovery;
                assert!(this.capture_loaded_export(Format::Json, cx).is_err());
            }
            let sibling_table = this
                .tabs
                .iter_mut()
                .find(|t| t.id == sibling)
                .unwrap()
                .catalog_document
                .as_mut()
                .unwrap()
                .table
                .as_mut()
                .unwrap();
            sibling_table.recovery = tables::ChangesRecovery::Ready;
            sibling_table.locks.applying = true;
            assert!(this.capture_loaded_export(Format::Json, cx).is_err());
            this.tabs
                .iter_mut()
                .find(|t| t.id == sibling)
                .unwrap()
                .catalog_document
                .as_mut()
                .unwrap()
                .table
                .as_mut()
                .unwrap()
                .locks
                .applying = false;
            this.profiles.last_mut().unwrap().session = None;
            this.tabs[index].session = None;
            assert!(this.capture_loaded_export(Format::Json, cx).is_ok());
            assert_eq!(backend.request_attempts_for_test(), calls);
            drop(grid);
        })
    })
    .unwrap();
}
