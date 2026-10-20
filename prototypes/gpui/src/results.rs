//! Read-only fixture results rendered with GPUI Kit's virtualized native table.

use std::cmp::Ordering;

use crate::{backend, grid_selection::Selection};
use gpui_kit::base::TestSupportExt as _;
use gpui_kit::component::{
    ActiveTheme,
    table::{Column as TableColumn, ColumnSort, TableDelegate, TableState},
};
use gpui_kit::{
    App, Context, InteractiveElement, IntoElement, ParentElement, StatefulInteractiveElement,
    Styled, Window, div, prelude::FluentBuilder, px,
};
pub(crate) mod interaction;

use crate::demo::{Cell, QueryResult};

pub struct ResultGrid {
    result: QueryResult,
    pub(super) visible_rows: Vec<usize>,
    filter: String,
    sort: Option<(usize, ColumnSort)>,
    pub(super) original: backend::ResultSet,
    pub(super) metadata: Vec<backend::TableColumnMetadata>,
    pub(super) row_ids: Vec<u64>,
    next_row_id: u64,
    pub(super) selection: Selection,
    pub(super) snapshot: u64,
    pub(super) context_valid: bool,
    pub(super) scope: Option<crate::tables::Navigation>,
    pub(super) details_open: bool,
    pub(super) details_row: Option<u64>,
    pub(super) details_guards: Vec<gpui_kit::component::input::InputAccessibilityGuard>,
    pub(super) details: Vec<gpui_kit::Entity<gpui_kit::component::input::EditorState>>,
    pub(super) readonly_reason: String,
    pub(super) drag_active: bool,
    pub(super) drag_whole: bool,
    pub(super) context_cell: Option<crate::grid_selection::CellPoint>,
    pub(super) draft: Option<crate::grid_changes::Draft>,
    pub(super) edit_owner: Option<crate::changes_view::Owner>,
    pub(super) inline: Option<crate::changes_view::Inline>,
    pub(super) edit_error: Option<String>,
    pub(super) accessibility: crate::accessibility::SharedTree,
    pub(super) accessibility_revision: u64,
    pub(super) accessibility_owner: Option<crate::accessibility::WorkspaceGridOwner>,
    pub(super) context_menu_handle: gpui_kit::component::menu::ContextMenuHandle,
}

impl ResultGrid {
    pub fn new(result: QueryResult) -> Self {
        let visible_rows = (0..result.rows.len()).collect();
        let original = backend::ResultSet {
            columns: result
                .columns
                .iter()
                .enumerate()
                .map(|(index, c)| backend::Column {
                    index,
                    name: c.name.clone(),
                    engine: "postgresql".into(),
                    native_type: c.data_type.clone(),
                    type_oid: 0,
                    encoding: None,
                })
                .collect(),
            rows: result
                .rows
                .iter()
                .map(|row| {
                    row.iter()
                        .map(|cell| match cell {
                            Cell::Null => None,
                            Cell::Text(v) | Cell::Number(v) | Cell::Binary(v) => Some(v.clone()),
                            Cell::Bool(v) => Some(v.to_string()),
                        })
                        .collect()
                })
                .collect(),
            ..Default::default()
        };
        let row_ids = (1..=result.rows.len() as u64).collect();
        let next_row_id = result.rows.len() as u64 + 1;
        Self {
            result,
            visible_rows,
            filter: String::new(),
            sort: None,
            original,
            metadata: Vec::new(),
            row_ids,
            next_row_id,
            selection: Selection::default(),
            snapshot: 0,
            context_valid: true,
            scope: None,
            details_open: false,
            details_row: None,
            details: Vec::new(),
            details_guards: Vec::new(),
            readonly_reason: "Query results are read only.".into(),
            drag_active: false,
            drag_whole: false,
            context_cell: None,
            draft: None,
            edit_owner: None,
            inline: None,
            edit_error: None,
            accessibility: crate::accessibility::RetainedTree::new(),
            accessibility_revision: 1,
            accessibility_owner: None,
            context_menu_handle: Default::default(),
        }
    }

    pub fn set_filter(&mut self, filter: &str) {
        self.invalidate_accessibility();
        self.filter = filter.to_lowercase();
        self.rebuild_rows();
    }

    pub fn row_count(&self) -> usize {
        self.visible_rows.len()
    }

    pub fn total_count(&self) -> usize {
        self.result.rows.len()
    }

    /// Copy the visible view, in its current sort order. All text fields are
    /// quoted; SQL NULL is an unquoted \N, so empty text, "NULL", and "\N"
    /// remain distinct. This is a display-copy format, not a database export.
    pub fn copy_tsv(&self) -> String {
        let mut lines = vec![
            self.result
                .columns
                .iter()
                .map(|column| quote_text(&column.name))
                .collect::<Vec<_>>()
                .join("\t"),
        ];
        lines.extend(self.visible_rows.iter().map(|&index| {
            self.result.rows[index]
                .iter()
                .map(copy_cell)
                .collect::<Vec<_>>()
                .join("\t")
        }));
        lines.join("\n")
    }

    fn rebuild_rows(&mut self) {
        self.visible_rows = self
            .result
            .rows
            .iter()
            .enumerate()
            .filter(|(_, row)| {
                self.filter.is_empty()
                    || row
                        .iter()
                        .any(|cell| cell.display().to_lowercase().contains(&self.filter))
            })
            .map(|(index, _)| index)
            .collect();

        if let Some((column, direction)) = self.sort {
            let rows = &self.result.rows;
            self.visible_rows.sort_by(|&left, &right| {
                let order = match (rows[left].get(column), rows[right].get(column)) {
                    (Some(left), Some(right)) => compare_cells(left, right),
                    _ => Ordering::Equal,
                };
                let order = if direction == ColumnSort::Descending {
                    order.reverse()
                } else {
                    order
                };
                order.then(left.cmp(&right))
            });
        }
    }

    fn cell(&self, row: usize, column: usize) -> Option<&Cell> {
        self.visible_rows
            .get(row)
            .and_then(|&index| self.result.rows.get(index))
            .and_then(|row| row.get(column))
    }

    /// Editor child hit testing keeps the table from stealing its caret/focus.
    fn inline_cell(&self, row: usize, column: usize) -> bool {
        self.inline.as_ref().is_some_and(|inline| {
            !inline.expanded
                && column != 0
                && column - 1 == inline.column
                && self
                    .visible_rows
                    .get(row)
                    .is_some_and(|&r| self.row_ids[r] == inline.row)
        })
    }

    /// Rebuild display/copy projection only. Protocol rows and CAS originals stay immutable.
    pub(super) fn project_draft(&mut self) {
        self.invalidate_accessibility();
        if let Some(draft) = &self.draft {
            self.row_ids = draft.rows.iter().map(|r| r.id).collect();
            self.result.rows = draft
                .rows
                .iter()
                .map(|row| {
                    row.values
                        .iter()
                        .enumerate()
                        .map(|(column, value)| match value {
                            backend::CellValue::Null => Cell::Null,
                            backend::CellValue::Default => Cell::Text("<DEFAULT>".into()),
                            backend::CellValue::Text(v)
                                if crate::live::numeric_type(
                                    &self.original.columns[column].native_type,
                                ) =>
                            {
                                Cell::Number(v.clone())
                            }
                            backend::CellValue::Text(v) => Cell::Text(v.clone()),
                            backend::CellValue::Binary(v) => Cell::Binary(v.clone()),
                        })
                        .collect()
                })
                .collect();
            self.selection.retain(&self.row_ids);
            self.details_row = None;
            self.rebuild_rows();
        }
    }
}

impl TableDelegate for ResultGrid {
    fn will_mutate(&mut self) {
        self.invalidate_accessibility();
    }
    fn context_menu_handle(&self) -> Option<gpui_kit::component::menu::ContextMenuHandle> {
        Some(self.context_menu_handle.clone())
    }
    fn accessibility_row_selected(&self, row: usize) -> Option<bool> {
        Some(self.selection.whole_rows && self.selected(row, 0))
    }
    fn render_container(
        &mut self,
        rows: std::ops::Range<usize>,
        columns: std::ops::Range<usize>,
        window: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) -> gpui_kit::Stateful<gpui_kit::Div> {
        self.publish_accessibility(rows, columns, window, cx);
        self.accessible_container(crate::accessibility::NodePart::Grid, 0, 0, cx)
    }
    fn render_tr(
        &mut self,
        row: usize,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) -> gpui_kit::Stateful<gpui_kit::Div> {
        self.accessible_container(crate::accessibility::NodePart::Row, row, 0, cx)
    }
    fn visible_rows_changed(
        &mut self,
        _: std::ops::Range<usize>,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) {
        self.invalidate_accessibility();
        cx.notify();
    }
    fn visible_columns_changed(
        &mut self,
        _: std::ops::Range<usize>,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) {
        self.invalidate_accessibility();
        cx.notify();
    }

    fn columns_count(&self, _: &App) -> usize {
        self.result.columns.len() + 1
    }

    fn rows_count(&self, _: &App) -> usize {
        self.row_count()
    }

    fn column(&self, column: usize, _: &App) -> TableColumn {
        if column == 0 {
            return TableColumn::new("__row_number", "#")
                .width(px(52.0))
                .min_width(px(52.0))
                .fixed_left()
                .text_right()
                .resizable(false)
                .movable(false)
                .selectable(false);
        }
        let definition = &self.result.columns[column - 1];
        let mut output = TableColumn::new(format!("column-{column}"), definition.name.clone())
            .width(px(definition.width))
            .min_width(px(70.0))
            .max_width(px(2000.0))
            .resizable(true)
            .movable(false)
            .sortable();
        if definition.data_type.starts_with("int") || definition.data_type.starts_with("numeric") {
            output = output.text_right();
        }
        output
    }

    fn perform_sort(
        &mut self,
        column: usize,
        direction: ColumnSort,
        window: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) {
        self.sort = if column == 0 || direction == ColumnSort::Default {
            None
        } else {
            Some((column - 1, direction))
        };
        self.rebuild_rows();
        self.sync_details(window, cx);
        cx.notify();
    }

    fn render_th(
        &mut self,
        column: usize,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) -> impl IntoElement {
        let header = self
            .accessible_container(crate::accessibility::NodePart::Header, 0, column, cx)
            .size_full()
            .flex()
            .flex_col()
            .justify_center();
        if column == 0 {
            return header.text_color(cx.theme().muted_foreground).child("#");
        }
        let definition = &self.result.columns[column - 1];
        header
            .child(
                div()
                    .text_size(px(12.0))
                    .truncate()
                    .child(definition.name.clone()),
            )
            .child(
                div()
                    .text_size(px(10.0))
                    .truncate()
                    .text_color(cx.theme().muted_foreground)
                    .child(definition.data_type.clone()),
            )
    }

    fn render_td(
        &mut self,
        row: usize,
        column: usize,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) -> impl IntoElement {
        let selected = self.selected(row, column);
        let cell = self
            .accessible_container(crate::accessibility::NodePart::Cell, row, column, cx)
            .test_support()
            .size_full()
            .min_w_0()
            .overflow_hidden()
            .truncate()
            .text_size(px(12.0))
            .font_family(cx.theme().mono_font_family.clone())
            .when(selected, |cell| {
                cell.bg(cx.theme().table_active)
                    .border_1()
                    .border_color(cx.theme().primary)
            })
            .on_mouse_down(
                gpui_kit::MouseButton::Left,
                cx.listener(move |table, event: &gpui_kit::MouseDownEvent, window, cx| {
                    if window.has_active_prompt() {
                        return;
                    }
                    if table.delegate().inline_cell(row, column) {
                        return;
                    }
                    gpui_kit::Focusable::focus_handle(table, cx).focus(window, cx);
                    table.delegate_mut().pointer(
                        row,
                        column,
                        event.modifiers.shift,
                        if cfg!(target_os = "macos") {
                            event.modifiers.platform
                        } else {
                            event.modifiers.control
                        },
                        event.modifiers.alt,
                    );
                    table.delegate_mut().drag_active = true;
                    table.delegate_mut().drag_whole = table.delegate().selection.whole_rows;
                    table.delegate_mut().context_cell = None;
                    table.delegate_mut().sync_details(window, cx);
                    cx.stop_propagation();
                    cx.notify();
                }),
            )
            .on_mouse_move(cx.listener(
                move |table, event: &gpui_kit::MouseMoveEvent, window, cx| {
                    if event.dragging() && table.delegate().drag_active {
                        let whole = table.delegate().drag_whole;
                        table
                            .delegate_mut()
                            .pointer(row, column, true, false, whole);
                        table.delegate_mut().sync_details(window, cx);
                        // Edge rows reached by drag stay visible; virtualization remains bounded.
                        let visible = table.visible_range().rows();
                        if row <= visible.start && row > 0 {
                            table.scroll_to_row(row - 1, cx);
                        } else if row + 1 >= visible.end && row + 1 < table.delegate().row_count() {
                            table.scroll_to_row(row + 1, cx);
                        }
                        cx.notify();
                    }
                },
            ))
            .on_mouse_up(
                gpui_kit::MouseButton::Left,
                cx.listener(|table, _, _, _| {
                    table.delegate_mut().drag_active = false;
                }),
            )
            .on_click(
                cx.listener(move |table, event: &gpui_kit::ClickEvent, window, cx| {
                    if table.delegate().inline_cell(row, column) {
                        return;
                    }
                    // Toolkit's single-cell escalation must not replace our range.
                    if event.click_count() == 2 {
                        table.delegate_mut().details_open = true;
                        table.delegate_mut().sync_details(window, cx);
                    }
                    cx.stop_propagation();
                    cx.notify();
                }),
            )
            .on_mouse_down(
                gpui_kit::MouseButton::Right,
                cx.listener(move |table, _, window, cx| {
                    if table.delegate().inline_cell(row, column) {
                        return;
                    }
                    if let Some(&source) = table.delegate().visible_rows.get(row) {
                        table.delegate_mut().context_cell =
                            Some(crate::grid_selection::CellPoint {
                                row: table.delegate().row_ids[source],
                                column: column.saturating_sub(1),
                            });
                    }
                    if !table.delegate().selected(row, column) {
                        table
                            .delegate_mut()
                            .pointer(row, column, false, false, false);
                    }
                    table.delegate_mut().sync_details(window, cx);
                    cx.notify();
                }),
            );
        if column == 0 {
            let marker = self
                .visible_rows
                .get(row)
                .and_then(|&r| self.draft.as_ref()?.rows.get(r))
                .map(|r| {
                    if r.deleted {
                        "- "
                    } else if r.original.is_none() {
                        "+ "
                    } else if r.pending() {
                        "* "
                    } else {
                        ""
                    }
                })
                .unwrap_or("");
            return cell
                .text_color(cx.theme().muted_foreground)
                .child(format!("{marker}{}", row + 1))
                .into_any_element();
        }
        if let Some(inline) = &self.inline
            && self
                .visible_rows
                .get(row)
                .is_some_and(|&r| self.row_ids[r] == inline.row)
            && inline.column == column - 1
            && !inline.expanded
        {
            return cell
                .key_context("DBeerGridField")
                .child(
                    gpui_kit::component::input::Editor::new(&inline.editor)
                        .readonly(inline.locked)
                        .accessibility_guard(inline.accessibility_guard.clone())
                        .accessibility_id(format!(
                            "dbeer-cell-editor-{}-{}",
                            inline.row, inline.column
                        ))
                        .aria_label("Edit exact typed cell value"),
                )
                .into_any_element();
        }
        let staged = self
            .visible_rows
            .get(row)
            .and_then(|&r| self.draft.as_ref()?.rows.get(r))
            .is_some_and(|r| r.original.is_none() || r.assignments.contains_key(&(column - 1)));
        let deleted = self
            .visible_rows
            .get(row)
            .and_then(|&r| self.draft.as_ref()?.rows.get(r))
            .is_some_and(|r| r.deleted);
        let cell = cell
            .when(staged && !selected, |cell| cell.bg(cx.theme().secondary))
            .when(deleted, |cell| cell.opacity(0.5));
        match self.cell(row, column - 1) {
            Some(Cell::Null) => cell
                .text_color(cx.theme().muted_foreground)
                .italic()
                .child("NULL"),
            Some(Cell::Text(value)) if value.is_empty() => {
                cell.text_color(cx.theme().muted_foreground).child("\"\"")
            }
            Some(Cell::Text(value)) if value == "NULL" => cell.child("\"NULL\""),
            Some(value) => cell.child(cell_preview(value)),
            None => cell,
        }
        .into_any_element()
    }

    fn context_menu(
        &mut self,
        _: usize,
        menu: gpui_kit::component::menu::PopupMenu,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) -> gpui_kit::component::menu::PopupMenu {
        self.selection_menu(menu, cx)
    }

    fn render_empty(
        &mut self,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) -> impl IntoElement {
        div()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .text_color(cx.theme().muted_foreground)
            .child(if self.filter.is_empty() {
                "No rows"
            } else {
                "No matching rows"
            })
    }

    fn cell_text(&self, row: usize, column: usize, _: &App) -> String {
        if column == 0 {
            return (row + 1).to_string();
        }
        self.cell(row, column - 1)
            .map(copy_cell)
            .unwrap_or_default()
    }
}

fn quote_text(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn copy_cell(cell: &Cell) -> String {
    match cell {
        Cell::Null => "\\N".into(),
        Cell::Text(value) => quote_text(value),
        Cell::Binary(value) => quote_text(&format!("base64:{value}")),
        Cell::Number(value) => value.clone(),
        Cell::Bool(value) => value.to_string(),
    }
}

/// Bound layout work for large text/binary cells; copy/details keep full values.
fn cell_preview(cell: &Cell) -> String {
    let (prefix, value) = match cell {
        Cell::Null => return "NULL".into(),
        Cell::Bool(value) => return value.to_string(),
        Cell::Text(value) | Cell::Number(value) => ("", value),
        Cell::Binary(value) => ("base64:", value),
    };
    let mut characters = value.chars();
    let mut preview = prefix.to_owned();
    preview.extend(characters.by_ref().take(256));
    if characters.next().is_some() {
        preview.push_str("...");
    }
    preview
}

fn compare_cells(left: &Cell, right: &Cell) -> Ordering {
    let rank = |cell: &Cell| match cell {
        Cell::Null => 0,
        Cell::Number(_) => 1,
        Cell::Bool(_) => 2,
        Cell::Text(_) => 3,
        Cell::Binary(_) => 4,
    };
    let rank_order = rank(left).cmp(&rank(right));
    if rank_order != Ordering::Equal {
        return rank_order;
    }
    match (left, right) {
        (Cell::Null, Cell::Null) => Ordering::Equal,
        (Cell::Null, _) => Ordering::Less,
        (_, Cell::Null) => Ordering::Greater,
        (Cell::Number(left), Cell::Number(right)) => compare_numbers(left, right),
        (Cell::Bool(left), Cell::Bool(right)) => left.cmp(right),
        _ => {
            let left = left.display();
            let right = right.display();
            left.to_lowercase()
                .cmp(&right.to_lowercase())
                .then(left.cmp(&right))
        }
    }
}

/// Compare signed fixed-point decimal strings without a floating-point
/// conversion. Non-decimal spellings (including exponents) sort as text.
fn compare_numbers(left: &str, right: &str) -> Ordering {
    match (decimal_parts(left), decimal_parts(right)) {
        (
            Some((left_negative, left_integer, left_fraction)),
            Some((right_negative, right_integer, right_fraction)),
        ) => {
            if left_negative != right_negative {
                return right_negative.cmp(&left_negative);
            }
            let order = left_integer
                .len()
                .cmp(&right_integer.len())
                .then(left_integer.cmp(right_integer))
                .then(left_fraction.cmp(right_fraction));
            if left_negative {
                order.reverse()
            } else {
                order
            }
        }
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => left.cmp(right),
    }
}

fn decimal_parts(value: &str) -> Option<(bool, &str, &str)> {
    let negative = value.starts_with('-');
    let unsigned = value.strip_prefix(['-', '+']).unwrap_or(value);
    let (integer, fraction) = unsigned.split_once('.').unwrap_or((unsigned, ""));
    if integer.is_empty() && fraction.is_empty()
        || !integer.bytes().all(|byte| byte.is_ascii_digit())
        || !fraction.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    let integer = integer.trim_start_matches('0');
    let fraction = fraction.trim_end_matches('0');
    Some((
        negative && (!integer.is_empty() || !fraction.is_empty()),
        integer,
        fraction,
    ))
}

#[cfg(test)]
mod tests {
    use super::{ResultGrid, compare_numbers};
    use crate::demo::{Cell, Column, QueryResult};
    use gpui_kit::component::table::ColumnSort;
    use std::cmp::Ordering;

    #[test]
    fn fixed_point_numbers_sort_without_losing_precision() {
        for (left, right) in [
            ("9007199254740992", "9007199254740993"),
            ("-100.10", "-100.01"),
            ("0.00001", "0.0001"),
            ("2.9", "10.1"),
            ("-0.1", "0"),
        ] {
            assert_eq!(compare_numbers(left, right), Ordering::Less);
            assert_eq!(compare_numbers(right, left), Ordering::Greater);
        }
        assert_eq!(compare_numbers("-000.00", "+0"), Ordering::Equal);
        assert_eq!(compare_numbers("01.20", "1.2"), Ordering::Equal);
    }

    #[test]
    fn copied_values_preserve_null_and_text_distinctions() {
        let grid = ResultGrid::new(QueryResult {
            columns: vec![Column {
                name: "value".into(),
                data_type: "text".into(),
                width: 140.0,
            }],
            rows: vec![
                vec![Cell::Null],
                vec![Cell::Text(String::new())],
                vec![Cell::Text("NULL".into())],
                vec![Cell::Text("\\N".into())],
                vec![Cell::Text("a\tb\n\"c\"".into())],
            ],
        });
        assert_eq!(
            grid.copy_tsv(),
            "\"value\"\n\\N\n\"\"\n\"NULL\"\n\"\\N\"\n\"a\tb\n\"\"c\"\"\""
        );
    }

    #[test]
    fn filtering_retains_sort_and_restores_original_rows() {
        let mut grid = ResultGrid::new(QueryResult {
            columns: vec![Column {
                name: "value".into(),
                data_type: "text".into(),
                width: 140.0,
            }],
            rows: vec![
                vec![Cell::Text("Bravo".into())],
                vec![Cell::Text("alpha".into())],
            ],
        });
        grid.sort = Some((0, ColumnSort::Ascending));
        grid.set_filter("A");
        assert_eq!(grid.visible_rows, [1, 0]);
        grid.set_filter("BR");
        assert_eq!(grid.visible_rows, [0]);
        assert_eq!(grid.row_count(), 1);
        assert_eq!(grid.total_count(), 2);
        grid.sort = None;
        grid.set_filter("");
        assert_eq!(grid.visible_rows, [0, 1]);
    }
}

#[cfg(test)]
mod selection_tests;
