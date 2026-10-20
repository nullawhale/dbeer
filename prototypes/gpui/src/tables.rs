//! Dedicated read-only table documents. SQL, casts, quoting and PK ordering belong to Go.
use super::*;
use backend::{CatalogFilter, CatalogRequest, CatalogSort, FilterOperator, SortDirection};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};

pub(super) const PAGE_SIZE: usize = 200;
pub(super) const MAX_PAGE: u32 = 1_000_000;
pub(super) const NO_KEY_NOTICE: &str = "This object has no primary key. No stable page order is guaranteed, even when data is unchanged; rows may repeat or be skipped between pages.";

#[derive(Clone, Default, PartialEq, Eq)]
pub(super) struct Navigation {
    pub page: u32,
    pub sort: Vec<CatalogSort>,
    pub filters: Vec<CatalogFilter>,
}
impl Navigation {
    pub(super) fn request(&self, node: &catalog::NodeId) -> Option<CatalogRequest> {
        let (schema, object) = node.object()?;
        let mut request = catalog::object_request(schema, object, "browse");
        request.page = self.page;
        request.sort = self.sort.clone();
        request.filters = self.filters.clone();
        request.valid().then_some(request)
    }
}
/// Tasks 17-19 set these typed locks before beginning an inline/staged/preview/apply workflow.
/// Rechecked at capture, submission, each follow-up and completion; no replacement may discard drafts.
#[derive(Default)]
pub(super) struct ReplacementLocks {
    pub inline_draft: bool,
    pub staged_changes: usize,
    pub previewing: bool,
    pub applying: bool,
    pub outcome_unknown: bool,
    pub closing: bool,
}
impl ReplacementLocks {
    pub(super) fn locked(&self) -> bool {
        self.inline_draft
            || self.staged_changes != 0
            || self.previewing
            || self.applying
            || self.outcome_unknown
            || self.closing
    }
}
#[derive(Clone, PartialEq, Eq)]
pub(super) struct Request {
    pub revision: u64,
    pub snapshot: u64,
    pub navigation: Navigation,
}
/// Volatile mutation recovery. Disconnect never clears this state.
#[derive(Clone, Default, PartialEq, Eq)]
pub(super) enum ChangesRecovery {
    #[default]
    Ready,
    /// Authoritative commit (or explicit discard) requires a successful new snapshot.
    ReloadRequired,
    Unknown {
        inspection: Option<DocumentId>,
        inspected: bool,
    },
}
/// Created only by validated inspection snapshot publication, never tab opening.
pub(super) struct ChangesInspection {
    pub document: DocumentId,
    pub target: catalog::CatalogTarget,
    pub snapshot: u64,
}
pub(super) struct TableDocument {
    /// Navigation of the visible snapshot; pending requests never change these controls.
    pub navigation: Navigation,
    pub snapshot: u64,
    pub revision: u64,
    pub pending: Option<Request>,
    /// A full page only means another page is possible. It is never a total/count claim.
    pub possible_next: bool,
    pub locks: ReplacementLocks,
    pub recovery: ChangesRecovery,
    pub inspection_proof: Option<ChangesInspection>,
    pub filter_column: usize,
    pub filter_operator: FilterOperator,
    pub filter_value: Entity<InputState>,
}
impl TableDocument {
    pub(super) fn new(window: &mut Window, cx: &mut App) -> Self {
        Self {
            navigation: Navigation::default(),
            snapshot: 0,
            revision: 0,
            pending: None,
            possible_next: false,
            locks: ReplacementLocks::default(),
            recovery: ChangesRecovery::Ready,
            inspection_proof: None,
            filter_column: 0,
            filter_operator: FilterOperator::Eq,
            filter_value: cx
                .new(|cx| InputState::new(window, cx).placeholder("Value (binary: Base64)")),
        }
    }
    pub(super) fn begin(&mut self, navigation: Navigation) -> Option<Request> {
        if self.locks.locked() || self.pending.is_some() {
            return None;
        }
        self.revision = self.revision.checked_add(1)?;
        let request = Request {
            revision: self.revision,
            snapshot: self.snapshot,
            navigation,
        };
        self.pending = Some(request.clone());
        Some(request)
    }
    pub(super) fn owns(&self, request: &Request) -> bool {
        !self.locks.locked()
            && self.snapshot == request.snapshot
            && self.revision == request.revision
            && self.pending.as_ref() == Some(request)
    }
    pub(super) fn commit(&mut self, request: &Request, rows: usize) -> bool {
        if !self.owns(request) {
            return false;
        }
        self.navigation = request.navigation.clone();
        self.snapshot = request.revision;
        self.possible_next = rows == PAGE_SIZE && self.navigation.page < MAX_PAGE;
        self.pending = None;
        if self.recovery == ChangesRecovery::ReloadRequired {
            self.recovery = ChangesRecovery::Ready;
        }
        true
    }
    pub(super) fn fail(&mut self, request: &Request) {
        if self.pending.as_ref() == Some(request) {
            self.pending = None;
        }
    }
}
#[derive(Clone)]
pub(super) enum Action {
    Refresh,
    Previous,
    Next,
    Sort(usize),
    AddFilter,
    RemoveFilter(usize),
    SelectColumn(usize),
    SelectOperator(FilterOperator),
}
#[derive(Clone)]
pub(super) struct Capture {
    pub document: DocumentId,
    pub target: catalog::CatalogTarget,
    pub snapshot: u64,
    pub revision: u64,
    pub navigation: Navigation,
    pub action: Action,
    /// Captured exact bytes, including empty text and literal NULL. No numeric parsing.
    pub filter: Option<CatalogFilter>,
}
impl Action {
    pub(super) fn command(&self) -> CommandId {
        match self {
            Self::Refresh => CommandId::CatalogRefreshDocument,
            Self::Previous => CommandId::TablePrevious,
            Self::Next => CommandId::TableNext,
            Self::Sort(_) => CommandId::TableSort,
            Self::AddFilter => CommandId::TableAddFilter,
            Self::RemoveFilter(_) => CommandId::TableRemoveFilter,
            Self::SelectColumn(_) => CommandId::TableFilterColumn,
            Self::SelectOperator(_) => CommandId::TableFilterOperator,
        }
    }
}
pub(super) const OPERATORS: &[(FilterOperator, &str)] = &[
    (FilterOperator::Eq, "="),
    (FilterOperator::Ne, "<>"),
    (FilterOperator::Lt, "<"),
    (FilterOperator::Lte, "<="),
    (FilterOperator::Gt, ">"),
    (FilterOperator::Gte, ">="),
    (FilterOperator::Contains, "Contains"),
    (FilterOperator::IsNull, "IS NULL"),
    (FilterOperator::IsNotNull, "IS NOT NULL"),
];
pub(super) fn operator_label(operator: FilterOperator) -> &'static str {
    OPERATORS.iter().find(|(op, _)| *op == operator).unwrap().1
}
/// Metadata brackets the browse. Do not combine a pre-DDL structure with post-DDL rows.
/// Native type spellings in row descriptions differ from catalog types; compare exact catalog
/// metadata to itself and match every row/column ordinal and engine without Rust dialect rules.
pub(super) fn validate_snapshot(
    sets: &[backend::ResultSet],
    engine: &str,
    truncated: bool,
) -> Result<Vec<backend::TableColumnMetadata>, &'static str> {
    if truncated || sets.len() != 3 || sets.iter().any(|s| s.truncated) {
        return Err("The table snapshot is incomplete. Refresh and try again.");
    }
    let fields = [
        "name",
        "nativeType",
        "nullable",
        "default",
        "generated",
        "primaryKey",
        "editable",
        "editReason",
    ];
    for metadata in [&sets[0], &sets[2]] {
        if metadata.columns.len() != fields.len()
            || !metadata
                .columns
                .iter()
                .zip(fields)
                .enumerate()
                .all(|(ordinal, (column, field))| column.index == ordinal && column.name == field)
            || metadata.rows.iter().any(|row| row.len() != fields.len())
        {
            return Err("Table metadata is invalid.");
        }
    }
    let columns = sets[0]
        .table_metadata()
        .map_err(|_| "Table metadata is invalid.")?;
    let after = sets[2]
        .table_metadata()
        .map_err(|_| "Table metadata is invalid.")?;
    let mut primary: Vec<_> = columns
        .iter()
        .filter_map(|c| (c.primary_key != 0).then_some(c.primary_key))
        .collect();
    primary.sort_unstable();
    if !primary
        .iter()
        .enumerate()
        .all(|(ordinal, key)| *key as usize == ordinal + 1)
    {
        return Err("Table primary key metadata is invalid.");
    }
    let rows = &sets[1];
    if columns != after
        || columns.is_empty()
        || rows.columns.len() != columns.len()
        || rows.rows.len() > PAGE_SIZE
        || rows.rows.iter().any(|r| r.len() != columns.len())
        || !rows
            .columns
            .iter()
            .zip(&columns)
            .enumerate()
            .all(|(ordinal, (row, meta))| {
                row.index == ordinal && row.name == meta.name && row.engine == engine
            })
    {
        return Err(
            "The object or its columns changed while loading. Refresh to load a consistent snapshot.",
        );
    }
    Ok(columns)
}
impl Workspace {
    pub(super) fn capture_table(
        &self,
        id: DocumentId,
        action: Action,
        cx: &App,
    ) -> Result<Capture, &'static str> {
        let tab = self
            .tabs
            .iter()
            .find(|t| t.id == id)
            .ok_or("The table document is unavailable.")?;
        if !matches!(tab.kind, model::DocumentKind::Table { .. }) || tab.snapshot_locked() {
            return Err("This command requires an idle table document.");
        }
        let doc = tab
            .catalog_document
            .as_ref()
            .ok_or("Table metadata is unavailable.")?;
        let table = doc.table.as_ref().ok_or("This is not a table document.")?;
        if table.pending.is_some() || table.locks.locked() || doc.loading {
            return Err("Finish the active table workflow before replacing its snapshot.");
        }
        let index = self
            .profile_index(&tab.profile)
            .ok_or("The connection is unavailable.")?;
        let target = self
            .catalog_target(index, doc.target.node.clone())
            .ok_or("Connect this profile explicitly before browsing.")?;
        self.catalog_action_available(CommandId::CatalogOpenData, &target)?;
        let filter = doc
            .columns
            .get(table.filter_column)
            .map(|column| CatalogFilter {
                column: column.name.clone(),
                operator: table.filter_operator,
                value: if matches!(
                    table.filter_operator,
                    FilterOperator::IsNull | FilterOperator::IsNotNull
                ) {
                    None
                } else {
                    Some(table.filter_value.read(cx).value().to_string())
                },
            });
        let capture = Capture {
            document: id,
            target,
            snapshot: table.snapshot,
            revision: table.revision,
            navigation: table.navigation.clone(),
            action,
            filter,
        };
        self.table_navigation(&capture)?;
        Ok(capture)
    }
    pub(super) fn table_capture_valid(&self, capture: &Capture) -> bool {
        self.catalog_target_valid(&capture.target)
            && self
                .catalog_action_available(CommandId::CatalogOpenData, &capture.target)
                .is_ok()
            && self
                .tabs
                .iter()
                .find(|t| t.id == capture.document)
                .is_some_and(|tab| {
                    tab.profile == capture.target.profile
                        && !tab.snapshot_locked()
                        && tab.catalog_document.as_ref().is_some_and(|doc| {
                            doc.target.node == capture.target.node
                                && !doc.loading
                                && doc.table.as_ref().is_some_and(|t| {
                                    t.snapshot == capture.snapshot
                                        && t.revision == capture.revision
                                        && t.pending.is_none()
                                        && !t.locks.locked()
                                        && t.navigation == capture.navigation
                                })
                        })
                })
            && self.table_navigation(capture).is_ok()
    }
    fn table_navigation(&self, capture: &Capture) -> Result<Navigation, &'static str> {
        let doc = self
            .tabs
            .iter()
            .find(|t| t.id == capture.document)
            .and_then(|t| t.catalog_document.as_ref())
            .ok_or("The table is unavailable.")?;
        let table = doc.table.as_ref().ok_or("The table is unavailable.")?;
        let mut navigation = capture.navigation.clone();
        match &capture.action {
            Action::Refresh => {}
            Action::Previous => {
                navigation.page = navigation
                    .page
                    .checked_sub(1)
                    .ok_or("Already on the first page.")?
            }
            Action::Next => {
                if !table.possible_next {
                    return Err("No further page is available.");
                }
                navigation.page = navigation
                    .page
                    .checked_add(1)
                    .filter(|p| *p <= MAX_PAGE)
                    .ok_or("The browse page limit has been reached.")?;
            }
            Action::Sort(ordinal) => {
                let column = doc
                    .columns
                    .get(*ordinal)
                    .ok_or("This column is unavailable.")?
                    .name
                    .clone();
                navigation.sort = match navigation.sort.first().filter(|s| s.column == column) {
                    Some(s) if s.direction == SortDirection::Asc => vec![CatalogSort {
                        column,
                        direction: SortDirection::Desc,
                    }],
                    Some(_) => Vec::new(),
                    None => vec![CatalogSort {
                        column,
                        direction: SortDirection::Asc,
                    }],
                };
                navigation.page = 0;
            }
            Action::AddFilter => {
                navigation
                    .filters
                    .push(capture.filter.clone().ok_or("Choose a filter column.")?);
                navigation.page = 0;
            }
            Action::RemoveFilter(ordinal) => {
                if *ordinal >= navigation.filters.len() {
                    return Err("This filter changed.");
                }
                navigation.filters.remove(*ordinal);
                navigation.page = 0;
            }
            Action::SelectColumn(ordinal) => {
                if *ordinal >= doc.columns.len() {
                    return Err("This column changed.");
                }
            }
            Action::SelectOperator(_) => {}
        }
        navigation
            .request(&capture.target.node)
            .ok_or("The browse request exceeds the helper limits.")?;
        Ok(navigation)
    }
    pub(super) fn dispatch_table(
        &mut self,
        capture: Capture,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.table_capture_valid(&capture) {
            return;
        }
        let navigation = match self.table_navigation(&capture) {
            Ok(n) => n,
            Err(_) => return,
        };
        let doc = self
            .tabs
            .iter_mut()
            .find(|t| t.id == capture.document)
            .unwrap()
            .catalog_document
            .as_mut()
            .unwrap();
        let table = doc.table.as_mut().unwrap();
        match capture.action {
            Action::SelectColumn(ordinal) => {
                table.filter_column = ordinal;
                cx.notify();
                return;
            }
            Action::SelectOperator(operator) => {
                table.filter_operator = operator;
                cx.notify();
                return;
            }
            _ => {}
        }
        let Some(request) = table.begin(navigation) else {
            return;
        };
        doc.loading = true;
        self.start_table_work(capture.target, capture.document, request, window, cx);
    }
    pub(super) fn table_controls(
        &self,
        id: DocumentId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tab = self.tabs.iter().find(|t| t.id == id).unwrap();
        let doc = tab.catalog_document.as_ref().unwrap();
        let table = doc.table.as_ref().unwrap();
        let enabled = self.capture_table(id, Action::Refresh, cx).is_ok()
            && !self.closing
            && (self.file_request.is_none() && self.export_request.is_none())
            && !window.has_active_dialog(cx)
            && !window.has_active_prompt()
            && self.transfer_task.is_none();
        let view = cx.entity().downgrade();
        let columns: Vec<_> = doc.columns.iter().map(|c| c.name.clone()).collect();
        let sort_columns = columns.clone();
        let column_view = view.clone();
        let operator_view = view.clone();
        let mut controls = div()
            .flex()
            .flex_col()
            .gap_2()
            .p_2()
            .border_b_1()
            .border_color(cx.theme().border)
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child("Server table navigation")
                    .child(
                        Button::new("table-previous")
                            .small()
                            .label("Previous")
                            .disabled(!enabled || table.navigation.page == 0)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.table_command(id, Action::Previous, window, cx)
                            })),
                    )
                    .child(format!(
                        "Page {} (200 rows per page)",
                        table.navigation.page + 1
                    ))
                    .child(
                        Button::new("table-next")
                            .small()
                            .label("Next")
                            .disabled(!enabled || !table.possible_next)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.table_command(id, Action::Next, window, cx)
                            })),
                    )
                    .child(
                        Button::new("table-server-sort")
                            .small()
                            .label("Sort column...")
                            .disabled(!enabled)
                            .dropdown_menu(move |mut menu, window, cx| {
                                for (ordinal, name) in sort_columns.iter().enumerate() {
                                    let view = view.clone();
                                    let capture = view
                                        .update(cx, |this, cx| {
                                            this.capture_table_action(
                                                id,
                                                Action::Sort(ordinal),
                                                CommandOrigin::Button,
                                                window,
                                                cx,
                                            )
                                        })
                                        .ok()
                                        .and_then(Result::ok);
                                    menu = menu.item(
                                        PopupMenuItem::new(name.clone())
                                            .disabled(capture.is_none())
                                            .on_click(move |_, window, cx| {
                                                if let Some(capture) = capture.clone() {
                                                    _ = view.update(cx, |this, cx| {
                                                        this.dispatch_command(capture, window, cx)
                                                    });
                                                }
                                            }),
                                    );
                                }
                                menu
                            }),
                    )
                    .child(
                        table
                            .navigation
                            .sort
                            .first()
                            .map(|s| {
                                format!(
                                    "{} {}",
                                    s.column,
                                    if s.direction == SortDirection::Asc {
                                        "ASC"
                                    } else {
                                        "DESC"
                                    }
                                )
                            })
                            .unwrap_or_else(|| "Adapter default order".into()),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .child("Server filter")
                    .child(
                        Button::new("table-filter-column")
                            .small()
                            .disabled(!enabled)
                            .label(
                                columns
                                    .get(table.filter_column)
                                    .cloned()
                                    .unwrap_or_else(|| "Choose column".into()),
                            )
                            .dropdown_menu(move |mut menu, window, cx| {
                                for (ordinal, name) in columns.iter().enumerate() {
                                    let view = column_view.clone();
                                    let capture = view
                                        .update(cx, |this, cx| {
                                            this.capture_table_action(
                                                id,
                                                Action::SelectColumn(ordinal),
                                                CommandOrigin::Button,
                                                window,
                                                cx,
                                            )
                                        })
                                        .ok()
                                        .and_then(Result::ok);
                                    menu = menu.item(
                                        PopupMenuItem::new(name.clone())
                                            .disabled(capture.is_none())
                                            .on_click(move |_, window, cx| {
                                                if let Some(capture) = capture.clone() {
                                                    _ = view.update(cx, |this, cx| {
                                                        this.dispatch_command(capture, window, cx)
                                                    });
                                                }
                                            }),
                                    );
                                }
                                menu
                            }),
                    )
                    .child(
                        Button::new("table-filter-operator")
                            .small()
                            .disabled(!enabled)
                            .label(operator_label(table.filter_operator))
                            .dropdown_menu(move |mut menu, window, cx| {
                                for &(operator, label) in OPERATORS {
                                    let view = operator_view.clone();
                                    let capture = view
                                        .update(cx, |this, cx| {
                                            this.capture_table_action(
                                                id,
                                                Action::SelectOperator(operator),
                                                CommandOrigin::Button,
                                                window,
                                                cx,
                                            )
                                        })
                                        .ok()
                                        .and_then(Result::ok);
                                    menu = menu.item(
                                        PopupMenuItem::new(label)
                                            .disabled(capture.is_none())
                                            .on_click(move |_, window, cx| {
                                                if let Some(capture) = capture.clone() {
                                                    _ = view.update(cx, |this, cx| {
                                                        this.dispatch_command(capture, window, cx)
                                                    });
                                                }
                                            }),
                                    );
                                }
                                menu
                            }),
                    )
                    .when(
                        !matches!(
                            table.filter_operator,
                            FilterOperator::IsNull | FilterOperator::IsNotNull
                        ),
                        |row| {
                            row.child(
                                div().w(px(230.)).child(
                                    Input::new(&table.filter_value).small().disabled(!enabled),
                                ),
                            )
                        },
                    )
                    .child(
                        Button::new("table-add-filter")
                            .small()
                            .label("Add Filter")
                            .disabled(
                                !enabled
                                    || doc.columns.is_empty()
                                    || table.navigation.filters.len() >= 32,
                            )
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.table_command(id, Action::AddFilter, window, cx)
                            })),
                    ),
            );
        for (ordinal, filter) in table.navigation.filters.iter().enumerate() {
            controls = controls.child(
                div()
                    .flex()
                    .gap_2()
                    .child(format!(
                        "{} {} {}",
                        filter.column,
                        operator_label(filter.operator),
                        filter
                            .value
                            .as_ref()
                            .map(|v| format!("{v:?}"))
                            .unwrap_or_default()
                    ))
                    .child(
                        Button::new(("table-remove-filter", ordinal))
                            .xsmall()
                            .label("Remove")
                            .disabled(!enabled)
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.table_command(id, Action::RemoveFilter(ordinal), window, cx)
                            })),
                    ),
            );
        }
        controls.into_any_element()
    }
}
#[cfg(test)]
mod tests;
