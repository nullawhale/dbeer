use super::{
    Capture, GridMetadata, MAX_NODES, NodeKey, NodePart, SelectionSummary, SemanticNode, TreeError,
    Value, Viewport,
};
use gpui_kit::accesskit::{Action, Role};
use std::collections::{BTreeMap, BTreeSet};

/// Original column ordinal and current visual position are intentionally
/// separate, including duplicate column names and reordered/hidden columns.
pub(crate) struct Column {
    pub ordinal: u32,
    pub visual_index: usize,
    pub name: String,
}
pub(crate) struct RealizedRow {
    pub source_id: u64,
    pub visual_index: usize,
    pub cells: BTreeMap<u32, Value>,
}
#[derive(Default)]
pub(crate) struct GridSelection {
    pub full_rows: BTreeSet<u64>,
    pub sparse_cells: BTreeSet<(u64, u32)>,
    pub active_cell: Option<(u64, u32)>,
    /// Total counts from retained selection, without expanding offscreen cells.
    pub summary: Option<SelectionSummary>,
}
/// Contains only the already-realized slice; no database fetch or grid mutation
/// occurs while building accessibility state. Values have no Debug/Serialize.
pub(crate) struct GridCapture {
    pub key: NodeKey,
    pub capture: Capture,
    pub name: String,
    pub viewport: Viewport,
    pub columns: Vec<Column>,
    pub rows: Vec<RealizedRow>,
    pub selection: GridSelection,
    pub read_only: bool,
    pub owns_keyboard_focus: bool,
}
fn base(
    key: NodeKey,
    capture: Capture,
    parent: Option<NodeKey>,
    role: Role,
    name: String,
) -> SemanticNode {
    SemanticNode {
        key,
        capture,
        parent,
        role,
        name,
        description: String::new(),
        value: None,
        grid: GridMetadata::default(),
        viewport: None,
        selection: None,
        selected: None,
        read_only: true,
        disabled: false,
        multiselectable: false,
        active_descendant: false,
        actions: vec![],
    }
}
/// Table -> Row -> GridCell plus ColumnHeader native hierarchy. The returned
/// nodes must decorate the exact corresponding rendered wrappers (container)
/// under the same hierarchy, not merely be published as an inspectable model.
/// Scroll actions on the grid use the retained viewport/key-navigation route;
/// Focus/Click/context on cells use original source row/column identity.
pub(crate) fn grid_nodes(input: GridCapture) -> Result<Vec<SemanticNode>, TreeError> {
    let viewport = input.viewport;
    if input.key.part != NodePart::Grid
        || !viewport.valid()
        || input.capture.document != input.key.document
    {
        return Err(TreeError::InvalidGrid);
    }
    let expected = 1usize.saturating_add(input.columns.len()).saturating_add(
        input
            .rows
            .len()
            .saturating_mul(input.columns.len().saturating_add(1)),
    );
    if expected > MAX_NODES {
        return Err(TreeError::TooManyNodes);
    }
    let mut ordinals = BTreeSet::new();
    let mut visual_columns = BTreeSet::new();
    for column in &input.columns {
        if !ordinals.insert(column.ordinal)
            || !visual_columns.insert(column.visual_index)
            || column.visual_index < viewport.first_column
            || column.visual_index >= viewport.end_column
        {
            return Err(TreeError::InvalidGrid);
        }
    }
    let mut row_ids = BTreeSet::new();
    let mut visual_rows = BTreeSet::new();
    for row in &input.rows {
        if !row_ids.insert(row.source_id)
            || !visual_rows.insert(row.visual_index)
            || row.visual_index < viewport.first_row
            || row.visual_index >= viewport.end_row
            || !ordinals
                .iter()
                .all(|ordinal| row.cells.contains_key(ordinal))
        {
            return Err(TreeError::InvalidGrid);
        }
    }
    let mut table = base(input.key, input.capture, None, Role::Grid, input.name);
    table.grid.row_count = Some(viewport.total_rows);
    table.grid.column_count = Some(viewport.total_columns);
    table.viewport = Some(viewport);
    table.selection = Some(input.selection.summary.unwrap_or_else(|| {
        SelectionSummary {
            full_rows: input.selection.full_rows.len(),
            sparse_cells: input
                .selection
                .sparse_cells
                .iter()
                .filter(|(row, _)| !input.selection.full_rows.contains(row))
                .count(),
        }
    }));
    table.read_only = input.read_only;
    table.multiselectable = true;
    table.actions = vec![
        Action::Focus,
        Action::ScrollUp,
        Action::ScrollDown,
        Action::ScrollLeft,
        Action::ScrollRight,
        Action::ShowContextMenu,
    ];
    let mut nodes = vec![table];
    for column in &input.columns {
        let key = NodeKey {
            part: NodePart::Header,
            item: 0,
            column: column.ordinal,
            ..input.key
        };
        let mut header = base(
            key,
            input.capture,
            Some(input.key),
            Role::ColumnHeader,
            column.name.clone(),
        );
        header.grid.column_index = Some(column.visual_index);
        header.grid.column_count = Some(viewport.total_columns);
        nodes.push(header);
    }
    for row in input.rows {
        let row_key = NodeKey {
            part: NodePart::Row,
            item: row.source_id,
            column: 0,
            ..input.key
        };
        let mut row_node = base(
            row_key,
            input.capture,
            Some(input.key),
            Role::Row,
            format!("Row {}", row.visual_index.saturating_add(1)),
        );
        row_node.grid.row_index = Some(row.visual_index);
        row_node.grid.row_count = Some(viewport.total_rows);
        row_node.selected = Some(input.selection.full_rows.contains(&row.source_id));
        nodes.push(row_node);
        for column in &input.columns {
            let key = NodeKey {
                part: NodePart::Cell,
                item: row.source_id,
                column: column.ordinal,
                ..input.key
            };
            let mut cell = base(
                key,
                input.capture,
                Some(row_key),
                Role::GridCell,
                column.name.clone(),
            );
            cell.grid = GridMetadata {
                row_index: Some(row.visual_index),
                column_index: Some(column.visual_index),
                row_count: Some(viewport.total_rows),
                column_count: Some(viewport.total_columns),
            };
            cell.value = row.cells.get(&column.ordinal).cloned();
            cell.selected = Some(
                input.selection.full_rows.contains(&row.source_id)
                    || input
                        .selection
                        .sparse_cells
                        .contains(&(row.source_id, column.ordinal)),
            );
            // Keep physical keyboard focus on the actual grid FocusHandle;
            // GPUI honors this descendant only while its ancestor owns focus.
            cell.active_descendant = input.owns_keyboard_focus
                && input.selection.active_cell == Some((row.source_id, column.ordinal));
            cell.actions = vec![
                Action::Focus,
                Action::Click,
                Action::ScrollIntoView,
                Action::ShowContextMenu,
            ];
            cell.read_only = input.read_only;
            // A direct SetValue would bypass typed inline draft/preview rules.
            // Editing must open the existing captured editor via Click/common
            // command; that editor exposes its own validated text actions.
            nodes.push(cell);
        }
    }
    Ok(nodes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::accessibility::RetainedTree;
    #[test]
    fn bounded_native_hierarchy_uses_original_rows_ordinals_and_virtual_metadata() {
        let key = NodeKey {
            document: 4,
            surface: 3,
            part: NodePart::Grid,
            instance: 77,
            item: 0,
            column: 0,
        };
        let capture = Capture {
            document: 4,
            result: 5,
            snapshot: 6,
            revision: 7,
            owner: 0,
        };
        let input = GridCapture {
            key,
            capture,
            name: "Results".into(),
            viewport: Viewport {
                first_row: 100,
                end_row: 101,
                total_rows: 1000000,
                first_column: 2,
                end_column: 4,
                total_columns: 30,
            },
            columns: vec![
                Column {
                    ordinal: 9,
                    visual_index: 2,
                    name: "same".into(),
                },
                Column {
                    ordinal: 3,
                    visual_index: 3,
                    name: "same".into(),
                },
            ],
            rows: vec![RealizedRow {
                source_id: 902,
                visual_index: 100,
                cells: BTreeMap::from([(9, Value::Null), (3, Value::Text("NULL".into()))]),
            }],
            selection: GridSelection {
                full_rows: BTreeSet::from([902]),
                sparse_cells: BTreeSet::from([(902, 9), (733, 3)]),
                active_cell: Some((902, 3)),
                summary: None,
            },
            read_only: true,
            owns_keyboard_focus: true,
        };
        let nodes = grid_nodes(input).unwrap();
        assert_eq!(nodes.len(), 6);
        let cells: Vec<_> = nodes
            .iter()
            .filter(|node| node.role == Role::GridCell)
            .collect();
        assert_eq!(cells[0].key.item, 902);
        assert_eq!(cells[0].key.column, 9);
        assert_eq!(cells[0].grid.row_index, Some(100));
        assert_eq!(cells[0].grid.row_count, Some(1000000));
        assert!(cells[1].active_descendant);
        assert!(!cells[0].active_descendant);
        assert_eq!(cells[0].selected, Some(true));
        assert_eq!(
            nodes[0].selection,
            Some(SelectionSummary {
                full_rows: 1,
                sparse_cells: 1
            })
        );
        assert_ne!(
            cells[0].value.as_ref().unwrap().kind_description(),
            cells[1].value.as_ref().unwrap().kind_description()
        );
        RetainedTree::new()
            .borrow_mut()
            .publish(nodes, Some(key))
            .unwrap();
    }
}
