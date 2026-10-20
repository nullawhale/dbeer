use super::{
    CatalogObject, CatalogSchema, NodeId, ResultSet, detail_nodes, object_nodes, object_request,
    value,
};
use crate::backend;

#[test]
fn overload_identity_and_adapter_requests_never_use_display_name_as_identity() {
    let first = CatalogObject {
        name: "quoted \" routine 😀".into(),
        kind: "function".into(),
        identity: Some("21903".into()),
    };
    let mut second = first.clone();
    second.identity = Some("21904".into());
    let a = NodeId::Object {
        schema: "a.b".into(),
        object: first.clone(),
    };
    let b = NodeId::Object {
        schema: "a.b".into(),
        object: second,
    };
    assert!(a != b);
    let request = object_request("a.b", &first, "name");
    assert_eq!(request.identity, "21903");
    assert_eq!(request.object, "quoted \" routine 😀");
    assert!(request.valid());
    let definition = object_request("a.b", &first, "definition");
    assert_eq!(definition.identity, "21903");
}
#[test]
fn expansion_is_local_then_lazy_and_refresh_does_not_erase_old_metadata_on_failure() {
    let schema = CatalogSchema::schema("unexpanded".into());
    let groups = schema.local_children().unwrap();
    assert_eq!(groups.len(), 5);
    for group in groups {
        assert!(!group.loaded);
        assert!(group.id.request().unwrap().valid());
    }
    let table = CatalogSchema::new(
        "t".into(),
        NodeId::Object {
            schema: "s".into(),
            object: CatalogObject {
                name: "t".into(),
                kind: "table".into(),
                identity: None,
            },
        },
    );
    let details = table.local_children().unwrap();
    assert_eq!(details.len(), 5);
    for detail in details {
        let request = detail.id.request().unwrap();
        assert!(request.valid());
        assert_eq!(request.object_kind, "table");
    }
}
#[test]
fn search_returns_unexpanded_schema_context_and_distinct_overloads() {
    let set = ResultSet {
        columns: ["name", "kind", "schema", "identity"]
            .into_iter()
            .map(|name| backend::Column {
                index: 0,
                name: name.into(),
                engine: "postgresql".into(),
                native_type: "text".into(),
                type_oid: 0,
                encoding: None,
            })
            .collect(),
        rows: vec![
            vec![
                Some("f".into()),
                Some("function".into()),
                Some("other".into()),
                Some("11".into()),
            ],
            vec![
                Some("f".into()),
                Some("function".into()),
                Some("other".into()),
                Some("12".into()),
            ],
        ],
        ..Default::default()
    };
    let nodes = object_nodes(&set);
    assert_eq!(nodes.len(), 2);
    assert!(nodes[0].id != nodes[1].id);
    assert_eq!(nodes[0].id.object().unwrap().0, "other");
}
#[test]
fn metadata_preserves_null_empty_literal_and_column_ordinal() {
    let set = ResultSet {
        columns: ["name", "nativeType", "default"]
            .into_iter()
            .map(|name| backend::Column {
                index: 0,
                name: name.into(),
                engine: "postgresql".into(),
                native_type: "text".into(),
                type_oid: 0,
                encoding: None,
            })
            .collect(),
        rows: vec![
            vec![Some("empty".into()), Some("numeric(65,30)".into()), None],
            vec![
                Some("empty".into()),
                Some("text".into()),
                Some(String::new()),
            ],
            vec![
                Some("empty".into()),
                Some("text".into()),
                Some("NULL".into()),
            ],
        ],
        ..Default::default()
    };
    let id = NodeId::DetailGroup {
        schema: "s".into(),
        object: CatalogObject {
            name: "t".into(),
            kind: "table".into(),
            identity: None,
        },
        kind: "columns".into(),
    };
    let nodes = detail_nodes(&id, &set);
    assert_eq!(nodes.len(), 3);
    assert!(nodes[0].id != nodes[1].id);
    assert_eq!(value(&set, &set.rows[0], "default"), None);
    assert_eq!(value(&set, &set.rows[1], "default"), Some(""));
    assert_eq!(value(&set, &set.rows[2], "default"), Some("NULL"));
}

#[cfg(feature = "native-smoke")]
mod headless {
    use super::super::{CatalogContext, CatalogObject, CatalogSchema, NodeId, Work, WorkOutput};
    use crate::{BackendClient, CommandId, Profile, Workspace, backend, model, workspace_tests};
    use gpui_kit::{AppContext, Context, TestAppContext};
    use std::time::Duration;

    fn client() -> BackendClient {
        let client = BackendClient::spawn(
            std::env::var_os("DBEER_GPUI_HELPER_PATH").expect("Use the GPUI test runner."),
        )
        .expect("Start the isolated helper.");
        smol::block_on(client.handshake()).expect("Handshake with the isolated helper.");
        client
    }
    fn attach(this: &mut Workspace, client: &BackendClient) -> usize {
        this.backend = Some(client.clone());
        let mut profile = Profile::saved(crate::connections::ConnectionProfile::new());
        profile.session = Some("catalog-service-only".into());
        profile.session_settings = profile.config.clone();
        this.profiles.push(profile);
        this.profiles.len() - 1
    }
    fn output(sets: Vec<backend::ResultSet>) -> Result<Option<WorkOutput>, backend::BackendError> {
        Ok(Some(WorkOutput {
            completion: None,
            sets,
            truncated: false,
            notice: String::new(),
        }))
    }
    fn set(names: &[&str], rows: Vec<Vec<Option<&str>>>) -> backend::ResultSet {
        backend::ResultSet {
            columns: names
                .iter()
                .enumerate()
                .map(|(index, name)| backend::Column {
                    index,
                    name: (*name).into(),
                    engine: "postgresql".into(),
                    native_type: "text".into(),
                    type_oid: 25,
                    encoding: None,
                })
                .collect(),
            rows: rows
                .into_iter()
                .map(|row| row.into_iter().map(|v| v.map(str::to_owned)).collect())
                .collect(),
            ..Default::default()
        }
    }
    fn context(this: &mut Workspace, index: usize, client: &BackendClient) -> CatalogContext {
        CatalogContext::capture(&mut this.profiles[index], client.clone()).unwrap()
    }
    fn object() -> NodeId {
        NodeId::Object {
            schema: "quoted.schema 😀".into(),
            object: CatalogObject {
                name: "quoted \" table".into(),
                kind: "table".into(),
                identity: None,
            },
        }
    }
    fn metadata() -> backend::ResultSet {
        set(
            &[
                "name",
                "nativeType",
                "nullable",
                "default",
                "generated",
                "primaryKey",
                "editable",
                "editReason",
            ],
            vec![vec![
                Some("id"),
                Some("numeric(65,30)"),
                Some("true"),
                None,
                Some(""),
                Some("1"),
                Some("true"),
                Some(""),
            ]],
        )
    }

    #[gpui_kit::test]
    fn stale_search_success_and_failure_never_mutate_new_query_or_reordered_profile(
        cx: &mut TestAppContext,
    ) {
        let client = client();
        let (window, view) = workspace_tests::workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let index = attach(this, &client);
                let original = context(this, index, &client);
                this.profiles.swap(0, index);
                this.catalog.search.revision = 2;
                this.catalog.search.query = "latest".into();
                let status = this.profiles[0].status.clone();
                let old = Work::Search {
                    revision: 1,
                    query: "earlier".into(),
                };
                this.finish_catalog_work(
                    &original,
                    &old,
                    output(vec![set(
                        &["name", "kind", "schema", "identity"],
                        vec![vec![Some("old"), Some("table"), Some("unexpanded"), None]],
                    )]),
                    window,
                    cx,
                );
                let mut error = backend::BackendError::transport("Obsolete search error");
                error.connected = true;
                this.finish_catalog_work(&original, &old, Err(error), window, cx);
                assert!(this.catalog.search.entries.is_empty());
                assert_eq!(this.profiles[0].status, status);
                let current = Work::Search {
                    revision: 2,
                    query: "latest".into(),
                };
                this.finish_catalog_work(
                    &original,
                    &current,
                    output(vec![set(
                        &["name", "kind", "schema", "identity"],
                        vec![vec![
                            Some("new"),
                            Some("function"),
                            Some("never expanded"),
                            Some("917"),
                        ]],
                    )]),
                    window,
                    cx,
                );
                assert_eq!(
                    this.catalog.search.entries[&original.profile].nodes.len(),
                    1
                );
                assert!(this.profiles[0].schemas.is_empty());
            })
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn lazy_error_retry_retains_metadata_and_exact_service_context(cx: &mut TestAppContext) {
        let client = client();
        let (window, view) = workspace_tests::workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let index = attach(this, &client);
                let mut schema = CatalogSchema::schema("s".into());
                schema.children = schema.local_children().unwrap();
                schema.loaded = true;
                let group = schema.children[0].id.clone();
                schema.children[0].data = Some(metadata());
                schema.children[0].loaded = true;
                schema.children[0].loading = true;
                this.profiles[index].schemas = vec![schema];
                let original = context(this, index, &client);
                let work = Work::Node {
                    id: group.clone(),
                    search_revision: None,
                };
                let mut error = backend::BackendError::transport("Metadata unavailable");
                error.connected = true;
                this.finish_catalog_work(&original, &work, Err(error), window, cx);
                let node = this
                    .find_catalog_node_mut(&original.profile, &group, None)
                    .unwrap();
                assert!(node.error.is_some());
                assert!(!node.loading);
                assert!(node.data.is_some());
                this.profiles[index].config.as_mut().unwrap().host = "changed-endpoint".into();
                assert!(this.catalog_valid(&original).is_none());
                this.finish_catalog_work(
                    &original,
                    &work,
                    output(vec![set(
                        &["name", "kind", "schema", "identity"],
                        Vec::new(),
                    )]),
                    window,
                    cx,
                );
                assert!(this.profiles[index].schemas[0].children[0].data.is_some());
            })
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn table_snapshot_and_generate_select_are_typed_disconnected_and_excluded_from_drafts(
        cx: &mut TestAppContext,
    ) {
        let client = client();
        let (window, view) = workspace_tests::workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let index = attach(this, &client);
                let target = this.catalog_target(index, object()).unwrap();
                let sql_id = this.tabs[0].id;
                this.tabs[0].session = Some("independent-sql-transaction".into());
                this.tabs[0].transaction = "transaction".into();
                let table_id = this
                    .new_catalog_document(target.clone(), true, window, cx)
                    .unwrap();
                let table_editor = this
                    .tabs
                    .iter()
                    .find(|t| t.id == table_id)
                    .unwrap()
                    .editor
                    .entity_id();
                let original = context(this, index, &client);
                let request = this
                    .tabs
                    .iter_mut()
                    .find(|t| t.id == table_id)
                    .unwrap()
                    .catalog_document
                    .as_mut()
                    .unwrap()
                    .table
                    .as_mut()
                    .unwrap()
                    .begin(crate::tables::Navigation::default())
                    .unwrap();
                let work = Work::Table {
                    target: Box::new(target.clone()),
                    document: table_id,
                    request,
                };
                this.finish_catalog_work(
                    &original,
                    &work,
                    output(vec![
                        metadata(),
                        set(
                            &["id"],
                            vec![vec![Some("9007199254740993.000000000000000001")]],
                        ),
                        metadata(),
                    ]),
                    window,
                    cx,
                );
                let tab = this.tabs.iter().find(|t| t.id == table_id).unwrap();
                assert!(matches!(tab.kind, model::DocumentKind::Table { .. }));
                assert!(tab.session.is_none());
                assert_eq!(
                    tab.catalog_document.as_ref().unwrap().columns[0].native_type,
                    "numeric(65,30)"
                );
                assert_eq!(
                    tab.result_sets[0].rows[0][0].as_deref(),
                    Some("9007199254740993.000000000000000001")
                );
                assert_eq!(tab.editor.entity_id(), table_editor);
                let old = tab.result_sets.clone();
                let mut error = backend::BackendError::transport("Browse failed after columns");
                error.connected = true;
                this.finish_catalog_work(&original, &work, Err(error), window, cx);
                assert_eq!(
                    this.tabs
                        .iter()
                        .find(|t| t.id == table_id)
                        .unwrap()
                        .result_sets,
                    old
                );
                let copied = Work::Action {
                    command: CommandId::CatalogCopyName,
                    target: Box::new(target.clone()),
                    document: None,
                };
                let adapter_name = "helper exact quoted name; 😀";
                this.finish_catalog_work(
                    &original,
                    &copied,
                    output(vec![set(&["name"], vec![vec![Some(adapter_name)]])]),
                    window,
                    cx,
                );
                assert_eq!(
                    cx.read_from_clipboard()
                        .and_then(|item| item.text())
                        .as_deref(),
                    Some(adapter_name)
                );
                let sql = "SELECT helper_generated_quoted_names;";
                let generated = Work::Action {
                    command: CommandId::CatalogGenerateSelect,
                    target: Box::new(target),
                    document: None,
                };
                this.finish_catalog_work(
                    &original,
                    &generated,
                    output(vec![set(&["sql"], vec![vec![Some(sql)]])]),
                    window,
                    cx,
                );
                let tab = &this.tabs[this.active];
                assert!(tab.session.is_none());
                assert!(!tab.busy());
                assert_eq!(tab.editor.read(cx).value().as_ref(), sql);
                assert_eq!(
                    this.tabs
                        .iter()
                        .find(|t| t.id == sql_id)
                        .unwrap()
                        .transaction,
                    "transaction"
                );
                let snapshot = this.document_snapshot(cx);
                assert!(snapshot.documents.iter().all(|d| {
                    d.id != this
                        .tabs
                        .iter()
                        .find(|t| t.id == table_id)
                        .unwrap()
                        .persistent_id
                }));
            })
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn changed_helper_and_closed_inspection_do_not_receive_old_payloads(cx: &mut TestAppContext) {
        let original_client = client();
        let replacement = client();
        let (window, view) = workspace_tests::workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let index = attach(this, &original_client);
                let target = this.catalog_target(index, object()).unwrap();
                let id = this
                    .new_catalog_document(target.clone(), false, window, cx)
                    .unwrap();
                let original = context(this, index, &original_client);
                let work = Work::Action {
                    command: CommandId::CatalogInspect,
                    target: Box::new(target),
                    document: Some(id),
                };
                this.backend = Some(replacement.clone());
                this.profiles[index].generation += 1;
                this.profiles[index].session = Some("replacement-service".into());
                let before = this.profiles[index].session.clone();
                this.finish_catalog_work(
                    &original,
                    &work,
                    output(vec![
                        metadata(),
                        set(
                            &["name", "definition"],
                            vec![vec![Some("t"), Some("old definition")]],
                        ),
                    ]),
                    window,
                    cx,
                );
                assert_eq!(this.profiles[index].session, before);
                assert!(
                    this.tabs
                        .iter()
                        .find(|t| t.id == id)
                        .unwrap()
                        .catalog_document
                        .as_ref()
                        .unwrap()
                        .definition
                        .is_none()
                );
                let close_index = this.tabs.iter().position(|t| t.id == id).unwrap();
                this.close_tab(close_index, window, cx);
                assert!(this.tabs.iter().all(|t| t.id != id));
            })
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn typing_and_missing_profile_never_connect_or_load_credentials(cx: &mut TestAppContext) {
        let (window, view) = workspace_tests::workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let mut profile = Profile::saved(crate::connections::ConnectionProfile::new());
                profile.config = None;
                profile.id = model::ProfileId("demo-brewery".into());
                let id = profile.id.clone();
                this.profiles.push(profile);
                this.selected_profile = this.profiles.len() - 1;
                this.add_default_tab(crate::DemoTable::Products, window, cx);
                assert!(!this.document_profile_available(&id));
                assert_eq!(this.tabs[this.active].editor.read(cx).value().as_ref(), "");
                this.catalog.search.query = "unexpanded".into();
                this.catalog.search.revision = 100;
                this.catalog.search.ready = true;
                this.pump_catalog_search(window, cx);
                assert!(this.backend.is_none());
                assert!(this.profiles.iter().all(|p| p.task.is_none()));
                assert!(this.catalog.search.entries.is_empty());
                let editor = this.tabs[this.active].editor.entity_id();
                this.run_query(window, cx);
                assert!(this.backend.is_none());
                assert_eq!(this.tabs[this.active].editor.entity_id(), editor);
            })
        })
        .unwrap();
    }
    fn table_work(
        this: &mut Workspace,
        id: model::DocumentId,
        target: super::super::CatalogTarget,
        navigation: crate::tables::Navigation,
    ) -> Work {
        let doc = this
            .tabs
            .iter_mut()
            .find(|t| t.id == id)
            .unwrap()
            .catalog_document
            .as_mut()
            .unwrap();
        let request = doc.table.as_mut().unwrap().begin(navigation).unwrap();
        doc.loading = true;
        Work::Table {
            target: Box::new(target),
            document: id,
            request,
        }
    }
    #[gpui_kit::test]
    fn table_pages_failed_refresh_stale_sort_and_per_document_navigation(cx: &mut TestAppContext) {
        use crate::tables::{Action, Navigation};
        let client = client();
        let (window, view) = workspace_tests::workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let index = attach(this, &client);
                let target = this.catalog_target(index, object()).unwrap();
                let first = this
                    .new_catalog_document(target.clone(), true, window, cx)
                    .unwrap();
                let second = this
                    .new_catalog_document(target.clone(), true, window, cx)
                    .unwrap();
                let context = context(this, index, &client);
                let work = table_work(this, first, target.clone(), Navigation::default());
                assert_eq!(
                    work.requests()
                        .iter()
                        .map(|r| r.kind.as_str())
                        .collect::<Vec<_>>(),
                    ["columns", "browse", "columns"]
                );
                this.finish_catalog_work(
                    &context,
                    &work,
                    output(vec![
                        metadata(),
                        set(&["id"], vec![vec![Some("0")]; 200]),
                        metadata(),
                    ]),
                    window,
                    cx,
                );
                let old = this
                    .tabs
                    .iter()
                    .find(|t| t.id == first)
                    .unwrap()
                    .result_sets
                    .clone();
                let next = this.capture_table(first, Action::Next, cx).unwrap();
                assert_eq!(next.navigation.page, 0);
                let failed = table_work(
                    this,
                    first,
                    target.clone(),
                    Navigation {
                        page: 1,
                        ..Default::default()
                    },
                );
                let mut error =
                    backend::BackendError::transport("Third metadata request failed after rows");
                error.connected = true;
                this.finish_catalog_work(&context, &failed, Err(error), window, cx);
                let tab = this.tabs.iter().find(|t| t.id == first).unwrap();
                assert_eq!(tab.result_sets, old);
                assert!(tab.error);
                let table = tab
                    .catalog_document
                    .as_ref()
                    .unwrap()
                    .table
                    .as_ref()
                    .unwrap();
                assert_eq!(table.navigation.page, 0);
                assert!(table.possible_next);
                let retry = table_work(
                    this,
                    first,
                    target.clone(),
                    Navigation {
                        page: 1,
                        ..Default::default()
                    },
                );
                this.finish_catalog_work(
                    &context,
                    &retry,
                    output(vec![metadata(), set(&["id"], vec![]), metadata()]),
                    window,
                    cx,
                );
                let tab = this.tabs.iter().find(|t| t.id == first).unwrap();
                let table = tab
                    .catalog_document
                    .as_ref()
                    .unwrap()
                    .table
                    .as_ref()
                    .unwrap();
                assert_eq!(table.navigation.page, 1);
                assert!(!table.possible_next);
                assert!(this.capture_table(first, Action::Previous, cx).is_ok());
                assert!(this.capture_table(first, Action::Next, cx).is_err());
                assert_eq!(
                    this.tabs
                        .iter()
                        .find(|t| t.id == second)
                        .unwrap()
                        .catalog_document
                        .as_ref()
                        .unwrap()
                        .table
                        .as_ref()
                        .unwrap()
                        .navigation
                        .page,
                    0
                );
                // A later sort/filter revision owns the terminal, even if the same service survives.
                let stale = table_work(this, first, target.clone(), Navigation::default());
                if let Work::Table { request, .. } = &stale {
                    this.tabs
                        .iter_mut()
                        .find(|t| t.id == first)
                        .unwrap()
                        .catalog_document
                        .as_mut()
                        .unwrap()
                        .table
                        .as_mut()
                        .unwrap()
                        .fail(request);
                }
                let newer = table_work(
                    this,
                    first,
                    target.clone(),
                    Navigation {
                        filters: vec![backend::CatalogFilter {
                            column: "id".into(),
                            operator: backend::FilterOperator::Eq,
                            value: Some("0".into()),
                        }],
                        ..Default::default()
                    },
                );
                this.finish_catalog_work(
                    &context,
                    &stale,
                    output(vec![
                        metadata(),
                        set(&["id"], vec![vec![Some("stale")]]),
                        metadata(),
                    ]),
                    window,
                    cx,
                );
                let mut late_error =
                    backend::BackendError::transport("Old filter privilege failure");
                late_error.connected = true;
                this.finish_catalog_work(&context, &stale, Err(late_error), window, cx);
                let table = this
                    .tabs
                    .iter()
                    .find(|t| t.id == first)
                    .unwrap()
                    .catalog_document
                    .as_ref()
                    .unwrap()
                    .table
                    .as_ref()
                    .unwrap();
                assert!(table.pending.is_some());
                assert_eq!(table.navigation.page, 1);
                let mut changed = metadata();
                changed.rows[0][1] = Some("text".into());
                this.finish_catalog_work(
                    &context,
                    &newer,
                    output(vec![
                        metadata(),
                        set(&["id"], vec![vec![Some("new")]]),
                        changed,
                    ]),
                    window,
                    cx,
                );
                let tab = this.tabs.iter().find(|t| t.id == first).unwrap();
                assert!(tab.result_sets[0].rows.is_empty());
                assert_eq!(
                    tab.catalog_document.as_ref().unwrap().columns[0].native_type,
                    "numeric(65,30)"
                );
                assert_eq!(
                    tab.catalog_document
                        .as_ref()
                        .unwrap()
                        .table
                        .as_ref()
                        .unwrap()
                        .navigation
                        .page,
                    1
                );
                // Locks activated after submission protect pending drafts from all terminals.
                let locked = table_work(this, first, target, Navigation::default());
                this.tabs
                    .iter_mut()
                    .find(|t| t.id == first)
                    .unwrap()
                    .catalog_document
                    .as_mut()
                    .unwrap()
                    .table
                    .as_mut()
                    .unwrap()
                    .locks
                    .inline_draft = true;
                this.finish_catalog_work(
                    &context,
                    &locked,
                    output(vec![
                        metadata(),
                        set(&["id"], vec![vec![Some("new")]]),
                        metadata(),
                    ]),
                    window,
                    cx,
                );
                assert!(
                    this.tabs
                        .iter()
                        .find(|t| t.id == first)
                        .unwrap()
                        .result_sets[0]
                        .rows
                        .is_empty()
                );
            });
        })
        .unwrap();
    }
    // Compiled preparation only. Native timing/backpressure cases run at final integration.
    #[gpui_kit::test]
    async fn rapid_search_keeps_one_debounce_and_latest_query(cx: &mut TestAppContext) {
        let (window, view) = workspace_tests::workspace(cx);
        for n in 0..250 {
            cx.update_window(window, |_, window, cx| {
                view.update(cx, |this, cx: &mut Context<Workspace>| {
                    this.search.update(cx, |state, cx| {
                        state.set_value(format!("latest-{n}"), window, cx)
                    });
                    this.schedule_catalog_search(window, cx);
                })
            })
            .unwrap();
        }
        cx.background_executor
            .timer(Duration::from_millis(300))
            .await;
        cx.update(|cx| {
            let this = view.read(cx);
            assert_eq!(this.catalog.search.query, "latest-249");
            assert!(this.backend.is_none());
            assert!(this.catalog.search.entries.is_empty());
        });
    }

    #[gpui_kit::test]
    fn completion_replacement_failure_and_late_helper_context_are_atomic(cx: &mut TestAppContext) {
        let (window, view) = crate::workspace_tests::workspace(cx);
        let original = client();
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |this, cx| {
                let index = attach(this, &original);
                this.profiles[index].loaded = true;
                this.profiles[index].session_client = Some(original.clone());
                let profile = this.profiles[index].id.clone();
                this.invalidate_completion(&profile, false);
                let revision = this.catalog.completion.entries[&profile].revision;
                let context = context(this, index, &original);
                let snapshot = crate::language_service::CatalogSnapshot::bounded([
                    crate::language_service::metadata::Relation {
                        schema: "public".into(),
                        name: "retained".into(),
                        kind: "table".into(),
                        columns: vec!["id".into()],
                        foreign_keys: vec![],
                        signatures: vec![],
                    },
                ]);
                this.complete_catalog_work(
                    &context,
                    &Work::Completion { revision },
                    WorkOutput {
                        completion: Some(snapshot),
                        sets: vec![],
                        truncated: false,
                        notice: String::new(),
                    },
                    window,
                    cx,
                );
                assert_eq!(this.completion_snapshot(&profile).1.relations().len(), 1);
                this.invalidate_completion(&profile, false);
                let new_revision = this.catalog.completion.entries[&profile].revision;
                this.finish_catalog_work(
                    &context,
                    &Work::Completion { revision },
                    Ok(Some(WorkOutput {
                        completion: Some(Default::default()),
                        sets: vec![],
                        truncated: false,
                        notice: String::new(),
                    })),
                    window,
                    cx,
                );
                assert_eq!(this.completion_snapshot(&profile).1.relations().len(), 1);
                let mut error = backend::BackendError::transport("Fixed fixture failure");
                error.connected = true;
                this.finish_catalog_work(
                    &context,
                    &Work::Completion {
                        revision: new_revision,
                    },
                    Err(error),
                    window,
                    cx,
                );
                assert_eq!(this.completion_snapshot(&profile).1.relations().len(), 1);
                assert!(
                    this.completion_status(&profile)
                        .unwrap()
                        .contains("previous")
                );
                this.profiles[index].service_generation += 1;
                assert!(this.completion_snapshot(&profile).1.relations().is_empty());
                assert!(!this.completion_work_current(&context, new_revision));
                assert!(this.tabs.iter().all(|tab| tab.session.is_none()));
            })
        })
        .unwrap();
    }
}

// Real helper preparation: system catalog reads need no application fixture writes.
#[test]
fn postgres_mysql_service_catalog_search_and_actions_preserve_sql_transaction() {
    for connection in [
        crate::live_tests::postgres_connection(),
        crate::live_tests::mysql_connection(),
    ]
    .into_iter()
    .flatten()
    {
        smol::block_on(async move {
            let client = crate::live_tests::client().await;
            let sql = crate::live_tests::bounded(client.connect(connection.clone()))
                .await
                .expect("Connect independent SQL session.");
            let service = crate::live_tests::bounded(client.connect(connection.clone()))
                .await
                .expect("Connect first profile service.");
            let other = crate::live_tests::bounded(client.connect(connection))
                .await
                .expect("Connect second profile service.");
            assert!(sql.session_id != service.session_id && service.session_id != other.session_id);
            let begin = crate::live_tests::finish(
                client
                    .execute(&sql.session_id, "START TRANSACTION READ ONLY".into())
                    .expect("Enqueue SQL transaction."),
            )
            .await
            .expect("Begin SQL transaction.");
            assert_eq!(
                begin.transaction_status,
                backend::TransactionStatus::Transaction
            );
            for session in [&service.session_id, &other.session_id] {
                let owner = crate::language_service::metadata::CatalogOwner {
                    profile_id: "observer-service".into(),
                    settings_revision: 1,
                    service_generation: 1,
                    catalog_revision: 1,
                };
                let mut pager = crate::language_service::metadata::CatalogPager::new(owner.clone());
                while let Some(request) = pager.next_request() {
                    let page = request.page;
                    let outcome = crate::live_tests::finish(
                        client
                            .catalog(session, request)
                            .expect("Enqueue connected completion page."),
                    )
                    .await
                    .expect("Read connected completion page.");
                    assert_eq!(outcome.transaction_status, backend::TransactionStatus::Idle);
                    pager
                        .accept_page(&owner, page, &outcome.result_sets)
                        .expect("Validate ordinal completion metadata.");
                }
                let snapshot = pager
                    .finish(&owner)
                    .expect("Publish complete metadata snapshot.");
                assert!(
                    snapshot
                        .relations()
                        .iter()
                        .all(|r| matches!(r.kind.as_str(), "table" | "view" | "function"))
                );
                let search = crate::live_tests::finish(
                    client
                        .catalog(
                            session,
                            backend::CatalogRequest {
                                kind: "search".into(),
                                search: "tables".into(),
                                ..Default::default()
                            },
                        )
                        .expect("Enqueue unexpanded server search."),
                )
                .await
                .expect("Search connected profile.");
                assert_eq!(search.transaction_status, backend::TransactionStatus::Idle);
                let nodes = object_nodes(&search.result_sets[0]);
                let target = nodes
                    .iter()
                    .find_map(|node| {
                        node.id.object().filter(|(schema, object)| {
                            *schema == "information_schema"
                                && object.name.eq_ignore_ascii_case("tables")
                        })
                    })
                    .expect("Server search includes unexpanded system relation.");
                for kind in ["columns", "name", "select", "browse"] {
                    let result = crate::live_tests::finish(
                        client
                            .catalog(session, object_request(target.0, target.1, kind))
                            .expect("Enqueue typed catalog action."),
                    )
                    .await
                    .expect("Complete isolated catalog action.");
                    assert_eq!(result.transaction_status, backend::TransactionStatus::Idle);
                    if kind == "columns" {
                        assert!(result.result_sets[0].table_metadata().is_ok());
                    }
                    if kind == "browse" {
                        assert!(result.result_sets[0].rows.len() <= 200);
                    }
                    if kind == "select" {
                        assert!(
                            !super::first_value(&result.result_sets, "sql")
                                .unwrap_or("")
                                .is_empty()
                        );
                    }
                    if kind == "name" {
                        assert!(
                            !super::first_value(&result.result_sets, "name")
                                .unwrap_or("")
                                .is_empty()
                        );
                    }
                }
            }
            let still_open = crate::live_tests::finish(
                client
                    .execute(&sql.session_id, "SELECT 1".into())
                    .expect("Inspect original SQL transaction."),
            )
            .await
            .expect("Read original SQL session.");
            assert_eq!(
                still_open.transaction_status,
                backend::TransactionStatus::Transaction
            );
            crate::live_tests::finish(
                client
                    .execute(&sql.session_id, "ROLLBACK".into())
                    .expect("Enqueue test rollback."),
            )
            .await
            .expect("Rollback owned SQL transaction.");
            for session in [&sql.session_id, &service.session_id, &other.session_id] {
                client
                    .disconnect(session)
                    .await
                    .expect("Disconnect owned test session.");
            }
            drop(client);
        });
    }
}
