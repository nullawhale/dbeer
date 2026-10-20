//! Captured local editor workflow. This module submits no helper requests.
use super::*;
use crate::grid_changes::{ColumnPolicy, Fingerprint};
use crate::grid_selection::{CellPoint, Selection};
use gpui_kit::base::Selectable;

#[derive(Clone)]
pub(super) struct Owner {
    pub document: DocumentId,
    pub result: (u64, usize),
    pub target: catalog::CatalogTarget,
    pub workspace: WeakEntity<Workspace>,
}
#[derive(Clone)]
pub(super) struct Capture {
    pub owner: Owner,
    pub grid: Entity<TableState<ResultGrid>>,
    pub fingerprint: Fingerprint,
    pub revision: u64,
}
/// Immutable handoff to Tasks 18-19. Never persist or log this value.
#[derive(Clone)]
pub(super) struct ChangesBatch {
    pub capture: Capture,
    pub request: backend::ChangesRequest,
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Kind {
    Value,
    Null,
    Default,
}
pub(super) struct Inline {
    pub row: u64,
    pub column: usize,
    pub token: u64,
    pub editor: Entity<EditorState>,
    pub accessibility_guard: gpui_kit::component::input::InputAccessibilityGuard,
    pub kind: Kind,
    pub expanded: bool,
    pub locked: bool,
    pub selection: Selection,
    pub focus: Option<FocusHandle>,
    pub _subscription: Subscription,
}
#[derive(Clone, Copy)]
pub(super) enum Action {
    Edit(bool),
    Insert,
    Delete,
    Discard,
    Columns,
}
impl ResultGrid {
    pub(super) fn has_drafts(&self) -> bool {
        self.inline.is_some() || self.draft.as_ref().is_some_and(|d| d.pending() != 0)
    }
    pub(super) fn draft_revision(&self) -> u64 {
        self.draft.as_ref().map_or(0, |d| d.revision)
    }
    pub(super) fn edit_capture(&self, grid: Entity<TableState<Self>>) -> Option<Capture> {
        Some(Capture {
            owner: self.edit_owner.clone()?,
            grid,
            fingerprint: self
                .draft
                .as_ref()
                .map(|d| d.fingerprint.clone())
                .unwrap_or_else(|| Fingerprint {
                    columns: self.original.columns.clone(),
                    metadata: self.metadata.clone(),
                    snapshot: self.snapshot,
                }),
            revision: self.draft_revision(),
        })
    }
}
impl Workspace {
    pub(super) fn discard_reviewed_drafts(
        &mut self,
        reviews: &[close::DraftReview],
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        for review in reviews {
            if !review.discard_allowed(cx)
                || !self.tabs.iter().any(|t| {
                    t.id == review.document && t.grid_views.values().any(|g| *g == review.grid)
                })
            {
                continue;
            }
            review.grid.update(cx, |table, cx| {
                let g = table.delegate_mut();
                g.inline = None;
                if let Some(draft) = &mut g.draft {
                    draft.discard();
                }
                g.selection = Selection::default();
                g.edit_error = None;
                g.project_draft();
                g.sync_details(window, cx);
                table.refresh(cx);
                cx.notify();
            });
        }
        for review in reviews {
            self.sync_changes_locks(review.document, cx);
        }
    }
    pub(super) fn changes_capture(&self, id: DocumentId, cx: &App) -> Option<Capture> {
        let tab = self.tabs.iter().find(|t| t.id == id)?;
        let grid = tab.grid.as_ref()?;
        grid.read(cx).delegate().edit_capture(grid.clone())
    }
    /// Exact original result/entity, protocol columns, ordinal capabilities,
    /// snapshot and full captured profile/settings/service/helper ownership.
    pub(super) fn changes_valid(&self, capture: &Capture, revision: bool, cx: &App) -> bool {
        self.changes_owner_valid(capture, cx) && {
            let g = capture.grid.read(cx).delegate();
            g.readonly_reason.is_empty()
                && g.draft.as_ref().is_some_and(|d| {
                    d.fingerprint == capture.fingerprint
                        && (!revision || d.revision == capture.revision)
                })
        }
    }
    fn changes_local_valid(&self, capture: &Capture, revision: bool, cx: &App) -> bool {
        self.tabs.iter().any(|t| {
            t.id == capture.owner.document
                && t.profile == capture.owner.target.profile
                && t.grid_views.get(&capture.owner.result) == Some(&capture.grid)
        }) && {
            let g = capture.grid.read(cx).delegate();
            g.context_valid
                && g.snapshot == capture.fingerprint.snapshot
                && g.original.columns == capture.fingerprint.columns
                && g.metadata == capture.fingerprint.metadata
                && g.draft.as_ref().is_some_and(|d| {
                    d.fingerprint == capture.fingerprint
                        && (!revision || d.revision == capture.revision)
                })
        }
    }
    fn changes_owner_valid(&self, capture: &Capture, cx: &App) -> bool {
        self.catalog_target_valid(&capture.owner.target)
            && self.tabs.iter().any(|t| {
                t.id == capture.owner.document
                    && t.profile == capture.owner.target.profile
                    && matches!(&t.kind, model::DocumentKind::Table { .. })
                    && !t.snapshot_locked()
                    && t.grid_views.get(&capture.owner.result) == Some(&capture.grid)
            })
            && {
                let g = capture.grid.read(cx).delegate();
                g.context_valid
                    && g.original.columns == capture.fingerprint.columns
                    && g.metadata == capture.fingerprint.metadata
                    && g.snapshot == capture.fingerprint.snapshot
            }
    }
    pub(super) fn changes_batch(&self, capture: &Capture, cx: &App) -> Option<ChangesBatch> {
        if !self.changes_valid(capture, true, cx) {
            return None;
        }
        let grid = capture.grid.read(cx).delegate();
        if grid.inline.is_some() {
            return None;
        }
        let (schema, object) = capture.owner.target.node.object()?;
        let request = grid
            .draft
            .as_ref()?
            .request(schema.into(), object.name.clone());
        request.valid().then(|| ChangesBatch {
            capture: capture.clone(),
            request,
        })
    }
    pub(super) fn sync_changes_locks(&mut self, id: DocumentId, cx: &App) {
        if let Some(tab) = self.tabs.iter_mut().find(|t| t.id == id) {
            let (inline, count) =
                tab.grid_views
                    .values()
                    .fold((false, 0), |(inline, count), grid| {
                        let grid = grid.read(cx).delegate();
                        (
                            inline || grid.inline.is_some(),
                            count + grid.draft.as_ref().map_or(0, |d| d.pending()),
                        )
                    });
            if let Some(table) = tab.catalog_document.as_mut().and_then(|d| d.table.as_mut()) {
                table.locks.inline_draft = inline;
                table.locks.staged_changes = count;
            }
        }
    }
    fn changes_available(&self, capture: &Capture, window: &mut Window, cx: &mut App) -> bool {
        !self.closing
            && !self.preview_blocks(capture.owner.document)
            && !self.changes_recovery_locked(capture.owner.document)
            && (self.file_request.is_none() && self.export_request.is_none())
            && !window.has_active_dialog(cx)
            && !window.has_active_prompt()
            && self.changes_valid(capture, true, cx)
    }
    pub(super) fn changes_action(
        &mut self,
        capture: Capture,
        action: Action,
        point: Option<CellPoint>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if matches!(action, Action::Columns) {
            if !self.closing
                && !self.preview_blocks(capture.owner.document)
                && !window.has_active_dialog(cx)
                && !window.has_active_prompt()
                && (self.file_request.is_none() && self.export_request.is_none())
                && self.changes_owner_valid(&capture, cx)
            {
                self.columns_dialog(&capture, window, cx);
            }
            return;
        }
        if matches!(action, Action::Discard) {
            if self.unknown_changes(capture.owner.document).is_some() {
                return;
            }
            if self.closing
                || self.preview_blocks(capture.owner.document)
                || (self.file_request.is_some()
                    || (self.export_request.is_some() || self.run_file.is_some()))
                || window.has_active_dialog(cx)
                || window.has_active_prompt()
                || !self.changes_local_valid(&capture, true, cx)
            {
                return;
            }
        } else if !self.changes_available(&capture, window, cx) {
            return;
        }
        if matches!(action, Action::Edit(_)) {
            self.open_cell(
                capture,
                point,
                matches!(action, Action::Edit(true)),
                window,
                cx,
            );
            return;
        }
        // Explicit Discard includes the uncommitted editor. Insert/Delete require it
        // to be staged/cancelled first, never silently commit text on focus loss.
        if capture.grid.read(cx).delegate().inline.is_some() && !matches!(action, Action::Discard) {
            return;
        }
        capture.grid.update(cx, |table, cx| {
            let g = table.delegate_mut();
            let selected: Vec<_> = g.selected_sources().iter().map(|&s| g.row_ids[s]).collect();
            let draft = g.draft.as_mut().unwrap();
            match action {
                Action::Insert => {
                    if let Some(id) = draft.insert() {
                        g.selection.select(
                            &[id],
                            CellPoint { row: id, column: 0 },
                            false,
                            true,
                            g.original.columns.len(),
                        );
                    }
                }
                Action::Delete => {
                    draft.delete(&selected);
                    g.selection = Selection::default();
                }
                Action::Discard => {
                    g.inline = None;
                    draft.discard();
                    g.selection = Selection::default();
                    g.edit_error = None;
                }
                _ => {}
            }
            g.project_draft();
            g.sync_details(window, cx);
            table.refresh(cx);
            cx.notify();
        });
        self.sync_changes_locks(capture.owner.document, cx);
        cx.notify();
    }
    fn open_cell(
        &mut self,
        capture: Capture,
        point: Option<CellPoint>,
        expanded: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let grid = capture.grid.read(cx).delegate();
        if grid.inline.is_some() {
            return;
        }
        let Some(point) = point.or(grid.selection.focus) else {
            return;
        };
        let draft = grid.draft.as_ref().unwrap();
        let Some(row) = draft.rows.iter().find(|r| r.id == point.row && !r.deleted) else {
            return;
        };
        let Some(meta) = draft.fingerprint.metadata.get(point.column) else {
            return;
        };
        let policy = ColumnPolicy::new(&draft.fingerprint.columns[point.column], meta);
        if !policy.editable {
            return;
        }
        let value = row.values[point.column].clone();
        let selection = grid.selection.clone();
        let token = draft.revision + 1;
        let (kind, text) = match value {
            backend::CellValue::Null => (Kind::Null, String::new()),
            backend::CellValue::Default => (Kind::Default, String::new()),
            backend::CellValue::Text(v) | backend::CellValue::Binary(v) => (Kind::Value, v),
        };
        let expanded =
            expanded || policy.multiline || text.len() > 160 || text.contains(['\n', '\r']);
        // Set BEFORE publishing editor/any callback; an already-pending browse
        // terminal must fail owns(), even though editing sends no database calls.
        if let Some(table) = self
            .tabs
            .iter_mut()
            .find(|t| t.id == capture.owner.document)
            .and_then(|t| t.catalog_document.as_mut())
            .and_then(|d| d.table.as_mut())
        {
            table.locks.inline_draft = true;
        }
        let focus = window.focused(cx);
        let editor = cx.new(|cx| {
            EditorState::new(window, cx)
                .line_number(false)
                .auto_close(false)
                .smart_indent(false)
                .submit_on_enter(!expanded)
                .default_value(text)
        });
        let owner = capture.owner.document;
        let entity = capture.grid.clone();
        let subscription = cx.subscribe_in(
            &editor,
            window,
            move |this, _, event: &InputEvent, window, cx| {
                if matches!(event, InputEvent::Change) {
                    entity.update(cx, |table, cx| {
                        let g = table.delegate_mut();
                        if let Some(inline) = g.inline.as_mut().filter(|i| i.token == token) {
                            // Typing into a NULL/DEFAULT placeholder is explicit text,
                            // including empty text; it never silently keeps the marker.
                            inline.kind = Kind::Value;
                            g.draft.as_mut().unwrap().touch();
                            cx.notify();
                        }
                    });
                    this.sync_changes_locks(owner, cx);
                    cx.notify();
                }
                if matches!(
                    event,
                    InputEvent::PressEnter {
                        secondary: false,
                        shift: false
                    }
                ) && entity
                    .read(cx)
                    .delegate()
                    .inline
                    .as_ref()
                    .is_some_and(|i| i.token == token && !i.expanded)
                    && let Some(capture) = entity.read(cx).delegate().edit_capture(entity.clone())
                {
                    this.finish_cell(capture, token, true, window, cx);
                }
            },
        );
        let weak = capture.grid.downgrade();
        let workspace = capture.owner.workspace.clone();
        let original_owner = capture.owner.clone();
        let fingerprint = capture.fingerprint.clone();
        let revision = capture.revision;
        let accessibility_guard = gpui_kit::component::input::InputAccessibilityGuard::default()
            .with_owner(move |window, cx| {
                let modal = window.has_active_dialog(cx) || window.has_active_prompt();
                !modal
                    && weak.upgrade().is_some_and(|g| {
                        let original = Capture {
                            owner: original_owner.clone(),
                            grid: g.clone(),
                            fingerprint: fingerprint.clone(),
                            revision,
                        };
                        workspace.upgrade().is_some_and(|w| {
                            !w.read(cx).closing && w.read(cx).changes_valid(&original, false, cx)
                        }) && g
                            .read(cx)
                            .delegate()
                            .inline
                            .as_ref()
                            .is_some_and(|i| i.token == token && !i.locked)
                    })
            });
        capture.grid.update(cx, |table, cx| {
            let g = table.delegate_mut();
            g.draft.as_mut().unwrap().touch();
            g.inline = Some(Inline {
                row: point.row,
                column: point.column,
                token,
                editor: editor.clone(),
                accessibility_guard,
                kind,
                expanded,
                locked: false,
                selection,
                focus,
                _subscription: subscription,
            });
            g.edit_error = None;
            cx.notify();
        });
        editor.update(cx, |editor, cx| editor.focus(window, cx));
        cx.notify();
    }
    pub(super) fn finish_cell(
        &mut self,
        capture: Capture,
        token: u64,
        stage: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.closing
            || (self.file_request.is_some()
                || (self.export_request.is_some() || self.run_file.is_some()))
            || (stage
                && (self.preview_blocks(capture.owner.document)
                    || self.changes_recovery_locked(capture.owner.document)))
            || (if stage {
                !self.changes_valid(&capture, false, cx)
            } else {
                !self.changes_local_valid(&capture, false, cx)
            })
        {
            return;
        }
        let editor = capture
            .grid
            .read(cx)
            .delegate()
            .inline
            .as_ref()
            .map(|i| i.editor.clone());
        if stage
            && editor.is_some_and(|editor| {
                editor.update(cx, |editor, cx| {
                    editor.marked_text_range(window, cx).is_some()
                })
            })
        {
            return;
        }
        capture.grid.update(cx, |table, cx| {
            let g = table.delegate_mut();
            let Some(inline) = g.inline.as_ref().filter(|i| i.token == token) else {
                return;
            };
            if stage {
                let policy = ColumnPolicy::new(
                    &g.original.columns[inline.column],
                    &g.metadata[inline.column],
                );
                let value = match inline.kind {
                    Kind::Null => backend::CellValue::Null,
                    Kind::Default => backend::CellValue::Default,
                    Kind::Value if policy.binary => {
                        backend::CellValue::Binary(inline.editor.read(cx).value().to_string())
                    }
                    Kind::Value => {
                        backend::CellValue::Text(inline.editor.read(cx).value().to_string())
                    }
                };
                if !g
                    .draft
                    .as_mut()
                    .unwrap()
                    .set(inline.row, inline.column, value)
                {
                    g.edit_error = Some(
                        if policy.binary {
                            "Enter valid Base64 for a binary value."
                        } else {
                            "This value is not allowed by the column's editing capabilities."
                        }
                        .into(),
                    );
                    cx.notify();
                    return;
                }
            }
            let inline = g.inline.take().unwrap();
            if !stage {
                g.selection = inline.selection;
            }
            g.draft.as_mut().unwrap().touch();
            g.edit_error = None;
            if stage {
                g.project_draft();
            }
            g.sync_details(window, cx);
            table.refresh(cx);
            if let Some(focus) = inline.focus {
                focus.focus(window, cx);
            }
            cx.notify();
        });
        self.sync_changes_locks(capture.owner.document, cx);
        cx.notify();
    }
    fn columns_dialog(&self, capture: &Capture, window: &mut Window, cx: &mut Context<Self>) {
        let g = capture.grid.read(cx).delegate();
        let fields: Vec<_> = g
            .original
            .columns
            .iter()
            .zip(&g.metadata)
            .enumerate()
            .map(|(i, (c, m))| {
                format!(
                    "{}. {} / {} / {} / PK {} / {} / default: {} / generated: {} / {}",
                    i + 1,
                    c.name,
                    m.native_type,
                    if m.nullable { "nullable" } else { "not null" },
                    m.primary_key,
                    if m.editable { "Editable" } else { "Read only" },
                    m.default.as_deref().unwrap_or("none"),
                    if m.generated.is_empty() {
                        "none"
                    } else {
                        &m.generated
                    },
                    m.edit_reason
                )
            })
            .collect();
        window.open_dialog(cx, move |dialog, _, _| {
            dialog
                .title("Columns")
                .accessibility_label("Columns")
                .child(
                    div()
                        .id("staged-columns")
                        .max_h(px(440.))
                        .overflow_y_scroll()
                        .children(fields.iter().cloned().map(|f| div().p_2().child(f))),
                )
        });
    }
    /// Task 20 loaded-export boundary: confirmed backend snapshot only. No
    /// reconnect/query and no projected inline/staged values. Caller must retain
    /// its captured result/snapshot through the native save dialog and recheck.
    pub(super) fn confirmed_loaded_table_snapshot(
        &self,
        id: DocumentId,
        cx: &App,
    ) -> Option<backend::ResultSet> {
        if self.closing
            || self.file_request.is_some()
            || self.preview_blocks(id)
            || self.changes_recovery_locked(id)
        {
            return None;
        }
        let tab = self.tabs.iter().find(|t| t.id == id)?;
        if tab.snapshot_locked() || tab.task.is_some() {
            return None;
        }
        let doc = tab.catalog_document.as_ref()?;
        let table = doc.table.as_ref()?;
        if doc.loading || table.pending.is_some() || table.locks.locked() {
            return None;
        }
        let grid = tab.grid.as_ref()?.read(cx).delegate();
        let loaded = tab.result_sets.first()?;
        if grid.has_drafts() || grid.snapshot != table.snapshot || &grid.original != loaded {
            return None;
        }
        Some(loaded.clone())
    }
    pub(super) fn changes_controls(
        &self,
        id: DocumentId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(tab) = self.tabs.iter().find(|t| t.id == id) else {
            return div().into_any_element();
        };
        let Some(grid) = &tab.grid else {
            return div().into_any_element();
        };
        let capture = self.changes_capture(id, cx);
        let enabled = capture
            .as_ref()
            .is_some_and(|c| self.changes_available(c, window, cx));
        let columns_enabled = !self.closing
            && !self.preview_blocks(id)
            && !window.has_active_dialog(cx)
            && capture
                .as_ref()
                .is_some_and(|c| self.changes_owner_valid(c, cx));
        let local_enabled = !self.closing
            && !self.preview_blocks(id)
            && (self.file_request.is_none() && self.export_request.is_none())
            && !window.has_active_dialog(cx)
            && !window.has_active_prompt()
            && capture
                .as_ref()
                .is_some_and(|c| self.changes_local_valid(c, true, cx));
        let g = grid.read(cx).delegate();
        let mut row = div()
            .px_3()
            .py_1()
            .flex()
            .flex_wrap()
            .items_center()
            .gap_2()
            .text_xs();
        if !g.readonly_reason.is_empty() {
            row = row.child(format!("Read only: {}", g.readonly_reason));
        } else if capture
            .as_ref()
            .is_some_and(|c| !self.catalog_target_valid(&c.owner.target))
        {
            row = row.child("Read only: This table belongs to an older connection context. Discard pending edits, then Refresh or reopen Data before editing.");
        }
        if let Some(draft) = &g.draft {
            row = row.child(format!("{} pending", draft.pending()));
        }
        for (n, label, action, available) in [
            (
                "edit",
                "Edit Cell",
                Action::Edit(false),
                g.inline.is_none() && g.selection.focus.is_some(),
            ),
            (
                "expanded",
                "Expanded Editor",
                Action::Edit(true),
                g.inline.is_none() && g.selection.focus.is_some(),
            ),
            ("insert", "Insert Row", Action::Insert, g.inline.is_none()),
            (
                "delete",
                "Delete Selected",
                Action::Delete,
                g.inline.is_none() && g.has_selection(),
            ),
            ("columns", "Columns...", Action::Columns, true),
            (
                "discard",
                "Discard",
                Action::Discard,
                g.has_drafts() && self.unknown_changes(id).is_none(),
            ),
        ] {
            let capture = capture.clone();
            row = row.child(
                Button::new(SharedString::from(format!("grid-{n}")))
                    .small()
                    .label(label)
                    .disabled(if matches!(action, Action::Columns) {
                        !columns_enabled
                    } else if matches!(action, Action::Discard) {
                        !local_enabled || !available
                    } else {
                        !enabled || !available
                    })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if let Some(c) = &capture {
                            this.changes_action(c.clone(), action, None, window, cx);
                        }
                    })),
            );
        }
        let preview_capture = capture.clone();
        row = row.child(
            Button::new("grid-preview")
                .small()
                .label("Preview SQL")
                .disabled(
                    !enabled
                        || self.changes_preview.is_some()
                        || g.inline.is_some()
                        || g.draft.as_ref().is_none_or(|d| d.pending() == 0),
                )
                .on_click(cx.listener(move |this, _, window, cx| {
                    if let Some(capture) = &preview_capture {
                        this.start_changes_preview(capture.clone(), window, cx);
                    }
                })),
        );
        if let Some(flow) = self.changes_preview.as_ref().filter(|f| f.document() == id) {
            row = row.child(flow.status.clone());
            row = row.child(
                Button::new("grid-cancel-preview")
                    .small()
                    .label(if flow.applying() {
                        "Stop Apply"
                    } else {
                        "Cancel Preview"
                    })
                    .disabled(flow.cancelling())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.stop_changes_preview(id, cx);
                    })),
            );
        }
        let apply_capture = capture.clone();
        row = row.child(
            Button::new("grid-apply")
                .small()
                .label("Apply")
                .disabled(
                    !enabled
                        || self.changes_preview.is_some()
                        || g.inline.is_some()
                        || g.draft.as_ref().is_none_or(|d| d.pending() == 0),
                )
                .on_click(cx.listener(move |this, _, window, cx| {
                    if let Some(capture) = &apply_capture {
                        this.start_changes_apply(capture.clone(), window, cx);
                    }
                })),
        );
        if let Some(inspected) = self.unknown_changes(id) {
            row = row.child("COMMIT outcome unknown. Inspect the affected rows, then discard local changes and reload.")
                .child(Button::new("inspect-unknown-apply").small().label("Inspect Data")
                    .on_click(cx.listener(move |this, _, window, cx| this.inspect_unknown_changes(id, window, cx))))
                .child(Button::new("discard-unknown-apply").small().label("Discard and Reload").disabled(!inspected)
                    .on_click(cx.listener(move |this, _, window, cx| this.discard_unknown_changes(id, window, cx))));
        } else if tab
            .catalog_document
            .as_ref()
            .and_then(|d| d.table.as_ref())
            .is_some_and(|t| t.recovery == tables::ChangesRecovery::ReloadRequired)
        {
            row = row
                .child("Changes require a successful reload before another Apply.")
                .child(
                    Button::new("reload-after-apply")
                        .small()
                        .label("Retry Reload")
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.reload_changes_snapshot(id, None, window, cx)
                        })),
                );
        }
        if let Some(error) = &g.edit_error {
            row = row.child(error.clone());
        }
        let mut view = div().flex().flex_col().child(row);
        if let Some(inline) = &g.inline {
            let c = capture.clone().unwrap();
            let token = inline.token;
            let policy = ColumnPolicy::new(
                &g.original.columns[inline.column],
                &g.metadata[inline.column],
            );
            let mut controls = div()
                .px_3()
                .py_1()
                .flex()
                .gap_2()
                .child(format!("Editing column {}", inline.column + 1));
            for (name, label, kind, allowed) in [
                ("value", "Value", Kind::Value, true),
                ("null", "NULL", Kind::Null, policy.null),
                ("default", "DEFAULT", Kind::Default, policy.default),
            ] {
                let c = c.clone();
                controls = controls.child(
                    Button::new(SharedString::from(format!("grid-kind-{name}")))
                        .small()
                        .label(label)
                        .disabled(!enabled || !allowed)
                        .selected(inline.kind == kind)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if this.closing
                                || this.preview_blocks(c.owner.document)
                                || this.changes_recovery_locked(c.owner.document)
                                || !this.changes_valid(&c, false, cx)
                            {
                                return;
                            }
                            c.grid.update(cx, |table, cx| {
                                let g = table.delegate_mut();
                                if let Some(i) = g.inline.as_mut().filter(|i| i.token == token) {
                                    i.kind = kind;
                                    g.draft.as_mut().unwrap().touch();
                                    cx.notify();
                                }
                            });
                            cx.notify();
                        })),
                );
            }
            if policy.empty {
                let c = c.clone();
                controls = controls.child(
                    Button::new("grid-empty")
                        .small()
                        .label("Empty String")
                        .disabled(!enabled)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            if this.closing
                                || this.preview_blocks(c.owner.document)
                                || this.changes_recovery_locked(c.owner.document)
                                || !this.changes_valid(&c, false, cx)
                            {
                                return;
                            }
                            c.grid.update(cx, |table, cx| {
                                let g = table.delegate_mut();
                                if let Some(i) = g.inline.as_mut().filter(|i| i.token == token) {
                                    i.kind = Kind::Value;
                                    i.editor.update(cx, |e, cx| e.set_value("", window, cx));
                                    g.draft.as_mut().unwrap().touch();
                                    cx.notify();
                                }
                            });
                            cx.notify();
                        })),
                );
            }
            for (name, label, stage) in [
                ("cancel", "Cancel Edit", false),
                ("stage", "Stage Change", true),
            ] {
                let c = c.clone();
                controls = controls.child(
                    Button::new(SharedString::from(format!("grid-{name}")))
                        .small()
                        .label(label)
                        .disabled(if stage { !enabled } else { !local_enabled })
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.finish_cell(c.clone(), token, stage, window, cx)
                        })),
                );
            }
            let expand = c.clone();
            controls = controls.child(
                Button::new("grid-expand-current")
                    .small()
                    .label(if inline.expanded { "Inline" } else { "Expand" })
                    .disabled(!enabled)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if this.closing
                            || this.preview_blocks(expand.owner.document)
                            || this.changes_recovery_locked(expand.owner.document)
                            || !this.changes_valid(&expand, false, cx)
                        {
                            return;
                        }
                        expand.grid.update(cx, |table, cx| {
                            if let Some(i) = table
                                .delegate_mut()
                                .inline
                                .as_mut()
                                .filter(|i| i.token == token)
                            {
                                i.expanded = !i.expanded;
                                i.editor.update(cx, |e, cx| {
                                    e.set_submit_on_enter(!i.expanded, cx);
                                    e.focus(window, cx);
                                });
                                cx.notify();
                            }
                        });
                        cx.notify();
                    })),
            );
            view = view.child(controls);
            if policy.binary {
                view = view.child(div().px_3().text_xs().child("Enter binary data as Base64."));
            }
            if inline.expanded {
                view = view.child(
                    div().h(px(180.)).key_context("DBeerGridField").child(
                        Editor::new(&inline.editor)
                            .readonly(!enabled)
                            .accessibility_guard(inline.accessibility_guard.clone())
                            .accessibility_id(format!(
                                "dbeer-cell-editor-{}-{}-{}",
                                id.0, inline.row, inline.column
                            ))
                            .aria_label("Edit exact typed cell value"),
                    ),
                );
            }
        }
        view.into_any_element()
    }
}

#[cfg(all(test, feature = "native-smoke"))]
pub(crate) mod tests;
