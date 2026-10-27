//! Prepared headless production callbacks. No desktop/IME/DB acceptance is implied.
use super::Action;
use crate::{
    BackendClient, CloseIntent, CommandId, CommandOrigin, Profile, ResultGrid, Workspace, backend,
    catalog, close,
    connections::ConnectionProfile,
    grid_changes::Draft,
    model::{self, DocumentId},
    results, tables, workspace_tests,
};
use gpui_kit::component::WindowExt;
use gpui_kit::component::table::TableState;
use gpui_kit::test::TestWindowExt;
use gpui_kit::{AppContext, Context, Entity, Focusable, TestAppContext, Window};

pub(crate) fn client() -> BackendClient {
    let client = BackendClient::spawn(
        std::env::var_os("DBEER_GPUI_HELPER_PATH").expect("Use the GPUI runner."),
    )
    .expect("Start the owned isolated helper.");
    smol::block_on(client.handshake()).expect("Handshake with the owned isolated helper.");
    client
}
pub(crate) fn attach(
    this: &mut Workspace,
    client: &BackendClient,
    window: &mut Window,
    cx: &mut Context<Workspace>,
) -> (DocumentId, Entity<TableState<ResultGrid>>) {
    this.backend = Some(client.clone());
    let mut profile = Profile::saved(ConnectionProfile::new());
    profile.session = Some("service-with-no-database-connection".into());
    profile.session_settings = profile.config.clone();
    profile.session_client = Some(client.clone());
    profile.loaded = true;
    let id = profile.id.clone();
    this.profiles.push(profile);
    let node = catalog::NodeId::Object {
        schema: "synthetic".into(),
        object: catalog::CatalogObject {
            name: "table".into(),
            kind: "table".into(),
            identity: None,
        },
    };
    let target = this.catalog_target(this.profiles.len() - 1, node).unwrap();
    let document = this
        .add_document_for_profile(
            "Table".into(),
            String::new(),
            id,
            model::DocumentKind::Table {
                schema: "synthetic".into(),
                object: "table".into(),
                object_kind: "table".into(),
            },
            window,
            cx,
        )
        .unwrap();
    let columns: Vec<_> = ["id", "value"]
        .into_iter()
        .enumerate()
        .map(|(index, name)| backend::Column {
            index,
            name: name.into(),
            engine: "postgresql".into(),
            native_type: "text".into(),
            type_oid: 25,
            encoding: None,
        })
        .collect();
    let metadata = columns
        .iter()
        .enumerate()
        .map(|(i, c)| backend::TableColumnMetadata {
            name: c.name.clone(),
            native_type: c.native_type.clone(),
            nullable: i != 0,
            default: None,
            generated: String::new(),
            primary_key: u32::from(i == 0),
            editable: true,
            edit_reason: String::new(),
        })
        .collect();
    let table = &mut this.tabs.iter_mut().find(|t| t.id == document).unwrap();
    let mut state = tables::TableDocument::new(window, cx);
    state.snapshot = 7;
    state.revision = 7;
    table.catalog_document = Some(catalog::CatalogDocument {
        target,
        columns: metadata,
        structure: None,
        definition: None,
        loading: false,
        table: Some(state),
    });
    table.result_sets = vec![backend::ResultSet {
        columns,
        rows: vec![
            vec![Some("2".into()), Some("Bravo".into())],
            vec![Some("1".into()), Some("alpha".into())],
        ],
        ..Default::default()
    }];
    this.render_live_result(document, window, cx);
    let grid = this
        .tabs
        .iter()
        .find(|t| t.id == document)
        .unwrap()
        .grid
        .clone()
        .unwrap();
    grid.update(cx, |table, cx| {
        table.delegate_mut().pointer(0, 2, false, false, false);
        cx.notify();
    });
    (document, grid)
}
fn locks(this: &Workspace, id: DocumentId) -> &tables::ReplacementLocks {
    &this
        .tabs
        .iter()
        .find(|t| t.id == id)
        .unwrap()
        .catalog_document
        .as_ref()
        .unwrap()
        .table
        .as_ref()
        .unwrap()
        .locks
}
#[gpui_kit::test]
fn production_inline_stage_cancel_expansion_mapping_and_batch_send_no_helper_calls(
    cx: &mut TestAppContext,
) {
    let client = client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, grid) = attach(this, &client, window, cx);
            let original = grid.read(cx).delegate().original.clone();
            let requests = client.request_attempts_for_test();
            let sql_editor = this.tabs[0].editor.clone();
            let sql_value = sql_editor.read(cx).value().to_string();
            let c = this.changes_capture(id, cx).unwrap();
            this.changes_action(c, Action::Edit(false), None, window, cx);
            assert!(locks(this, id).inline_draft);
            let inline = grid.read(cx).delegate().inline.as_ref().unwrap();
            let editor = inline.editor.clone();
            let token = inline.token;
            editor.update(cx, |e, cx| {
                e.set_value("NULL", window, cx);
                e.set_selected_range(1..3, cx);
            });
            // Expansion moves the same entity; no replacement, Undo reset or staging.
            grid.update(cx, |t, _| {
                t.delegate_mut().inline.as_mut().unwrap().expanded = true
            });
            assert_eq!(
                grid.read(cx)
                    .delegate()
                    .inline
                    .as_ref()
                    .unwrap()
                    .editor
                    .entity_id(),
                editor.entity_id()
            );
            let c = this.changes_capture(id, cx).unwrap();
            this.finish_cell(c, token, true, window, cx);
            assert!(!locks(this, id).inline_draft);
            assert_eq!(locks(this, id).staged_changes, 1);
            let g = grid.read(cx).delegate();
            assert_eq!(g.original, original);
            assert_eq!(
                g.payload(results::interaction::CopyMode::Range)
                    .unwrap()
                    .values[0][0]
                    .kind,
                "text"
            );
            assert_eq!(
                g.payload(results::interaction::CopyMode::Range)
                    .unwrap()
                    .values[0][0]
                    .value
                    .as_deref(),
                Some("NULL")
            );
            let c = this.changes_capture(id, cx).unwrap();
            let batch = this.changes_batch(&c, cx).unwrap();
            assert_eq!(batch.capture.revision, c.revision);
            assert!(batch.request.valid());
            assert!(
                batch.request.changes[0].original[1] == backend::CellValue::Text("Bravo".into())
            );
            assert!(this.capture_table(id, tables::Action::Next, cx).is_err());
            this.changes_action(c, Action::Edit(true), None, window, cx);
            let (editor, token) = {
                let i = grid.read(cx).delegate().inline.as_ref().unwrap();
                (i.editor.clone(), i.token)
            };
            editor.update(cx, |e, cx| {
                e.set_value("uncommitted\nlarge value", window, cx)
            });
            this.finish_cell(
                this.changes_capture(id, cx).unwrap(),
                token,
                false,
                window,
                cx,
            );
            assert_eq!(
                grid.read(cx).delegate().draft.as_ref().unwrap().pending(),
                1
            );
            assert_eq!(
                grid.read(cx)
                    .delegate()
                    .payload(results::interaction::CopyMode::Range)
                    .unwrap()
                    .values[0][0]
                    .value
                    .as_deref(),
                Some("NULL")
            );
            assert_eq!(sql_editor.read(cx).value().as_ref(), sql_value);
            assert_eq!(
                client.request_attempts_for_test(),
                requests,
                "Local editing attempted a hidden helper request."
            );
            this.changes_action(
                this.changes_capture(id, cx).unwrap(),
                Action::Discard,
                None,
                window,
                cx,
            );
            assert!(!locks(this, id).locked());
            assert_eq!(grid.read(cx).delegate().original, original);
        })
    })
    .unwrap();
}
#[gpui_kit::test]
fn inline_focus_refuses_run_and_late_browse_cannot_replace_the_original(cx: &mut TestAppContext) {
    let client = client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, grid) = attach(this, &client, window, cx);
            let request = this
                .tabs
                .iter_mut()
                .find(|t| t.id == id)
                .unwrap()
                .catalog_document
                .as_mut()
                .unwrap()
                .table
                .as_mut()
                .unwrap()
                .begin(tables::Navigation::default())
                .unwrap();
            this.changes_action(
                this.changes_capture(id, cx).unwrap(),
                Action::Edit(false),
                None,
                window,
                cx,
            );
            let editor = grid
                .read(cx)
                .delegate()
                .inline
                .as_ref()
                .unwrap()
                .editor
                .clone();
            assert!(editor.focus_handle(cx).is_focused(window));
            assert_eq!(
                this.command_context(CommandId::RunCurrent, None, window, cx)
                    .focus,
                crate::commands::CommandFocus::TextInput
            );
            let selection = grid.read(cx).delegate().selection.clone();
            results::interaction::select_all(&grid, window, cx);
            assert_eq!(
                grid.read(cx).delegate().selection,
                selection,
                "Grid navigation replaced focused field input."
            );
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
            assert!(
                !this
                    .tabs
                    .iter()
                    .find(|t| t.id == id)
                    .unwrap()
                    .catalog_document
                    .as_ref()
                    .unwrap()
                    .table
                    .as_ref()
                    .unwrap()
                    .owns(&request)
            );
            let original = grid.read(cx).delegate().original.clone();
            // Even a direct late rendering attempt must preserve the retained draft.
            this.tabs
                .iter_mut()
                .find(|t| t.id == id)
                .unwrap()
                .result_sets[0]
                .rows[0][1] = Some("late browse".into());
            this.render_live_result(id, window, cx);
            assert_eq!(grid.read(cx).delegate().original, original);
            assert_eq!(
                grid.read(cx)
                    .delegate()
                    .inline
                    .as_ref()
                    .unwrap()
                    .editor
                    .entity_id(),
                editor.entity_id()
            );
        })
    })
    .unwrap();
}
#[gpui_kit::test]
fn close_cancel_and_later_transaction_cancel_preserve_inline_and_deferred_discard(
    cx: &mut TestAppContext,
) {
    let client = client();
    let (window, view) = workspace_tests::workspace(cx);
    let (id, editor, token, grid) = cx
        .update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let (id, grid) = attach(this, &client, window, cx);
                this.changes_action(
                    this.changes_capture(id, cx).unwrap(),
                    Action::Edit(true),
                    None,
                    window,
                    cx,
                );
                let i = grid.read(cx).delegate().inline.as_ref().unwrap();
                (id, i.editor.clone(), i.token, grid.clone())
            })
        })
        .unwrap();
    cx.update_window(window, |_, window, cx| {
        editor.update(cx, |e, cx| {
            e.set_value("retained inline buffer", window, cx);
            e.set_selected_range(3..8, cx);
        })
    })
    .unwrap();
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            this.request_close(CloseIntent::Tab(id), window, cx);
            let first = this.close_flow.as_ref().unwrap().token;
            assert_eq!(
                this.close_flow.as_ref().unwrap().phase,
                close::ClosePhase::Changes(id)
            );
            this.request_close(CloseIntent::Window, window, cx);
            assert_eq!(this.close_flow.as_ref().unwrap().token, first);
        })
    })
    .unwrap();
    cx.update_window(window, |_, window, cx| {
        window.press("enter", cx);
    })
    .unwrap();
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            assert!(this.close_flow.is_none());
            assert!(!this.closing);
            let i = grid.read(cx).delegate().inline.as_ref().unwrap();
            assert_eq!(i.token, token);
            assert_eq!(i.editor.entity_id(), editor.entity_id());
            assert_eq!(i.editor.read(cx).value().as_ref(), "retained inline buffer");
            assert_eq!(i.editor.read(cx).selected_range(), 3..8);
            // Window close resolves existing SQL transactions before table Apply.
            this.tabs[0].transaction = "transaction".into();
            this.request_close(CloseIntent::Window, window, cx);
            assert!(matches!(
                this.close_flow.as_ref().unwrap().phase,
                close::ClosePhase::Transaction(_)
            ));
            assert!(grid.read(cx).delegate().inline.is_some());
        })
    })
    .unwrap();
    cx.update_window(window, |_, window, cx| {
        window.press("escape", cx);
    })
    .unwrap();
    cx.update_window(window, |_, _, cx| {
        view.update(cx, |this, cx| {
            assert!(!this.closing);
            assert!(grid.read(cx).delegate().inline.is_some());
            assert_eq!(editor.read(cx).value().as_ref(), "retained inline buffer");
        })
    })
    .unwrap();
}
#[gpui_kit::test]
fn stale_revision_refuses_discard_and_clear_sql_drafts_excludes_table_edits(
    cx: &mut TestAppContext,
) {
    let client = client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, grid) = attach(this, &client, window, cx);
            this.changes_action(
                this.changes_capture(id, cx).unwrap(),
                Action::Insert,
                None,
                window,
                cx,
            );
            this.request_close(CloseIntent::Tab(id), window, cx);
            let token = this.close_flow.as_ref().unwrap().token;
            grid.update(cx, |table, _| {
                table.delegate_mut().draft.as_mut().unwrap().touch()
            });
            this.choose_close_discard(token, id, window, cx);
            assert!(this.close_flow.is_none());
            assert_eq!(
                grid.read(cx).delegate().draft.as_ref().unwrap().pending(),
                1
            );
            window.close_dialog(cx);
            this.tabs[0].transaction = "transaction".into();
            this.request_close(CloseIntent::ClearDrafts, window, cx);
            assert!(matches!(
                this.close_flow.as_ref().unwrap().phase,
                close::ClosePhase::Transaction(_)
            ));
            assert!(!locks(this, id).closing);
            assert_eq!(
                grid.read(cx).delegate().draft.as_ref().unwrap().pending(),
                1
            );
            let token = this.close_flow.as_ref().unwrap().token;
            window.close_dialog(cx);
            this.cancel_close(&token, window, cx);
            // A stale service/settings capture can no longer stage, but local Cancel/Discard is safe.
            let c = this.changes_capture(id, cx).unwrap();
            let profile = this.profile_index(&c.owner.target.profile).unwrap();
            this.profiles[profile].config.as_mut().unwrap().host = "different-endpoint".into();
            assert!(!this.changes_valid(&c, true, cx));
            this.changes_action(c, Action::Discard, None, window, cx);
            assert_eq!(
                grid.read(cx).delegate().draft.as_ref().unwrap().pending(),
                0
            );
        })
    })
    .unwrap();
}
#[gpui_kit::test]
fn immutable_batch_rejects_changes_and_capability_fingerprints_and_inserted_selection_stays_stable(
    cx: &mut TestAppContext,
) {
    let client = client();
    let (window, view) = workspace_tests::workspace(cx);
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            let (id, grid) = attach(this, &client, window, cx);
            let c = this.changes_capture(id, cx).unwrap();
            this.changes_action(c, Action::Insert, None, window, cx);
            let c = this.changes_capture(id, cx).unwrap();
            let batch = this.changes_batch(&c, cx).unwrap();
            let inserted = grid.read(cx).delegate().selection.focus.unwrap().row;
            grid.update(cx, |table, cx| {
                let g = table.delegate_mut();
                assert!(g.draft.as_mut().unwrap().set(
                    inserted,
                    1,
                    backend::CellValue::Text("new row".into())
                ));
                g.project_draft();
                g.set_filter("new row");
                cx.notify();
            });
            this.sync_changes_locks(id, cx);
            assert!(!this.changes_valid(&batch.capture, true, cx));
            assert!(batch.request.changes[0].values.is_empty());
            let g = grid.read(cx).delegate();
            assert_eq!(g.selected_sources(), [2]);
            assert_eq!(g.row_ids[g.visible_rows[0]], inserted);
            assert_eq!(g.original.rows.len(), 2);
            let c = this.changes_capture(id, cx).unwrap();
            grid.update(cx, |t, _| t.delegate_mut().metadata[1].editable = false);
            assert!(!this.changes_valid(&c, true, cx));
            // Ordinal metadata validation prevents a name-based change from staging.
            let set = grid.read(cx).delegate().original.clone();
            let mut meta = grid.read(cx).delegate().metadata.clone();
            meta[0].name = "value".into();
            assert!(Draft::new(&set, meta, 7, &[1, 2]).is_none());
        })
    })
    .unwrap();
}

#[gpui_kit::test]
fn profile_delete_cancel_and_failed_profile_publication_keep_reviewed_drafts(
    cx: &mut TestAppContext,
) {
    let client = client();
    let (window, view) = workspace_tests::workspace(cx);
    let (id, grid, mutation) = cx
        .update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let (id, grid) = attach(this, &client, window, cx);
                this.changes_action(
                    this.changes_capture(id, cx).unwrap(),
                    Action::Insert,
                    None,
                    window,
                    cx,
                );
                let capture = this.changes_capture(id, cx).unwrap();
                let profile = this.profile_index(&capture.owner.target.profile).unwrap();
                let expected = this.profiles[profile].config.clone().unwrap();
                let mutation = std::sync::Arc::new(crate::profiles::ProfileMutation {
                    change: crate::profiles::ProfileChange::Delete(Box::new(expected)),
                    editor: None,
                    startup: false,
                });
                this.request_close(CloseIntent::ProfileMutation(mutation.clone()), window, cx);
                assert_eq!(
                    this.close_flow.as_ref().unwrap().phase,
                    close::ClosePhase::Changes(id)
                );
                (id, grid, mutation)
            })
        })
        .unwrap();
    cx.update_window(window, |_, window, cx| {
        window.press("escape", cx);
    })
    .unwrap();
    cx.update_window(window, |_, window, cx| {
        view.update(cx, |this, cx| {
            assert!(this.close_flow.is_none());
            assert_eq!(
                grid.read(cx).delegate().draft.as_ref().unwrap().pending(),
                1
            );
            let profile = this.profile_index(&mutation.profile_id()).unwrap();
            // Simulate an acknowledged disconnected service; avoid an actual DB call.
            this.profiles[profile].session = None;
            this.profiles[profile].session_settings = None;
            this.request_close(CloseIntent::ProfileMutation(mutation.clone()), window, cx);
            let token = this.close_flow.as_ref().unwrap().token;
            this.choose_close_discard(token, id, window, cx);
            assert_eq!(
                this.close_flow.as_ref().unwrap().phase,
                close::ClosePhase::Finishing
            );
            assert_eq!(
                grid.read(cx).delegate().draft.as_ref().unwrap().pending(),
                1
            );
        })
    })
    .unwrap();
    workspace_tests::await_workspace(cx, &view, |this| !this.closing && this.close_flow.is_none());
    cx.update_window(window, |_, _, cx| {
        view.update(cx, |this, cx| {
            // No ProfileStore ownership is available in this disposable workspace,
            // so publication refuses and the approved-but-not-cleared draft survives.
            assert!(this.close_flow.is_none());
            assert!(!this.closing);
            assert_eq!(
                grid.read(cx).delegate().draft.as_ref().unwrap().pending(),
                1
            );
            assert!(
                this.profiles
                    .iter()
                    .any(|p| p.id == mutation.profile_id() && p.config.is_some())
            );
        })
    })
    .unwrap();
}
