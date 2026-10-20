use super::*;
use crate::grid_clipboard::{Payload, Publication, Value};
use crate::grid_selection::{CellPoint, Selection};
use gpui_kit::component::{
    WindowExt,
    input::{Editor, EditorState},
    menu::{PopupMenu, PopupMenuItem},
};
use gpui_kit::{AppContext, Entity, Focusable, InteractiveElement, KeyBinding};
use std::collections::HashMap;

#[derive(Clone, PartialEq, serde::Deserialize, gpui_kit::Action)]
#[action(namespace = dbeer_grid, no_json)]
pub(crate) struct Navigate {
    key: String,
    extend: bool,
    primary: bool,
}

pub(crate) fn install_keys(cx: &mut App) {
    for key in [
        "left", "right", "up", "down", "home", "end", "pageup", "pagedown", "space", "enter",
        "escape", "a", "tab",
    ] {
        for extend in [false, true] {
            for primary in [false, true] {
                if key == "a" && !primary {
                    continue;
                }
                let binding = format!(
                    "{}{}{}",
                    if primary {
                        if cfg!(target_os = "macos") {
                            "cmd-"
                        } else {
                            "ctrl-"
                        }
                    } else {
                        ""
                    },
                    if extend { "shift-" } else { "" },
                    key
                );
                cx.bind_keys([KeyBinding::new(
                    &binding,
                    Navigate {
                        key: key.into(),
                        extend,
                        primary,
                    },
                    Some("DBeerGrid > DataTable"),
                )]);
            }
        }
    }
    cx.bind_keys([KeyBinding::new(
        &crate::platform::binding("c"),
        gpui_kit::component::input::Copy,
        Some("DBeerGrid > DataTable"),
    )]);
    for binding in ["shift-f10", "contextmenu"] {
        cx.bind_keys([KeyBinding::new(
            binding,
            Navigate {
                key: "contextmenu".into(),
                extend: false,
                primary: false,
            },
            Some("DBeerGrid > DataTable"),
        )]);
    }
    for key in ["delete", "f2"] {
        cx.bind_keys([KeyBinding::new(
            key,
            Navigate {
                key: key.into(),
                extend: false,
                primary: false,
            },
            Some("DBeerGrid > DataTable"),
        )]);
    }
    // Tab and Shift+Tab traverse focus; arrows operate on original IDs.
}

impl ResultGrid {
    pub(crate) fn bind(
        &mut self,
        set: backend::ResultSet,
        metadata: Vec<backend::TableColumnMetadata>,
        snapshot: u64,
        scope: Option<crate::tables::Navigation>,
        readonly_reason: String,
    ) {
        self.original = set;
        self.metadata = metadata;
        self.snapshot = snapshot;
        self.scope = scope;
        self.readonly_reason = readonly_reason;
        if self.readonly_reason.is_empty() {
            self.draft = crate::grid_changes::Draft::new(
                &self.original,
                self.metadata.clone(),
                snapshot,
                &self.row_ids,
            );
        }
    }

    pub(crate) fn same_schema(&self, other: &Self) -> bool {
        self.original.columns == other.original.columns && self.metadata == other.metadata
    }

    /// Refresh retains only provably identical original row identities: unique PK
    /// tuples, or unique exact full rows without a key. Navigation is a new scope.
    /// New operation/result entities never inherit selection or original row IDs.
    pub(crate) fn replace(&mut self, mut next: Self) {
        let same_schema = self.same_schema(&next);
        let reconcile = same_schema && self.scope.is_some() && self.scope == next.scope;
        if same_schema {
            for (old, new) in self.result.columns.iter().zip(&mut next.result.columns) {
                new.width = old.width;
            }
            next.sort = self.sort;
            next.details_open = self.details_open;
        }
        if reconcile {
            let pk: Vec<usize> = self
                .metadata
                .iter()
                .enumerate()
                .filter_map(|(i, c)| (c.primary_key != 0).then_some(i))
                .collect();
            let key = |row: &Vec<Option<String>>| {
                if pk.is_empty() {
                    row.clone()
                } else {
                    pk.iter().map(|&i| row[i].clone()).collect()
                }
            };
            let mut old: HashMap<Vec<Option<String>>, Vec<u64>> = HashMap::new();
            let mut counts = HashMap::new();
            for (row, &id) in self.original.rows.iter().zip(&self.row_ids) {
                old.entry(key(row)).or_default().push(id);
            }
            for row in &next.original.rows {
                *counts.entry(key(row)).or_insert(0usize) += 1;
            }
            next.next_row_id = self.next_row_id;
            next.row_ids = next
                .original
                .rows
                .iter()
                .map(|row| {
                    let k = key(row);
                    if counts[&k] == 1
                        && let Some(ids) = old.get(&k).filter(|ids| ids.len() == 1)
                    {
                        return ids[0];
                    }
                    let id = next.next_row_id;
                    next.next_row_id += 1;
                    id
                })
                .collect();
            next.selection = self.selection.clone();
            next.selection.retain(&next.row_ids);
        }
        next.filter = self.filter.clone();
        if next.draft.is_some() {
            next.draft = crate::grid_changes::Draft::new(
                &next.original,
                next.metadata.clone(),
                next.snapshot,
                &next.row_ids,
            );
        }
        next.rebuild_rows();
        *self = next;
    }

    pub(crate) fn inherit_presentation(&mut self, old: &Self) {
        if self.same_schema(old) {
            for (old, new) in old.result.columns.iter().zip(&mut self.result.columns) {
                new.width = old.width;
            }
        }
    }

    pub(crate) fn widths_changed(&mut self, widths: &[gpui_kit::Pixels]) {
        for (column, width) in self.result.columns.iter_mut().zip(widths.iter().skip(1)) {
            column.width = f32::from(*width).clamp(70., 2000.);
        }
    }

    fn visible_ids(&self) -> Vec<u64> {
        self.visible_rows.iter().map(|&i| self.row_ids[i]).collect()
    }

    pub(crate) fn pointer(
        &mut self,
        row: usize,
        column: usize,
        extend: bool,
        toggle: bool,
        whole: bool,
    ) {
        let Some(&source) = self.visible_rows.get(row) else {
            return;
        };
        let point = CellPoint {
            row: self.row_ids[source],
            column: column.saturating_sub(1),
        };
        if toggle {
            self.selection.toggle_row(point, self.result.columns.len());
        } else {
            self.selection.select(
                &self.visible_ids(),
                point,
                extend,
                whole || column == 0,
                self.result.columns.len(),
            );
        }
    }

    pub(crate) fn selected(&self, row: usize, column: usize) -> bool {
        self.visible_rows
            .get(row)
            .is_some_and(|&i| self.selection.rows.contains(&self.row_ids[i]))
            && (column == 0
                || self
                    .selection
                    .columns
                    .as_ref()
                    .is_some_and(|r| r.contains(&(column - 1))))
    }

    /// Source ordinals and stable row IDs are separate, explicit staging APIs.
    pub(crate) fn selected_sources(&self) -> Vec<usize> {
        self.visible_rows
            .iter()
            .copied()
            .filter(|&source| self.selection.rows.contains(&self.row_ids[source]))
            .collect()
    }

    pub(crate) fn payload(&self, mode: CopyMode) -> Option<Payload> {
        let mut rows = self.selected_sources();
        let mut columns: Vec<usize> = self.selection.columns.clone()?.collect();
        match mode {
            CopyMode::Range => {}
            CopyMode::Rows => {
                columns = (0..self.original.columns.len()).collect();
            }
            CopyMode::Cell => {
                let focus = self.context_cell.or(self.selection.focus)?;
                rows = vec![self.row_ids.iter().position(|id| *id == focus.row)?];
                columns = vec![focus.column];
            }
        }
        if rows.is_empty() || columns.is_empty() {
            return None;
        }
        let values = rows
            .iter()
            .map(|&r| {
                columns
                    .iter()
                    .map(|&c| {
                        self.draft
                            .as_ref()
                            .map(|d| crate::grid_changes::clipboard(&d.rows[r].values[c]))
                            .unwrap_or_else(|| {
                                Value::original(
                                    &self.original.columns[c],
                                    &self.original.rows[r][c],
                                )
                            })
                    })
                    .collect()
            })
            .collect();
        let selected = columns
            .iter()
            .map(|&c| {
                let mut column = self.original.columns[c].clone();
                if column.engine == "postgresql"
                    && column.type_oid == 17
                    && column.encoding.is_none()
                {
                    column.encoding = Some("base64".into());
                }
                column
            })
            .collect();
        Some(Payload {
            version: 1,
            columns: selected,
            source_rows: rows,
            source_column_indices: columns,
            values,
        })
    }

    pub(crate) fn publication(&self) -> Option<Publication> {
        self.payload(CopyMode::Range)?.prepare().ok()
    }

    pub(crate) fn has_selection(&self) -> bool {
        self.selection.columns.is_some()
            && self
                .visible_rows
                .iter()
                .any(|&source| self.selection.rows.contains(&self.row_ids[source]))
    }

    pub(crate) fn sync_details(&mut self, window: &mut Window, cx: &mut Context<TableState<Self>>) {
        if !self.details_open {
            self.details_row = None;
            for guard in &self.details_guards {
                guard.invalidate();
            }
            self.details_guards.clear();
            self.details.clear();
            return;
        }
        let rows = self.selected_sources();
        let row = (rows.len() == 1).then(|| rows[0]);
        let id = row.map(|r| self.row_ids[r]);
        if self.details_row == id {
            return;
        }
        for guard in &self.details_guards {
            guard.invalidate();
        }
        self.details_guards.clear();
        self.details_row = id;
        self.details.clear();
        if let Some(row) = row {
            self.details = self
                .original
                .columns
                .iter()
                .enumerate()
                .map(|(column, metadata)| {
                    let value = self
                        .draft
                        .as_ref()
                        .map(|d| crate::grid_changes::clipboard(&d.rows[row].values[column]))
                        .unwrap_or_else(|| {
                            Value::original(metadata, &self.original.rows[row][column])
                        });
                    let text = value.value.unwrap_or_else(|| {
                        if value.kind == "default" {
                            "<DEFAULT>"
                        } else {
                            "SQL NULL"
                        }
                        .into()
                    });
                    cx.new(|cx| {
                        EditorState::new(window, cx)
                            .line_number(false)
                            .auto_close(false)
                            .smart_indent(false)
                            .default_value(text)
                    })
                })
                .collect();
        }
        let snapshot = self.snapshot;
        let owner = self.accessibility_owner.clone();
        let weak = cx.entity().downgrade();
        self.details_guards = self
            .details
            .iter()
            .map(|_| {
                let weak = weak.clone();
                let owner = owner.clone();
                gpui_kit::component::input::InputAccessibilityGuard::default().with_owner(
                    move |window, cx| {
                        let modal = window.has_active_dialog(cx) || window.has_active_prompt();
                        let live_owner = owner.as_ref().is_some_and(|o| {
                            o.workspace.upgrade().is_some_and(|w| {
                                let w = w.read(cx);
                                !w.closing
                                    && w.tabs.get(w.active).is_some_and(|t| {
                                        t.id == o.document && t.generation == o.source
                                    })
                            })
                        });
                        !modal
                            && live_owner
                            && weak.upgrade().is_some_and(|grid| {
                                let g = grid.read(cx).delegate();
                                g.context_valid
                                    && g.snapshot == snapshot
                                    && g.details_open
                                    && g.details_row == id
                            })
                    },
                )
            })
            .collect();
    }

    pub(crate) fn details_view(&self, cx: &App) -> gpui_kit::AnyElement {
        let mut view = div()
            .id("grid-row-details")
            .role(gpui_kit::Role::Group)
            .accessibility_id("dbeer-row-details")
            .aria_label("Exact row values and database column metadata")
            .w(gpui_kit::px(360.))
            .h_full()
            .flex()
            .flex_col()
            .border_l_1()
            .border_color(cx.theme().border)
            .p_3()
            .gap_2();
        view = view.child(div().child("Row Details"));
        let sources = self.selected_sources();
        if sources.len() != 1 {
            return view
                .child(if sources.is_empty() {
                    "Select a row to view its fields.".to_owned()
                } else {
                    format!("{} rows selected", sources.len())
                })
                .into_any_element();
        }
        let row = sources[0];
        let mut fields = div()
            .id("grid-detail-fields")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_3()
            .child(format!(
                "Row {} / original row {}",
                self.visible_rows
                    .iter()
                    .position(|&i| i == row)
                    .unwrap_or(0)
                    + 1,
                row + 1
            ));
        for (ordinal, column) in self.original.columns.iter().enumerate() {
            let projected = self
                .draft
                .as_ref()
                .map(|d| crate::grid_changes::clipboard(&d.rows[row].values[ordinal]));
            let value = projected
                .as_ref()
                .map(|v| v.value.as_ref())
                .unwrap_or_else(|| self.original.rows[row][ordinal].as_ref());
            let binary = column.encoding.as_deref() == Some("base64")
                || (column.engine == "postgresql"
                    && column.type_oid == 17
                    && value.is_some_and(|v| v.starts_with("\\x")));
            let reason = self
                .metadata
                .get(ordinal)
                .map(|m| m.edit_reason.as_str())
                .filter(|r| !r.is_empty())
                .unwrap_or(&self.readonly_reason);
            let policy = self
                .metadata
                .get(ordinal)
                .map(|m| {
                    format!(
                        " / {} / {}{}",
                        if m.nullable { "nullable" } else { "not null" },
                        if m.editable {
                            "adapter supports editing"
                        } else {
                            "read only"
                        },
                        if m.generated.is_empty() {
                            ""
                        } else {
                            " / generated"
                        }
                    )
                })
                .unwrap_or_default();
            let mut field = div()
                .flex()
                .flex_col()
                .gap_1()
                .child(format!("{}. {}", ordinal + 1, column.name))
                .child(
                    div()
                        .text_xs()
                        .text_color(cx.theme().muted_foreground)
                        .child(format!(
                            "{} {} / OID {}{}",
                            column.engine, column.native_type, column.type_oid, policy
                        )),
                )
                .child(div().text_xs().child(if binary {
                    "Binary / Base64"
                } else if projected.as_ref().is_some_and(|v| v.kind == "default") {
                    "DEFAULT"
                } else if value.is_none() {
                    "SQL NULL"
                } else if value.is_some_and(String::is_empty) {
                    "Empty string"
                } else {
                    "Text"
                }));
            if let Some(editor) = self.details.get(ordinal) {
                let height =
                    if binary || value.is_some_and(|v| v.len() > 160 || v.contains(['\n', '\r'])) {
                        140.
                    } else {
                        42.
                    };
                field = field.child(
                    div().h(px(height)).key_context("DBeerGridField").child(
                        Editor::new(editor)
                            .readonly(true)
                            .accessibility_guard(self.details_guards[ordinal].clone())
                            .accessibility_id(format!(
                                "dbeer-row-detail-{}-{}-{}",
                                self.snapshot,
                                self.details_row.unwrap_or(0),
                                ordinal
                            ))
                            .aria_label(format!("{} value, column {}", column.name, ordinal + 1)),
                    ),
                );
            }
            fields = fields.child(
                field.child(
                    div()
                        .text_xs()
                        .text_color(cx.theme().muted_foreground)
                        .child(reason.to_owned()),
                ),
            );
        }
        view.child(fields).into_any_element()
    }

    pub(super) fn selection_menu(
        &self,
        mut menu: PopupMenu,
        cx: &mut Context<TableState<Self>>,
    ) -> PopupMenu {
        let snapshot = self.snapshot;
        let draft_revision = self.draft_revision();
        if let Some(capture) = self.edit_capture(cx.entity()) {
            let point = self.context_cell.or(self.selection.focus);
            let owner = capture.owner.workspace.clone();
            menu = menu.item(
                PopupMenuItem::new("Edit Cell")
                    .disabled(point.is_none() || self.inline.is_some())
                    .on_click(move |_, window, cx| {
                        _ = owner.update(cx, |this, cx| {
                            this.changes_action(
                                capture.clone(),
                                crate::changes_view::Action::Edit(false),
                                point,
                                window,
                                cx,
                            )
                        });
                    }),
            );
        }
        for (title, mode) in [
            ("Copy Cell", CopyMode::Cell),
            ("Copy Selected Rows", CopyMode::Rows),
            ("Copy Range", CopyMode::Range),
        ] {
            let publication = self.payload(mode).and_then(|p| p.prepare().ok());
            let weak = cx.entity().downgrade();
            menu = menu.item(
                PopupMenuItem::new(title)
                    .disabled(publication.is_none())
                    .on_click(move |_, window, cx| {
                        if let Some(grid) = weak.upgrade()
                            && grid.read(cx).delegate().context_valid
                            && grid.read(cx).delegate().snapshot == snapshot
                            && grid.read(cx).delegate().draft_revision() == draft_revision
                            && let Some(data) = &publication
                            && let Err(reason) =
                                crate::native_clipboard::publish(data.clone(), window, cx)
                        {
                            window.open_dialog(cx, move |dialog, _, _| {
                                dialog
                                    .title("Copy Selection")
                                    .accessibility_label("Copy Selection")
                                    .child(reason)
                            });
                        }
                    }),
            );
        }
        let weak = cx.entity().downgrade();
        let context = self.context_cell;
        menu.item(
            PopupMenuItem::new("Row Details").on_click(move |_, window, cx| {
                if let Some(grid) = weak.upgrade() {
                    grid.update(cx, |grid, cx| {
                        if grid.delegate().context_valid
                            && grid.delegate().snapshot == snapshot
                            && grid.delegate().draft_revision() == draft_revision
                        {
                            if let Some(point) = context {
                                let visible = grid.delegate().visible_ids();
                                let columns = grid.delegate().original.columns.len();
                                grid.delegate_mut()
                                    .selection
                                    .select(&visible, point, false, false, columns);
                            }
                            grid.delegate_mut().details_open = true;
                            grid.delegate_mut().sync_details(window, cx);
                            cx.notify();
                        }
                    });
                }
            }),
        )
    }
}

#[derive(Clone, Copy)]
pub(crate) enum CopyMode {
    Cell,
    Rows,
    Range,
}

pub(crate) fn navigate(
    grid: &Entity<TableState<ResultGrid>>,
    action: &Navigate,
    window: &mut Window,
    cx: &mut App,
) {
    let modal = window.has_active_dialog(cx) || window.has_active_prompt();
    let g = grid.read(cx).delegate();
    if g.inline
        .as_ref()
        .is_some_and(|i| i.editor.focus_handle(cx).contains_focused(window, cx))
        || g.details
            .iter()
            .any(|editor| editor.focus_handle(cx).contains_focused(window, cx))
    {
        return;
    }
    if modal || !g.context_valid {
        return;
    }
    if action.key == "contextmenu" {
        let point = g.selection.focus;
        let row = point.and_then(|point| {
            g.visible_rows
                .iter()
                .position(|&r| g.row_ids[r] == point.row)
        });
        let menu = g.context_menu_handle.clone();
        grid.update(cx, |table, cx| {
            table.delegate_mut().context_cell = point;
            table.set_right_clicked_row(row, cx);
            cx.notify();
        });
        menu.open(window, cx);
        return;
    }
    if matches!(action.key.as_str(), "delete" | "f2") {
        if let Some(capture) = g.edit_capture(grid.clone()) {
            let point = g.selection.focus;
            let owner = capture.owner.workspace.clone();
            let action = if action.key == "delete" {
                crate::changes_view::Action::Delete
            } else {
                crate::changes_view::Action::Edit(false)
            };
            _ = owner.update(cx, |w, cx| {
                w.changes_action(capture, action, point, window, cx)
            });
        }
        return;
    }
    grid.update(cx, |table, cx| {
        if action.key == "tab" {
            if action.extend {
                window.focus_prev(cx);
            } else {
                window.focus_next(cx);
            }
            return;
        }
        table.delegate_mut().context_cell = None;
        let visible = table.delegate().visible_ids();
        let columns = table.delegate().original.columns.len();
        if visible.is_empty() || columns == 0 {
            return;
        }
        let focus = table.delegate().selection.focus.unwrap_or(CellPoint {
            row: visible[0],
            column: 0,
        });
        let mut row = visible.iter().position(|&id| id == focus.row).unwrap_or(0);
        let mut column = focus.column;
        let page = table
            .visible_range()
            .rows()
            .len()
            .max(1)
            .saturating_sub(1)
            .max(1);
        let mut whole = table.delegate().selection.whole_rows
            && matches!(action.key.as_str(), "up" | "down" | "pageup" | "pagedown");
        match action.key.as_str() {
            "left" => {
                column = if action.primary {
                    0
                } else {
                    column.saturating_sub(1)
                }
            }
            "right" => {
                column = if action.primary {
                    columns - 1
                } else {
                    (column + 1).min(columns - 1)
                }
            }
            "up" => {
                row = if action.primary {
                    0
                } else {
                    row.saturating_sub(1)
                }
            }
            "down" => {
                row = if action.primary {
                    visible.len() - 1
                } else {
                    (row + 1).min(visible.len() - 1)
                }
            }
            "home" => {
                column = 0;
                if action.primary {
                    row = 0;
                }
            }
            "end" => {
                column = columns - 1;
                if action.primary {
                    row = visible.len() - 1;
                }
            }
            "pageup" => row = row.saturating_sub(page),
            "pagedown" => row = (row + page).min(visible.len() - 1),
            "escape" => {
                table.delegate_mut().selection = Selection::default();
                table.delegate_mut().sync_details(window, cx);
                cx.notify();
                return;
            }
            "space" if action.extend => {
                whole = true;
            }
            "space" | "enter" => {
                table.delegate_mut().details_open = !table.delegate().details_open;
                table.delegate_mut().sync_details(window, cx);
                cx.notify();
                return;
            }
            "a" if action.primary => {
                let selection = &mut table.delegate_mut().selection;
                selection.select(
                    &visible,
                    CellPoint {
                        row: visible[0],
                        column: 0,
                    },
                    false,
                    false,
                    columns,
                );
                selection.select(
                    &visible,
                    CellPoint {
                        row: *visible.last().unwrap(),
                        column: columns - 1,
                    },
                    true,
                    false,
                    columns,
                );
                table.delegate_mut().sync_details(window, cx);
                cx.notify();
                return;
            }
            _ => return,
        }
        table.delegate_mut().selection.select(
            &visible,
            CellPoint {
                row: visible[row],
                column,
            },
            action.extend,
            whole,
            columns,
        );
        table.delegate_mut().sync_details(window, cx);
        table.scroll_to_row(row, cx);
        table.scroll_to_col(column + 1, cx);
        cx.notify();
    });
}

pub(crate) fn select_all(grid: &Entity<TableState<ResultGrid>>, window: &mut Window, cx: &mut App) {
    navigate(
        grid,
        &Navigate {
            key: "a".into(),
            extend: false,
            primary: true,
        },
        window,
        cx,
    );
}

pub(crate) fn navigate_native(
    grid: &Entity<TableState<ResultGrid>>,
    action: gpui_kit::accesskit::Action,
    window: &mut Window,
    cx: &mut App,
) {
    let key = match action {
        gpui_kit::accesskit::Action::ScrollUp => "pageup",
        gpui_kit::accesskit::Action::ScrollDown => "pagedown",
        gpui_kit::accesskit::Action::ScrollLeft => "left",
        gpui_kit::accesskit::Action::ScrollRight => "right",
        _ => return,
    };
    navigate(
        grid,
        &Navigate {
            key: key.into(),
            extend: false,
            primary: false,
        },
        window,
        cx,
    );
}
