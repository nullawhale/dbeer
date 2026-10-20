use super::*;
use crate::{grid_clipboard::Value, tables::Navigation};
use interaction::CopyMode;

fn fixture() -> backend::ResultSet {
    serde_json::from_str(include_str!("../../fixtures/grid-selection-v1.json")).unwrap()
}

fn grid(
    set: backend::ResultSet,
    page: Option<u32>,
    snapshot: u64,
    primary_key: bool,
) -> ResultGrid {
    let mut grid = ResultGrid::new(QueryResult {
        columns: set
            .columns
            .iter()
            .map(|c| crate::demo::Column {
                name: c.name.clone(),
                data_type: c.native_type.clone(),
                width: 140.,
            })
            .collect(),
        rows: set
            .rows
            .iter()
            .map(|r| {
                r.iter()
                    .zip(&set.columns)
                    .map(|(v, c)| match v {
                        None => Cell::Null,
                        Some(v) if c.encoding.as_deref() == Some("base64") => {
                            Cell::Binary(v.clone())
                        }
                        Some(v) if c.native_type == "numeric" => Cell::Number(v.clone()),
                        Some(v) => Cell::Text(v.clone()),
                    })
                    .collect()
            })
            .collect(),
    });
    let metadata = if page.is_some() {
        set.columns
            .iter()
            .enumerate()
            .map(|(i, c)| backend::TableColumnMetadata {
                name: c.name.clone(),
                native_type: c.native_type.clone(),
                nullable: true,
                default: None,
                generated: String::new(),
                primary_key: u32::from(primary_key && i == 0),
                editable: i < 2,
                edit_reason: if i == 2 {
                    "Binary is read only for this fixture.".into()
                } else {
                    String::new()
                },
            })
            .collect()
    } else {
        Vec::new()
    };
    grid.bind(
        set,
        metadata,
        snapshot,
        page.map(|page| Navigation {
            page,
            ..Default::default()
        }),
        "Read only in Task 16.".into(),
    );
    grid
}

#[test]
fn rectangle_has_only_actual_cells_duplicate_ordinals_and_exact_typed_values() {
    let mut g = grid(fixture(), None, 1, false);
    assert!(g.payload(CopyMode::Range).is_none());
    g.pointer(0, 1, false, false, false);
    g.pointer(1, 2, true, false, false);
    let payload = g.payload(CopyMode::Range).unwrap();
    assert_eq!(payload.source_rows, [0, 1]);
    assert_eq!(payload.source_column_indices, [0, 1]);
    assert_eq!(
        payload
            .columns
            .iter()
            .map(|c| c.name.as_str())
            .collect::<Vec<_>>(),
        ["x", "x"]
    );
    assert_eq!(
        payload.columns.iter().map(|c| c.index).collect::<Vec<_>>(),
        [0, 1]
    );
    let publication = payload.prepare().unwrap();
    assert_eq!(
        publication.text,
        "9007199254740993.123456789\t\"\"\n\\N\tNULL"
    );
    let decoded: crate::grid_clipboard::Payload = serde_json::from_str(&publication.json).unwrap();
    assert_eq!(decoded, payload);
    assert_eq!(
        decoded.values[0][0].value.as_deref(),
        Some("9007199254740993.123456789")
    );
    assert_eq!(decoded.values[0][1].value.as_deref(), Some(""));
    assert_eq!(decoded.values[1][0].kind, "null");
    assert_eq!(decoded.values[1][1].kind, "text");
}

#[test]
fn sparse_rows_full_row_headers_and_context_cell_stay_distinct_from_copy_loaded_rows() {
    let mut g = grid(fixture(), None, 1, false);
    g.pointer(0, 0, false, false, false);
    g.pointer(3, 2, false, true, false);
    assert!(g.selection.whole_rows);
    let payload = g.payload(CopyMode::Range).unwrap();
    assert_eq!(payload.source_rows, [0, 3]);
    assert_eq!(payload.source_column_indices, [0, 1, 2]);
    assert_eq!(
        payload.values[0][2],
        Value {
            kind: "binary".into(),
            value: Some("AAEC/w==".into())
        }
    );
    assert_eq!(
        payload.values[1][1].value.as_deref(),
        Some("line one\r\nline two\t\"quoted\"")
    );
    assert!(
        payload
            .prepare()
            .unwrap()
            .text
            .contains("\"line one\r\nline two\t\"\"quoted\"\"\"")
    );
    g.context_cell = Some(crate::grid_selection::CellPoint {
        row: g.row_ids[0],
        column: 2,
    });
    let cell = g.payload(CopyMode::Cell).unwrap();
    assert_eq!(cell.source_rows, [0]);
    assert_eq!(cell.source_column_indices, [2]);
    assert_eq!(cell.prepare().unwrap().text, "AAEC/w==");
    assert_ne!(cell.prepare().unwrap().text, g.copy_tsv());
    g.pointer(0, 1, false, true, false);
    g.pointer(3, 1, false, true, false);
    assert!(g.payload(CopyMode::Range).is_none());
}

#[test]
fn local_sort_filter_keep_original_source_mapping_and_never_retarget_hidden_selection() {
    let mut g = grid(fixture(), None, 1, false);
    g.pointer(0, 1, false, false, false);
    let id = g.selection.focus.unwrap().row;
    g.sort = Some((1, ColumnSort::Descending));
    g.rebuild_rows();
    assert_eq!(g.payload(CopyMode::Range).unwrap().source_rows, [0]);
    assert_eq!(g.selection.focus.unwrap().row, id);
    g.set_filter("line one");
    assert!(g.payload(CopyMode::Range).is_none());
    assert_eq!(g.selection.focus.unwrap().row, id);
    g.set_filter("");
    assert_eq!(g.payload(CopyMode::Range).unwrap().source_rows, [0]);
    g.pointer(0, 0, false, false, false);
    assert_eq!(
        g.payload(CopyMode::Rows).unwrap().source_rows,
        [g.visible_rows[0]]
    );
}

#[test]
fn same_navigation_refresh_reconciles_unique_keys_not_row_positions_and_retains_widths() {
    let mut g = grid(fixture(), Some(0), 1, true);
    g.result.columns[0].width = 417.;
    g.result.columns[1].width = 211.;
    g.pointer(0, 2, false, false, false);
    let id = g.selection.focus.unwrap().row;
    let mut changed = fixture();
    changed.rows.reverse();
    changed.rows[3][1] = Some("a changed value on the same primary key".into());
    g.replace(grid(changed, Some(0), 2, true));
    assert_eq!(g.snapshot, 2);
    assert_eq!(g.result.columns[0].width, 417.);
    assert_eq!(g.result.columns[1].width, 211.);
    assert_eq!(g.selection.focus.unwrap().row, id);
    assert_eq!(g.selected_sources(), [3]);
    assert_eq!(
        g.payload(CopyMode::Cell).unwrap().values[0][0]
            .value
            .as_deref(),
        Some("a changed value on the same primary key")
    );
    let mut no_identity = fixture();
    no_identity.rows[0][0] = Some("different primary key".into());
    g.replace(grid(no_identity, Some(0), 3, true));
    assert!(g.payload(CopyMode::Range).is_none());
}

#[test]
fn no_key_refresh_matches_only_unique_exact_rows_and_new_page_or_schema_invalidates_selection() {
    let mut g = grid(fixture(), Some(0), 1, false);
    g.pointer(3, 3, false, false, false);
    let id = g.selection.focus.unwrap().row;
    let mut shuffled = fixture();
    shuffled.rows.rotate_right(1);
    g.replace(grid(shuffled.clone(), Some(0), 2, false));
    assert_eq!(g.selected_sources(), [0]);
    assert_eq!(g.selection.focus.unwrap().row, id);
    shuffled.rows.push(shuffled.rows[0].clone());
    g.replace(grid(shuffled, Some(0), 3, false));
    assert!(g.payload(CopyMode::Range).is_none());
    g.pointer(0, 1, false, false, false);
    g.replace(grid(fixture(), Some(1), 4, false));
    assert!(g.selection.rows.is_empty());
    g.pointer(0, 1, false, false, false);
    let mut incompatible = fixture();
    incompatible.columns[0].native_type = "text".into();
    g.replace(grid(incompatible, Some(1), 5, false));
    assert!(g.selection.rows.is_empty());
    assert_eq!(g.result.columns[0].width, 140.);
}

#[test]
fn new_result_presentation_can_inherit_widths_but_never_original_ids_or_selection() {
    let mut first = grid(fixture(), None, 10, false);
    first.result.columns[0].width = 512.;
    first.pointer(1, 1, false, false, false);
    let mut other = grid(fixture(), None, 11, false);
    other.inherit_presentation(&first);
    assert_eq!(other.result.columns[0].width, 512.);
    assert!(other.selection.rows.is_empty());
    first.replace(other);
    assert!(first.selection.rows.is_empty());
}

#[test]
fn raw_postgres_hex_empty_binary_null_collision_and_large_strings_are_lossless() {
    let mut set = fixture();
    set.columns[2].encoding = None;
    set.rows[0][2] = Some("\\x000102ff".into());
    set.rows[1][2] = Some("\\x".into());
    let mut g = grid(set, None, 1, false);
    g.pointer(0, 3, false, false, false);
    g.pointer(2, 3, true, false, false);
    let payload = g.payload(CopyMode::Range).unwrap();
    assert_eq!(payload.columns[0].encoding.as_deref(), Some("base64"));
    assert_eq!(payload.values[0][0].value.as_deref(), Some("AAEC/w=="));
    assert_eq!(payload.values[1][0].value.as_deref(), Some(""));
    assert_eq!(payload.prepare().unwrap().text, "AAEC/w==\n\"\"\n\\N");
    assert_eq!(
        Value {
            kind: "text".into(),
            value: Some("\\N".into())
        }
        .tsv(),
        "\"\\N\""
    );
    let huge = "synthetic\n".repeat(80_000);
    assert!(cell_preview(&Cell::Text(huge.clone())).chars().count() <= 259);
    assert_eq!(
        Value::original(&g.original.columns[1], &Some(huge.clone())).value,
        Some(huge)
    );
}

#[test]
fn bounded_large_grid_selection_touches_only_selected_source_rows() {
    let mut set = fixture();
    set.rows = (0..1000)
        .map(|r| {
            vec![
                Some(r.to_string()),
                Some(format!("row-{r}")),
                Some(String::new()),
            ]
        })
        .collect();
    let mut g = grid(set, None, 1, false);
    g.pointer(997, 2, false, false, false);
    g.pointer(999, 3, true, false, false);
    let payload = g.payload(CopyMode::Range).unwrap();
    assert_eq!(payload.source_rows, [997, 998, 999]);
    assert_eq!(payload.values.len(), 3);
    assert_eq!(payload.values[0].len(), 2);
    assert!(!payload.prepare().unwrap().text.contains("row-996"));
}

#[cfg(feature = "native-smoke")]
mod headless {
    use super::*;
    use gpui_kit::test::TestWindowExt;
    use gpui_kit::{AppContext, Focusable, TestAppContext};

    #[gpui_kit::test]
    fn retained_result_entities_widths_selection_details_and_focused_field_copy(
        cx: &mut TestAppContext,
    ) {
        let (window, view) = crate::workspace_tests::workspace(cx);
        cx.update_window(window, |_, window, cx| {
            crate::commands::install_keys(cx);
            let first = view.update(cx, |workspace, cx| {
                let id = workspace.tabs[0].id;
                workspace.tabs[0].result_sets = vec![fixture(), fixture()];
                workspace.render_live_result(id, window, cx);
                workspace.tabs[0].grid.clone().unwrap()
            });
            window.render_frame(cx);
            first.focus_handle(cx).focus(window, cx);
            let first_source_row = first.read(cx).delegate().row_ids[0];
            let cell_id = first.update(cx, |table, cx| {
                let cell = table.delegate().accessible_container(
                    crate::accessibility::NodePart::Cell,
                    0,
                    1,
                    cx,
                );
                gpui_kit::Element::id(&cell)
                    .expect("The retained data cell has a native element ID")
            });
            window.click(cell_id, cx);
            assert_eq!(
                first.read(cx).delegate().selection.focus,
                Some(crate::grid_selection::CellPoint {
                    row: first_source_row,
                    column: 0
                })
            );
            assert!(first.focus_handle(cx).is_focused(window));
            window.press("shift-right", cx);
            assert_eq!(
                first
                    .read(cx)
                    .delegate()
                    .payload(CopyMode::Range)
                    .unwrap()
                    .source_column_indices,
                [0, 1]
            );
            window.press("space", cx);
            assert!(first.read(cx).delegate().details_open);
            assert_eq!(
                first.read(cx).delegate().details_row,
                Some(first.read(cx).delegate().row_ids[0])
            );
            let field = first.read(cx).delegate().details[1].clone();
            field.update(cx, |state, cx| {
                state.focus(window, cx);
                state.set_selected_range(0..0, cx);
            });
            let focus = view.update(cx, |workspace, cx| {
                workspace
                    .command_context(crate::commands::CommandId::Copy, None, window, cx)
                    .focus
            });
            assert_eq!(focus, crate::commands::CommandFocus::TextInput);
            let original = first.read(cx).delegate().selection.clone();
            view.update(cx, |workspace, cx| {
                workspace.cycle_result(window, cx);
            });
            let second = view.read(cx).tabs[0].grid.clone().unwrap();
            assert_ne!(first.entity_id(), second.entity_id());
            assert!(!second.read(cx).delegate().has_selection());
            view.update(cx, |workspace, cx| {
                workspace.cycle_result(window, cx);
            });
            assert_eq!(
                view.read(cx).tabs[0].grid.as_ref().unwrap().entity_id(),
                first.entity_id()
            );
            assert_eq!(first.read(cx).delegate().selection, original);
        })
        .unwrap();
    }

    #[gpui_kit::test]
    fn captured_selection_refuses_replaced_snapshot_and_new_operation(cx: &mut TestAppContext) {
        let (window, view) = crate::workspace_tests::workspace(cx);
        cx.update_window(window, |_, window, cx| {
            view.update(cx, |workspace, cx| {
                let id = workspace.tabs[0].id;
                workspace.tabs[0].result_sets = vec![fixture()];
                workspace.render_live_result(id, window, cx);
                let table = workspace.tabs[0].grid.clone().unwrap();
                table.update(cx, |table, _| {
                    table.delegate_mut().pointer(0, 1, false, false, false)
                });
                let capture = workspace
                    .capture_command(
                        crate::commands::CommandId::GridCopy,
                        crate::commands::CommandOrigin::Button,
                        None,
                        window,
                        cx,
                    )
                    .unwrap();
                assert!(workspace.capture_valid(&capture, cx));
                table.update(cx, |table, _| table.delegate_mut().snapshot += 1);
                assert!(!workspace.capture_valid(&capture, cx));
                // No native clipboard publication is executed in this ownership test.
            });
        })
        .unwrap();
    }
}
