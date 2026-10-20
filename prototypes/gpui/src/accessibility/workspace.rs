//! Production semantics on the original retained table and editor owners.
//! No capture, value or action payload implements diagnostic serialization.
use super::*;
use crate::{
    backend, changes_view, grid_selection::CellPoint, model::DocumentId, results::ResultGrid,
    workspace::Workspace,
};
use base64::Engine as _;
use gpui_kit::{
    App, AppContext, Context, Div, Entity, FocusHandle, Focusable, InteractiveElement, Role,
    Stateful, StatefulInteractiveElement, WeakEntity, Window, accesskit,
    component::{WindowExt, table::TableState},
    div,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    ops::Range,
    rc::Rc,
};

#[derive(Clone)]
pub(crate) struct WorkspaceGridOwner {
    pub workspace: WeakEntity<Workspace>,
    pub document: DocumentId,
    pub source: u64,
    pub result: (u64, usize),
    focus: FocusHandle,
}
impl Workspace {
    pub(crate) fn prepare_native_owners(&self, cx: &mut Context<Self>) {
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
        let Some(grid) = &tab.grid else { return };
        let result = tab
            .grid_views
            .iter()
            .find_map(|(key, value)| (value == grid).then_some(*key))
            .unwrap_or((
                tab.executions.first().map_or(0, |e| e.operation),
                tab.selected_result,
            ));
        let owner = WorkspaceGridOwner {
            workspace: cx.entity().downgrade(),
            document: tab.id,
            source: tab.generation,
            result,
            // The table is borrowed during delegate rendering. Capture its
            // stable focus handle before entering any TableState update.
            focus: grid.focus_handle(cx),
        };
        grid.update(cx, |table, _| {
            table.delegate_mut().accessibility_owner = Some(owner);
        });
    }
}
impl ResultGrid {
    pub(crate) fn invalidate_accessibility(&mut self) {
        self.accessibility.borrow_mut().invalidate();
        self.accessibility_revision = self.accessibility_revision.checked_add(1).unwrap_or(0);
    }
    fn native_key(&self, part: NodePart, row: usize, column: usize) -> NodeKey {
        let owner = self.accessibility_owner.as_ref();
        NodeKey {
            document: owner.map_or(0, |o| u128::from(o.document.0)),
            surface: 2,
            part,
            instance: owner.map_or(0, |o| o.result.1 as u64),
            item: if matches!(part, NodePart::Row | NodePart::Cell) {
                self.visible_rows
                    .get(row)
                    .and_then(|&r| self.row_ids.get(r))
                    .copied()
                    .unwrap_or(0)
            } else {
                0
            },
            column: if matches!(part, NodePart::Grid | NodePart::Row) {
                0
            } else if column == 0 {
                u32::MAX
            } else {
                (column - 1) as u32
            },
        }
    }
    pub(crate) fn publish_accessibility(
        &mut self,
        rows: Range<usize>,
        columns: Range<usize>,
        window: &mut Window,
        _cx: &mut Context<TableState<Self>>,
    ) {
        let Some(owner) = &self.accessibility_owner else {
            return;
        };
        if self.accessibility_revision == 0 || !self.context_valid {
            return;
        }
        let column_count = self.original.columns.len() + 1;
        let rows = rows.start.min(self.row_count())..rows.end.min(self.row_count());
        let columns = columns.start.min(column_count)..columns.end.min(column_count);
        let cols: Vec<_> = columns
            .clone()
            .map(|column| Column {
                ordinal: if column == 0 {
                    u32::MAX
                } else {
                    (column - 1) as u32
                },
                visual_index: column,
                name: if column == 0 {
                    "Row number".into()
                } else {
                    self.original.columns[column - 1].name.clone()
                },
            })
            .collect();
        let mut values = Vec::new();
        for row in rows.clone() {
            let source = self.visible_rows[row];
            let cells = columns
                .clone()
                .map(|column| {
                    let value = if column == 0 {
                        Value::Text((row + 1).to_string())
                    } else {
                        let value = self
                            .draft
                            .as_ref()
                            .and_then(|d| d.rows.get(source))
                            .and_then(|r| r.values.get(column - 1));
                        match value {
                            Some(backend::CellValue::Null) => Value::Null,
                            Some(backend::CellValue::Default) => Value::Default,
                            Some(backend::CellValue::Binary(v)) => binary(v),
                            Some(backend::CellValue::Text(v)) => text(v),
                            None => match self
                                .original
                                .rows
                                .get(source)
                                .and_then(|r| r.get(column - 1))
                                .and_then(Option::as_ref)
                            {
                                None => Value::Null,
                                Some(v)
                                    if self.original.columns[column - 1].encoding.as_deref()
                                        == Some("base64") =>
                                {
                                    binary(v)
                                }
                                Some(v) => text(v),
                            },
                        }
                    };
                    (
                        if column == 0 {
                            u32::MAX
                        } else {
                            (column - 1) as u32
                        },
                        value,
                    )
                })
                .collect::<BTreeMap<_, _>>();
            values.push(RealizedRow {
                source_id: self.row_ids[source],
                visual_index: row,
                cells,
            });
        }
        // Capture only realized selection membership; offscreen totals come
        // from the original retained selection, never an expanded cell product.
        let realized_ids: BTreeSet<_> = values.iter().map(|r| r.source_id).collect();
        let selected_columns = self.selection.columns.as_ref();
        let selection = GridSelection {
            full_rows: if self.selection.whole_rows {
                realized_ids
                    .intersection(&self.selection.rows)
                    .copied()
                    .collect()
            } else {
                BTreeSet::new()
            },
            sparse_cells: if self.selection.whole_rows {
                BTreeSet::new()
            } else {
                realized_ids
                    .iter()
                    .filter(|row| self.selection.rows.contains(row))
                    .flat_map(|row| {
                        cols.iter()
                            .filter(move |c| {
                                c.ordinal != u32::MAX
                                    && selected_columns
                                        .is_some_and(|range| range.contains(&(c.ordinal as usize)))
                            })
                            .map(move |c| (*row, c.ordinal))
                    })
                    .collect()
            },
            active_cell: self.selection.focus.map(|p| (p.row, p.column as u32)),
            summary: Some(SelectionSummary {
                full_rows: if self.selection.whole_rows {
                    self.selection.rows.len()
                } else {
                    0
                },
                sparse_cells: if self.selection.whole_rows {
                    0
                } else {
                    self.selection.rows.len().saturating_mul(
                        self.selection
                            .columns
                            .as_ref()
                            .map_or(0, |r| r.clone().count()),
                    )
                },
            }),
        };
        // The remaining real cells retain their semantic readonly projection;
        // root navigation and bounded captured actions remain available.
        values.truncate(MAX_NODES.saturating_sub(cols.len() + 1) / (cols.len() + 1));
        let key = self.native_key(NodePart::Grid, 0, 0);
        let capture = Capture {
            document: u128::from(owner.document.0),
            result: owner.result.0,
            snapshot: self.snapshot,
            revision: self.accessibility_revision,
            owner: owner.source,
        };
        let input = GridCapture {
            key,
            capture,
            name: "Loaded results".into(),
            viewport: Viewport {
                first_row: rows.start,
                end_row: rows.end,
                total_rows: self.row_count(),
                first_column: columns.start,
                end_column: columns.end,
                total_columns: column_count,
            },
            columns: cols,
            rows: values,
            selection,
            read_only: !self.readonly_reason.is_empty(),
            owns_keyboard_focus: owner.focus.is_focused(window),
        };
        if let Ok(mut nodes) = grid_nodes(input) {
            // Preserve the rest of the UI if a single value exceeds native text
            // limits. Exact data stays in its original selectable inspector.
            let mut remaining = MAX_VALUE_BYTES / 2;
            for node in &mut nodes {
                if let Some(value) = &node.value {
                    let bytes = value.text().len();
                    if bytes > remaining {
                        node.description = format!(
                            "{}; {} UTF-8 bytes. Open Row Details for the exact value; native grid value exceeds its bounded text budget.",
                            value.kind_description(),
                            bytes
                        );
                        node.value = None;
                    } else {
                        remaining -= bytes;
                    }
                }
            }
            _ = self.accessibility.borrow_mut().publish(nodes, None);
        }
    }
    pub(crate) fn accessible_container(
        &self,
        part: NodePart,
        row: usize,
        column: usize,
        cx: &Context<TableState<Self>>,
    ) -> Stateful<Div> {
        let key = self.native_key(part, row, column);
        let weak = cx.entity().downgrade();
        let handler: NativeActionHandler = Rc::new(move |binding, action, _, window, cx| {
            let Some(grid) = weak.upgrade() else { return };
            native_action(&grid, binding, action, window, cx);
        });
        container(&self.accessibility, key, handler).unwrap_or_else(|| {
            // A just-realized slice gets its capture next frame. No stale action
            // is attached during this bounded transition.
            let id = format!("dbeer-{}-{}-{:?}-{}-{}-{}-{}-{}", key.document, key.surface, key.part, key.instance, key.item, key.column,
                self.accessibility_owner.as_ref().map_or(0, |o| o.result.0), self.snapshot);
            let root = div().id(id.clone()).accessibility_id(id);
            match part {
                NodePart::Grid => root.role(Role::Grid).aria_label("Loaded results").aria_row_count(self.row_count()).aria_column_count(self.original.columns.len() + 1),
                NodePart::Row => root.role(Role::Row).aria_label(format!("Row {}", row + 1)).aria_row_index(row).aria_row_count(self.row_count()).aria_selected(self.selection.whole_rows && self.selected(row, 0)),
                NodePart::Header => root.role(Role::ColumnHeader).aria_label(if column == 0 { "Row number".to_owned() } else { self.original.columns.get(column - 1).map_or_else(String::new, |c| c.name.clone()) }).aria_column_index(column),
                NodePart::Cell => {
                    let root = root.role(Role::GridCell).aria_row_index(row).aria_column_index(column).aria_selected(self.selected(row, column));
                    if column == 0 { root.aria_label("Row number").aria_value((row + 1).to_string()) } else {
                        let value = self.visible_rows.get(row).and_then(|&r| self.draft.as_ref()?.rows.get(r)).and_then(|r| r.values.get(column - 1)).map(|v| match v {
                            backend::CellValue::Null => Value::Null, backend::CellValue::Default => Value::Default, backend::CellValue::Text(v) => text(v), backend::CellValue::Binary(v) => binary(v),
                        }).unwrap_or_else(|| self.visible_rows.get(row).and_then(|&r| self.original.rows.get(r)).and_then(|r| r.get(column - 1)).and_then(Option::as_ref).map_or(Value::Null, |v| if self.original.columns[column - 1].encoding.as_deref() == Some("base64") { binary(v) } else { text(v) }));
                        let root = root.aria_label(self.original.columns.get(column - 1).map_or_else(String::new, |c| c.name.clone()));
                        if value.text().len() <= MAX_VALUE_BYTES { root.aria_description(value.kind_description()).aria_value(value.text().to_owned()) }
                        else { root.aria_description(format!("{}; value exceeds the native text limit. Open Row Details for the exact value.", value.kind_description())) }
                    }
                }
                _ => root,
            }
        })
    }
}
fn text(v: &str) -> Value {
    if v.is_empty() {
        Value::Empty
    } else {
        Value::Text(v.to_owned())
    }
}
fn binary(v: &str) -> Value {
    Value::Binary {
        base64: v.to_owned(),
        byte_count: base64::engine::general_purpose::STANDARD
            .decode(v)
            .map_or(0, |v| v.len()),
    }
}
fn native_action(
    grid: &Entity<TableState<ResultGrid>>,
    binding: Binding,
    action: accesskit::Action,
    window: &mut Window,
    cx: &mut App,
) {
    let modal = window.has_active_dialog(cx) || window.has_active_prompt();
    let g = grid.read(cx).delegate();
    if !g.accessibility.borrow().accepts(binding, action, None) {
        return;
    }
    let Some(owner) = g.accessibility_owner.clone() else {
        return;
    };
    let Some(workspace) = owner.workspace.upgrade() else {
        return;
    };
    let w = workspace.read(cx);
    let live = w.tabs.get(w.active).is_some_and(|t| {
        t.id == owner.document
            && t.generation == owner.source
            && t.grid.as_ref() == Some(grid)
            && (t.grid_views.is_empty() || t.grid_views.get(&owner.result) == Some(grid))
    });
    if !live
        || w.closing
        || modal
        || !g.context_valid
        || binding.capture.result != owner.result.0
        || binding.capture.snapshot != g.snapshot
        || binding.capture.revision != g.accessibility_revision
        || binding.capture.owner != owner.source
    {
        return;
    }
    let row = g
        .visible_rows
        .iter()
        .position(|&r| g.row_ids[r] == binding.key.item);
    let column = if binding.key.column == u32::MAX {
        0
    } else {
        binding.key.column as usize + 1
    };
    // Row-number cells select whole rows and open details; they are not an
    // alias for data column zero's typed editor.
    let edit = if column > 0 && g.readonly_reason.is_empty() {
        g.edit_capture(grid.clone())
    } else {
        None
    };
    let menu = g.context_menu_handle.clone();
    let point = row.map(|_| CellPoint {
        row: binding.key.item,
        column: column.saturating_sub(1),
    });
    let focus = grid.focus_handle(cx);
    grid.update(cx, |table, cx| {
        table.delegate_mut().invalidate_accessibility();
        focus.focus(window, cx);
        if let Some(row) = row {
            table
                .delegate_mut()
                .pointer(row, column, false, false, column == 0);
            table.scroll_to_row(row, cx);
            table.scroll_to_col(column, cx);
            table.delegate_mut().context_cell = point;
            table.set_right_clicked_row(Some(row), cx);
            table.delegate_mut().sync_details(window, cx);
        }
        cx.notify();
    });
    match action {
        accesskit::Action::Click if binding.key.part == NodePart::Cell => {
            if let (Some(capture), Some(point)) = (edit, point) {
                workspace.update(cx, |w, cx| {
                    w.changes_action(
                        capture,
                        changes_view::Action::Edit(false),
                        Some(point),
                        window,
                        cx,
                    )
                });
            } else {
                grid.update(cx, |table, cx| {
                    table.delegate_mut().details_open = true;
                    table.delegate_mut().sync_details(window, cx);
                    cx.notify();
                });
            }
        }
        accesskit::Action::ShowContextMenu => menu.open(window, cx),
        accesskit::Action::ScrollUp
        | accesskit::Action::ScrollDown
        | accesskit::Action::ScrollLeft
        | accesskit::Action::ScrollRight => {
            crate::results::interaction::navigate_native(grid, action, window, cx);
        }
        _ => {}
    }
}

#[cfg(all(test, feature = "native-smoke"))]
mod tests {
    use super::*;
    use gpui_kit::test::TestWindowExt;
    use gpui_kit::{AnyWindowHandle, Element, TestAppContext};
    fn retained_grid(
        cx: &mut TestAppContext,
    ) -> (
        AnyWindowHandle,
        Entity<Workspace>,
        Entity<TableState<ResultGrid>>,
    ) {
        let (handle, workspace) = crate::workspace_tests::workspace(cx);
        let grid = cx
            .update_window(handle, |_, window, cx| {
                let grid = cx.new(|cx| {
                    let columns = (0..5)
                        .map(|_| crate::demo::Column {
                            name: "duplicate".into(),
                            data_type: "text".into(),
                            width: 140.,
                        })
                        .collect();
                    let rows = (0..200)
                        .map(|_| {
                            vec![
                                crate::demo::Cell::Null,
                                crate::demo::Cell::Text(String::new()),
                                crate::demo::Cell::Text("NULL".into()),
                                crate::demo::Cell::Number("9007199254740993.0001".into()),
                                crate::demo::Cell::Binary("AAEC".into()),
                            ]
                        })
                        .collect();
                    let mut grid = ResultGrid::new(crate::demo::QueryResult { columns, rows });
                    grid.original.columns[4].encoding = Some("base64".into());
                    TableState::new(grid, window, cx)
                        .cell_selectable(false)
                        .row_selectable(false)
                        .row_header(false)
                });
                workspace.update(cx, |w, cx| {
                    let tab = &mut w.tabs[0];
                    tab.grid = Some(grid.clone());
                    tab.grid_views.insert((70, 0), grid.clone());
                    w.prepare_native_owners(cx);
                });
                grid
            })
            .unwrap();
        (handle, workspace, grid)
    }
    fn capture(
        grid: &Entity<TableState<ResultGrid>>,
        row: usize,
        column: usize,
        window: &mut Window,
        cx: &mut App,
    ) -> Binding {
        grid.update(cx, |table, cx| {
            let g = table.delegate_mut();
            g.publish_accessibility(row..row + 1, 0..6, window, cx);
            let key = g.native_key(NodePart::Cell, row, column);
            g.accessibility.borrow().binding(key).unwrap().0
        })
    }
    #[gpui_kit::test]
    fn actual_grid_wrappers_publish_typed_values_original_ids_and_virtual_positions(
        cx: &mut TestAppContext,
    ) {
        let (handle, _, grid) = retained_grid(cx);
        cx.update_window(handle, |_, window, cx| {
            grid.update(cx, |table, cx| {
                let g = table.delegate_mut();
                g.pointer(100, 1, false, false, false);
                g.pointer(100, 5, true, false, false);
                g.publish_accessibility(100..101, 0..6, window, cx);
                let root = g.native_key(NodePart::Grid, 0, 0);
                let (_, root_node) = g.accessibility.borrow().binding(root).unwrap();
                assert_eq!(root_node.grid.row_count, Some(200));
                assert_eq!(root_node.selection.unwrap().sparse_cells, 5);
                let kinds = (1..6)
                    .map(|column| {
                        let key = g.native_key(NodePart::Cell, 100, column);
                        let (_, node) = g.accessibility.borrow().binding(key).unwrap();
                        assert_eq!(node.key.item, 101);
                        assert_eq!(node.grid.row_index, Some(100));
                        let element = g.accessible_container(NodePart::Cell, 100, column, cx);
                        let mut native = accesskit::Node::new(element.a11y_role().unwrap());
                        element.write_a11y_info(&mut native);
                        assert_eq!(native.author_id(), Some(node.native_id().as_str()));
                        assert_eq!(native.value(), Some(node.value.as_ref().unwrap().text()));
                        assert!(!native.supports_action(accesskit::Action::SetValue));
                        node.value.unwrap().kind_description()
                    })
                    .collect::<Vec<_>>();
                assert_eq!(kinds[0], "SQL NULL");
                assert_eq!(kinds[1], "Empty string");
                assert_eq!(kinds[2], "Text value");
                assert_eq!(kinds[4], "Binary value; 3 bytes; Base64");
            });
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn bounded_capture_retains_default_and_offscreen_selection_totals_without_erasing_other_cells(
        cx: &mut TestAppContext,
    ) {
        let (handle, _, grid) = retained_grid(cx);
        cx.update_window(handle, |_, window, cx| {
            grid.update(cx, |table, cx| {
                let g = table.delegate_mut();
                let metadata = g
                    .original
                    .columns
                    .iter()
                    .map(|c| backend::TableColumnMetadata {
                        name: c.name.clone(),
                        native_type: c.native_type.clone(),
                        nullable: true,
                        default: None,
                        generated: String::new(),
                        primary_key: 0,
                        editable: true,
                        edit_reason: String::new(),
                    })
                    .collect();
                g.draft =
                    crate::grid_changes::Draft::new(&g.original, metadata, g.snapshot, &g.row_ids);
                let draft = g.draft.as_mut().unwrap();
                draft.rows[0].values[0] = backend::CellValue::Default;
                draft.rows[0].values[1] = backend::CellValue::Text("x".repeat(MAX_VALUE_BYTES + 1));
                g.pointer(0, 1, false, false, false);
                g.pointer(199, 5, true, false, false);
                g.publish_accessibility(0..1, 0..6, window, cx);
                let tree = g.accessibility.borrow();
                let root = tree.binding(g.native_key(NodePart::Grid, 0, 0)).unwrap().1;
                assert_eq!(root.selection.unwrap().sparse_cells, 1000);
                let default = tree.binding(g.native_key(NodePart::Cell, 0, 1)).unwrap().1;
                assert!(default.value == Some(Value::Default));
                let large = tree.binding(g.native_key(NodePart::Cell, 0, 2)).unwrap().1;
                assert!(large.value.is_none());
                assert!(large.description.contains("native grid value exceeds"));
                let exact = tree.binding(g.native_key(NodePart::Cell, 0, 4)).unwrap().1;
                assert_eq!(exact.value.unwrap().text(), "9007199254740993.0001");
            });
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn native_cell_action_uses_original_focus_selection_and_details_without_database_work(
        cx: &mut TestAppContext,
    ) {
        let (handle, workspace, grid) = retained_grid(cx);
        cx.update_window(handle, |_, window, cx| {
            let binding = capture(&grid, 100, 4, window, cx);
            native_action(&grid, binding, accesskit::Action::Click, window, cx);
            let g = grid.read(cx).delegate();
            assert_eq!(
                g.selection.focus,
                Some(CellPoint {
                    row: 101,
                    column: 3
                })
            );
            assert!(g.details_open);
            assert!(grid.focus_handle(cx).is_focused(window));
            let retained_focus = grid.focus_handle(cx);
            let other_focus = cx.focus_handle();
            for focused in [true, false, true] {
                if focused {
                    retained_focus.focus(window, cx);
                } else {
                    other_focus.focus(window, cx);
                }
                let current = capture(&grid, 100, 4, window, cx);
                let g = grid.read(cx).delegate();
                let tree = g.accessibility.borrow();
                let cell = tree.binding(current.key).unwrap().1;
                assert_eq!(cell.active_descendant, focused);
                assert_eq!(
                    g.selection.focus,
                    Some(CellPoint {
                        row: 101,
                        column: 3
                    })
                );
            }
            assert!(workspace.read(cx).tabs[0].operation.is_none());
            assert!(workspace.read(cx).backend.is_none());
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn stale_source_snapshot_selection_and_modal_actions_cannot_select_a_new_owner(
        cx: &mut TestAppContext,
    ) {
        let (handle, workspace, grid) = retained_grid(cx);
        cx.update_window(handle, |_, window, cx| {
            let old = capture(&grid, 100, 1, window, cx);
            grid.update(cx, |table, _| {
                table.delegate_mut().pointer(2, 3, false, false, false)
            });
            native_action(&grid, old, accesskit::Action::Click, window, cx);
            assert_eq!(grid.read(cx).delegate().selection.focus.unwrap().row, 3);
            let old = capture(&grid, 100, 1, window, cx);
            workspace.update(cx, |w, _| w.tabs[0].generation += 1);
            native_action(&grid, old, accesskit::Action::Click, window, cx);
            assert_eq!(grid.read(cx).delegate().selection.focus.unwrap().row, 3);
            workspace.update(cx, |w, cx| w.prepare_native_owners(cx));
            let old = capture(&grid, 100, 1, window, cx);
            Workspace::information("Owned modal", window, cx);
            native_action(&grid, old, accesskit::Action::Click, window, cx);
            assert_eq!(grid.read(cx).delegate().selection.focus.unwrap().row, 3);
            window.close_dialog(cx);
            let old = capture(&grid, 100, 1, window, cx);
            grid.update(cx, |table, _| table.delegate_mut().snapshot += 1);
            native_action(&grid, old, accesskit::Action::Click, window, cx);
            assert_eq!(grid.read(cx).delegate().selection.focus.unwrap().row, 3);
        })
        .unwrap();
    }
    #[gpui_kit::test]
    fn tab_traversal_and_context_menu_use_the_retained_grid_owner(cx: &mut TestAppContext) {
        let (handle, workspace, grid) = retained_grid(cx);
        cx.update_window(handle, |_, window, cx| {
            crate::commands::install_keys(cx);
            window.render_frame(cx);
            grid.focus_handle(cx).focus(window, cx);
            grid.update(cx, |table, _| {
                table.delegate_mut().pointer(0, 1, false, false, false)
            });
            window.render_frame(cx);
            window.press("shift-f10", cx);
        })
        .unwrap();
        // The production context menu builds and takes focus in window.defer.
        // Complete that callback before checking the retained focus owner.
        cx.run_until_parked();
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            assert!(!grid.focus_handle(cx).is_focused(window));
            window.press("escape", cx);
        })
        .unwrap();
        cx.run_until_parked();
        cx.update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            assert!(grid.focus_handle(cx).is_focused(window));
            window.press("tab", cx);
        })
        .unwrap();
        cx.run_until_parked();
        cx.update_window(handle, |_, window, cx| {
            assert!(!grid.focus_handle(cx).is_focused(window));
            window.press("shift-tab", cx);
        })
        .unwrap();
        cx.run_until_parked();
        cx.update_window(handle, |_, window, cx| {
            assert!(grid.focus_handle(cx).is_focused(window));
            assert_eq!(
                grid.read(cx).delegate().selection.focus,
                Some(CellPoint { row: 1, column: 0 })
            );
            assert!(workspace.read(cx).backend.is_none());
            assert!(workspace.read(cx).tabs[0].operation.is_none());
        })
        .unwrap();
    }
}
