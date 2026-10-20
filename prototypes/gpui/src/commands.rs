//! One synchronous capture/availability/dispatch boundary for desktop commands.
//! Captures contain SQL and connection settings: deliberately never Debug/log them.
use super::*;
use gpui_kit::component::input;
use gpui_kit::component::menu::{DropdownMenu, PopupMenu, PopupMenuItem};
use std::sync::Arc;

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Deserialize)]
pub(super) enum CommandId {
    NewConnection,
    NewTab,
    OpenSql,
    SaveSql,
    SaveSqlAs,
    CloseTab,
    Quit,
    Undo,
    Redo,
    Cut,
    Copy,
    Paste,
    SelectAll,
    SearchCatalog,
    CatalogExpand,
    CatalogRefresh,
    CatalogInspect,
    CatalogDefinition,
    CatalogOpenData,
    CatalogGenerateSelect,
    CatalogCopyName,
    CatalogRetrySearch,
    CatalogRefreshDocument,
    TablePrevious,
    TableNext,
    TableSort,
    TableAddFilter,
    TableRemoveFilter,
    TableFilterColumn,
    TableFilterOperator,
    RunCurrent,
    Complete,
    RunScript,
    RunToJson,
    RunToCsv,
    Stop,
    History,
    GridCopy,
    ExportResultsJson,
    ExportResultsCsv,
    ExportResultsTsv,
    SelectProfile,
    NewProfileTab,
    Connect,
    Disconnect,
    EditProfile,
    DeleteProfile,
    ImportProfiles,
    ExportProfiles,
    ExportAllProfiles,
    CopyRows,
    NextResult,
    Appearance,
    ShortcutSettings,
    ToggleTheme,
    About,
}
#[derive(Clone, PartialEq, serde::Deserialize, Action)]
#[action(namespace = dbeer, no_json)]
pub(super) struct DispatchCommand {
    pub(super) command: CommandId,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum CommandOrigin {
    Button,
    Menu,
    Shortcut,
    System,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum CommandFocus {
    Editor,
    Grid,
    TextInput,
    Workspace,
}

pub(super) struct MenuOrigin {
    pub(super) focus: Option<FocusHandle>,
    pub(super) document: Option<DocumentId>,
}

impl CommandId {
    pub(super) const GROUPS: &'static [(&'static str, &'static [Self])] = &[
        (
            "File",
            &[
                Self::NewConnection,
                Self::NewTab,
                Self::OpenSql,
                Self::SaveSql,
                Self::SaveSqlAs,
                Self::CloseTab,
                Self::Quit,
            ],
        ),
        (
            "Edit",
            &[
                Self::Undo,
                Self::Redo,
                Self::Cut,
                Self::Copy,
                Self::Paste,
                Self::SelectAll,
                Self::SearchCatalog,
            ],
        ),
        (
            "Query",
            &[
                Self::RunCurrent,
                Self::Complete,
                Self::RunScript,
                Self::RunToJson,
                Self::RunToCsv,
                Self::Stop,
                Self::History,
                Self::CopyRows,
                Self::GridCopy,
                Self::ExportResultsJson,
                Self::ExportResultsCsv,
            ],
        ),
        (
            "Connections",
            &[
                Self::Connect,
                Self::Disconnect,
                Self::EditProfile,
                Self::DeleteProfile,
                Self::ImportProfiles,
                Self::ExportAllProfiles,
            ],
        ),
        (
            "Catalog",
            &[
                Self::CatalogInspect,
                Self::CatalogDefinition,
                Self::CatalogOpenData,
                Self::CatalogGenerateSelect,
                Self::CatalogCopyName,
                Self::CatalogRefresh,
            ],
        ),
        (
            "Table",
            &[
                Self::CatalogRefreshDocument,
                Self::TablePrevious,
                Self::TableNext,
                Self::TableSort,
                Self::TableAddFilter,
            ],
        ),
        (
            "Settings",
            &[
                Self::Appearance,
                Self::ShortcutSettings,
                Self::ToggleTheme,
                Self::About,
            ],
        ),
    ];
    pub(super) fn title(self) -> &'static str {
        match self {
            Self::NewConnection => "New Connection...",
            Self::NewTab | Self::NewProfileTab => "New SQL Tab",
            Self::OpenSql => "Open SQL...",
            Self::SaveSql => "Save SQL",
            Self::SaveSqlAs => "Save SQL As...",
            Self::CloseTab => "Close Tab",
            Self::Quit => "Quit DBeer",
            Self::Undo => "Undo",
            Self::Redo => "Redo",
            Self::Cut => "Cut",
            Self::Copy => "Copy",
            Self::Paste => "Paste",
            Self::SelectAll => "Select All",
            Self::SearchCatalog => "Find in Connections",
            Self::CatalogExpand => "Expand / Collapse",
            Self::CatalogRefresh => "Refresh",
            Self::CatalogInspect => "Structure and Definition...",
            Self::CatalogDefinition => "Definition...",
            Self::CatalogOpenData => "Open Data",
            Self::CatalogGenerateSelect => "Generate SELECT",
            Self::CatalogCopyName => "Copy Name",
            Self::CatalogRetrySearch => "Retry Search",
            Self::CatalogRefreshDocument => "Refresh Object Document",
            Self::TablePrevious => "Previous Table Page",
            Self::TableNext => "Next Table Page",
            Self::TableSort => "Cycle Server Sort for Filter Column",
            Self::TableAddFilter => "Add Server Filter",
            Self::TableRemoveFilter => "Remove Server Filter",
            Self::TableFilterColumn => "Choose Server Filter Column",
            Self::TableFilterOperator => "Choose Server Filter Operator",
            Self::RunCurrent => "Run Selection or Current Statement",
            Self::Complete => "Complete SQL",
            Self::RunScript => "Run Script",
            Self::RunToJson => "Run to JSON File...",
            Self::RunToCsv => "Run to CSV File...",
            Self::Stop => "Stop",
            Self::History => "SQL History...",
            Self::GridCopy => "Copy Grid Selection",
            Self::ExportResultsJson => "Export Loaded Results as JSON...",
            Self::ExportResultsCsv => "Export Loaded Results as CSV...",
            Self::ExportResultsTsv => "Export Loaded Results as TSV...",
            Self::SelectProfile => "Select",
            Self::Connect => "Connect / Refresh",
            Self::Disconnect => "Disconnect",
            Self::EditProfile => "Edit Connection...",
            Self::DeleteProfile => "Delete Connection...",
            Self::ImportProfiles => "Import Connections...",
            Self::ExportProfiles => "Export Connection...",
            Self::ExportAllProfiles => "Export Connections...",
            Self::CopyRows => "Copy Rows",
            Self::NextResult => "Next Result Set",
            Self::Appearance => "Appearance...",
            Self::ShortcutSettings => "Shortcuts...",
            Self::ToggleTheme => "Toggle Light / Dark",
            Self::About => "About DBeer",
        }
    }
    /// Explicit gates for workflows owned by later tasks. No enabled placeholder succeeds.
    pub(super) fn unavailable_reason(self) -> Option<&'static str> {
        match self {
            Self::ExportResultsTsv => {
                Some("Use Copy Rows for the loaded TSV view. File export supports JSON and CSV.")
            }

            _ => None,
        }
    }
    pub(super) fn loaded_export(self) -> bool {
        matches!(self, Self::ExportResultsJson | Self::ExportResultsCsv)
    }
    pub(super) fn catalog(self) -> bool {
        matches!(
            self,
            Self::CatalogExpand
                | Self::CatalogRefresh
                | Self::CatalogInspect
                | Self::CatalogDefinition
                | Self::CatalogOpenData
                | Self::CatalogGenerateSelect
                | Self::CatalogCopyName
                | Self::CatalogRetrySearch
        )
    }
    pub(super) fn table(self) -> bool {
        matches!(
            self,
            Self::TablePrevious
                | Self::TableNext
                | Self::TableSort
                | Self::TableAddFilter
                | Self::TableRemoveFilter
                | Self::TableFilterColumn
                | Self::TableFilterOperator
        )
    }
    fn edit_action(self) -> Option<Box<dyn Action>> {
        Some(match self {
            Self::Undo => Box::new(input::Undo),
            Self::Redo => Box::new(input::Redo),
            Self::Cut => Box::new(input::Cut),
            Self::Copy => Box::new(input::Copy),
            Self::Paste => Box::new(input::Paste),
            Self::SelectAll => Box::new(input::SelectAll),
            _ => return None,
        })
    }
    fn execution(self) -> bool {
        matches!(
            self,
            Self::RunCurrent | Self::RunScript | Self::RunToJson | Self::RunToCsv
        )
    }
    fn document(self) -> bool {
        self.execution()
            || self.loaded_export()
            || self.table()
            || matches!(
                self,
                Self::CatalogRefreshDocument
                    | Self::Complete
                    | Self::Stop
                    | Self::CloseTab
                    | Self::CopyRows
                    | Self::GridCopy
                    | Self::NextResult
                    | Self::SaveSql
                    | Self::SaveSqlAs
            )
    }
}

/// Pure availability input; contains no SQL, results or credentials.
#[derive(Clone)]
pub(super) struct CommandContext {
    pub(super) document: Option<DocumentId>,
    pub(super) focus: CommandFocus,
    pub(super) modal: bool,
    pub(super) closing: bool,
    pub(super) composing: bool,
    pub(super) busy: bool,
    pub(super) uncertain: bool,
    pub(super) snapshot_locked: bool,
    pub(super) settings_match: bool,
    pub(super) sql_document: bool,
    pub(super) catalog_document: bool,
    pub(super) has_grid: bool,
    pub(super) has_results: bool,
    pub(super) saved_profile: bool,
    pub(super) profile_busy: bool,
    pub(super) can_store: bool,
    pub(super) has_exports: bool,
    pub(super) transfer_pending: bool,
    pub(super) edit_available: bool,
}
pub(super) fn availability(
    command: CommandId,
    context: &CommandContext,
) -> Result<(), &'static str> {
    if let Some(reason) = command.unavailable_reason() {
        return Err(reason);
    }
    if command.edit_action().is_some() {
        return context
            .edit_available
            .then_some(())
            .ok_or("The focused control cannot perform this edit action.");
    }
    if context.closing {
        return Err("Workspace close is in progress.");
    }
    if context.modal || context.transfer_pending {
        return Err("Finish or cancel the active dialog first.");
    }
    if command.document() && context.document.is_none() {
        return Err("No document is available.");
    }
    if command.execution() {
        if matches!(context.focus, CommandFocus::TextInput | CommandFocus::Grid) {
            return Err("SQL commands are unavailable in text fields.");
        }
        if context.composing {
            return Err("Finish text composition before executing SQL.");
        }
        if !context.sql_document {
            return Err("This command requires a SQL document.");
        }
        if context.busy {
            return Err("The document already has an active operation.");
        }
        if context.uncertain {
            return Err("Acknowledge the unknown outcome and disconnect before retrying.");
        }
        if !context.settings_match {
            return Err("Disconnect the session before using changed connection settings.");
        }
    }
    if command == CommandId::Complete
        && (!context.sql_document || context.focus != CommandFocus::Editor || context.composing)
    {
        return Err("SQL completion requires a focused editor outside text composition.");
    }
    if command.loaded_export()
        && (!context.has_results || !context.has_grid || context.busy || context.uncertain)
    {
        return Err("No idle confirmed loaded result is available for export.");
    }
    if matches!(command, CommandId::SaveSql | CommandId::SaveSqlAs) && !context.sql_document {
        return Err("This command requires a SQL document.");
    }
    if (command.table() || command == CommandId::CatalogRefreshDocument)
        && (context.busy || context.uncertain || context.snapshot_locked || context.profile_busy)
    {
        return Err("Finish the active operation before replacing the table snapshot.");
    }
    if (command.table() || command == CommandId::CatalogRefreshDocument)
        && !context.catalog_document
    {
        return Err("This command requires a table or inspection document.");
    }
    if command == CommandId::Stop && !context.busy {
        return Err("No operation is running.");
    }
    if matches!(command, CommandId::CopyRows | CommandId::GridCopy)
        && (!context.has_grid || context.busy)
    {
        return Err("No idle loaded result is available.");
    }
    if command == CommandId::NextResult && (!context.has_results || context.busy) {
        return Err("No idle result set is available.");
    }
    if command == CommandId::GridCopy && context.focus == CommandFocus::TextInput {
        return Err("Copy in a field uses that field's text selection.");
    }
    if matches!(
        command,
        CommandId::Connect
            | CommandId::EditProfile
            | CommandId::DeleteProfile
            | CommandId::ExportProfiles
    ) && !context.saved_profile
    {
        return Err("Select a saved connection first.");
    }
    if command == CommandId::Connect && context.profile_busy {
        return Err("The connection already has an active operation.");
    }
    if matches!(
        command,
        CommandId::NewConnection
            | CommandId::EditProfile
            | CommandId::DeleteProfile
            | CommandId::ImportProfiles
    ) && !context.can_store
    {
        return Err("The disposable workspace has no writable profile library.");
    }
    if command == CommandId::ExportAllProfiles && !context.has_exports {
        return Err("There are no saved connections to export.");
    }
    // A live/transaction snapshot does not prohibit Run on its own session. Future
    // settings/profile-rebinding commands must explicitly account for this lock.
    let _ = context.snapshot_locked;
    Ok(())
}

#[derive(Clone)]
pub(super) struct DocumentCapture {
    pub(super) id: DocumentId,
    profile: ProfileId,
    pub(super) settings: Option<ConnectionProfile>,
    source_revision: u64,
    session_generation: u64,
    session: Option<String>,
    operation: Option<u64>,
    grid: Option<EntityId>,
    selected_result: usize,
    grid_snapshot: Option<u64>,
    grid_draft_revision: Option<u64>,
    changes_preview: Option<u64>,
}
#[derive(Clone)]
pub(super) struct CommandCapture {
    pub(super) command: CommandId,
    pub(super) origin: CommandOrigin,
    pub(super) context: CommandContext,
    pub(super) document: Option<DocumentCapture>,
    profile: Option<(ProfileId, Option<ConnectionProfile>)>,
    /// Full original source and selected fragment, captured before any await.
    pub(super) fragment: Option<Arc<sql::PreparedFragment>>,
    edit_focus: Option<FocusHandle>,
    pub(super) file: Option<Arc<crate::file_view::FileCapture>>,
    pub(super) catalog: Option<catalog::CatalogTarget>,
    pub(super) loaded_export: Option<Arc<export_view::ExportCapture>>,
    pub(super) table: Option<tables::Capture>,
    grid_publication: Option<grid_clipboard::Publication>,
}

/// Platform-neutral key suffixes. Platform::binding chooses Cmd on the Mac
/// development host and Ctrl on Windows/Linux. Task 28 replaces this table's
/// resolution with persisted overrides while retaining the same action path.
pub(super) const DEFAULT_SHORTCUTS: &[(&str, CommandId, &str)] = &[
    ("n", CommandId::NewConnection, "DBeerWorkspace"),
    ("t", CommandId::NewTab, "DBeerWorkspace"),
    ("o", CommandId::OpenSql, "DBeerWorkspace"),
    ("s", CommandId::SaveSql, "DBeerWorkspace"),
    ("shift-s", CommandId::SaveSqlAs, "DBeerWorkspace"),
    ("w", CommandId::CloseTab, "DBeerWorkspace"),
    ("q", CommandId::Quit, "DBeerWorkspace"),
    ("f", CommandId::SearchCatalog, "DBeerWorkspace"),
    ("enter", CommandId::RunCurrent, "DBeerSqlEditor > Input"),
    (
        "shift-enter",
        CommandId::RunScript,
        "DBeerSqlEditor > Input",
    ),
];

pub(super) fn install_keys(cx: &mut App) {
    results::interaction::install_keys(cx);
    // Primary-modifier Enter bindings exclude Alt combinations; native AltGr/IME
    // acceptance remains required. Ordinary Enter keeps the input action.
    // Query shortcuts are confined to the SQL editor subtree, never global inputs.
    for &(key, command, scope) in DEFAULT_SHORTCUTS {
        // Configurable commands resolve exact native events in the Workspace
        // capture callback. Generic GPUI aliases must never bypass InputSafety.
        if shortcuts::ConfigurableCommand::ALL
            .iter()
            .any(|id| id.command() == command)
        {
            continue;
        }
        cx.bind_keys([KeyBinding::new(
            &platform::binding(key),
            DispatchCommand { command },
            Some(scope),
        )]);
    }
    // Suppress only conflicting default Input aliases while the retained SQL
    // editor's current preference context owns that exact combination. NoAction
    // forwards the original KeyDown to shortcut_key; it grants no execution.
    for (key, scope) in [
        ("enter", "DBeerCapturePrimaryEnter > Input"),
        ("shift-enter", "DBeerCapturePrimaryShiftEnter > Input"),
    ] {
        cx.bind_keys([KeyBinding::new(
            &platform::binding(key),
            gpui_kit::NoAction,
            Some(scope),
        )]);
    }
    // Existing completion popup keys must reach their original raw callback
    // before Input aliases. This tag exists only while the popup is visible.
    for key in ["enter", "tab", "up", "down", "home", "end", "escape"] {
        cx.bind_keys([KeyBinding::new(
            key,
            gpui_kit::NoAction,
            Some("DBeerCompletionKeys > Input"),
        )]);
    }
    // Edit shortcuts remain the toolkit's original input actions, including its
    // platform Undo/Redo and IME behavior. Stop has no reference default shortcut.
}

impl Workspace {
    pub(super) fn shortcut_input_context(&self) -> gpui_kit::KeyContext {
        let mut context = gpui_kit::KeyContext::default();
        context.add("DBeerSqlEditor");
        if self.completion_popup_visible() {
            context.add("DBeerCompletionKeys");
        }
        let primary =
            if shortcuts::NativePlatform::current() == shortcuts::NativePlatform::MacDevelopment {
                shortcuts::Modifiers {
                    platform: true,
                    ..Default::default()
                }
            } else {
                shortcuts::Modifiers {
                    control: true,
                    ..Default::default()
                }
            };
        for (shift, tag) in [
            (false, "DBeerCapturePrimaryEnter"),
            (true, "DBeerCapturePrimaryShiftEnter"),
        ] {
            let expected =
                shortcuts::Shortcut::new("enter", shortcuts::Modifiers { shift, ..primary });
            if shortcuts::ConfigurableCommand::ALL.iter().any(|command| {
                self.shortcuts
                    .preferences
                    .shortcut(*command, shortcuts::NativePlatform::current())
                    .as_ref()
                    == Some(&expected)
            }) {
                context.add(tag);
            }
        }
        context
    }
    pub(super) fn forward_native_input_alias(
        &self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut App,
    ) {
        if window.default_prevented() || event.prefer_character_input {
            return;
        }
        let (tag, action): (&str, Box<dyn gpui_kit::Action>) =
            if event.keystroke.modifiers == gpui_kit::Modifiers::default() {
                let action: Box<dyn gpui_kit::Action> = match event.keystroke.key.as_str() {
                    "enter" => Box::new(input::Enter {
                        secondary: false,
                        shift: false,
                    }),
                    "tab" => Box::new(input::IndentInline),
                    "up" => Box::new(input::MoveUp),
                    "down" => Box::new(input::MoveDown),
                    "home" => Box::new(input::MoveHome),
                    "end" => Box::new(input::MoveEnd),
                    "escape" => Box::new(input::Escape),
                    _ => return,
                };
                ("DBeerCompletionKeys", action)
            } else {
                let shift = event.keystroke.modifiers.shift;
                let primary = if shortcuts::NativePlatform::current()
                    == shortcuts::NativePlatform::MacDevelopment
                {
                    shortcuts::Modifiers {
                        platform: true,
                        shift,
                        ..Default::default()
                    }
                } else {
                    shortcuts::Modifiers {
                        control: true,
                        shift,
                        ..Default::default()
                    }
                };
                if !shortcuts::Shortcut::new("enter", primary).matches_native(&event.keystroke) {
                    return;
                }
                (
                    if shift {
                        "DBeerCapturePrimaryShiftEnter"
                    } else {
                        "DBeerCapturePrimaryEnter"
                    },
                    Box::new(input::Enter {
                        secondary: true,
                        shift,
                    }),
                )
            };
        // The rendered tag records which native alias NoAction suppressed. It
        // may outlive a preference edit in this turn: native editing still has
        // authority, while shortcut_key alone checks CURRENT execution rights.
        if !window
            .context_stack()
            .iter()
            .any(|context| context.contains(tag))
        {
            return;
        }
        let Some(editor) = self
            .tabs
            .get(self.active)
            .filter(|tab| tab.kind == model::DocumentKind::Sql)
            .map(|tab| tab.editor.clone())
        else {
            return;
        };
        let focus = editor.focus_handle(cx);
        if !focus.is_focused(window) {
            return;
        }
        // Delegate synchronously to the exact original input node. No key is
        // synthesized, no query is dispatched, and focus cannot be retargeted.
        focus.dispatch_action(action.as_ref(), window, cx);
        window.prevent_default();
        cx.stop_propagation();
    }
    pub(super) fn command_context(
        &self,
        command: CommandId,
        target: Option<&ProfileId>,
        window: &mut Window,
        cx: &mut App,
    ) -> CommandContext {
        let modal = window.has_active_dialog(cx) || window.has_active_prompt();
        let tab = self.tabs.get(self.active);
        let profile = target
            .and_then(|id| self.profiles.iter().find(|p| &p.id == id))
            .or_else(|| {
                if command.document() {
                    tab.map(|t| self.profile(&t.profile))
                } else {
                    self.profiles.get(self.selected_profile)
                }
            });
        let focus = if tab.is_some_and(|t| t.editor.focus_handle(cx).is_focused(window)) {
            CommandFocus::Editor
        } else if self.search.focus_handle(cx).contains_focused(window, cx)
            || tab.is_some_and(|t| t.filter.focus_handle(cx).contains_focused(window, cx))
            || tab.is_some_and(|t| {
                t.grid_views.values().any(|grid| {
                    let g = grid.read(cx).delegate();
                    g.inline
                        .as_ref()
                        .is_some_and(|i| i.editor.focus_handle(cx).contains_focused(window, cx))
                        || g.details
                            .iter()
                            .any(|editor| editor.focus_handle(cx).contains_focused(window, cx))
                })
            })
            || window
                .context_stack()
                .iter()
                .any(|context| context.contains("Input"))
            || modal
        {
            // A field editor inside a grid remains a text input. Do not let its
            // ancestor grid replace text editing with SQL/grid commands.
            CommandFocus::TextInput
        } else if tab
            .and_then(|t| t.grid.as_ref())
            .is_some_and(|g| g.focus_handle(cx).contains_focused(window, cx))
        {
            CommandFocus::Grid
        } else {
            CommandFocus::Workspace
        };
        let edit_available = command
            .edit_action()
            .is_some_and(|action| window.is_action_available(action.as_ref(), cx));
        CommandContext {
            document: tab.map(|t| t.id),
            focus,
            modal,
            closing: self.closing,
            composing: false,
            busy: tab.is_some_and(|t| {
                t.busy()
                    || t.task.is_some()
                    || self.preview_blocks(t.id)
                    || self.run_file_pending(t.id)
            }),
            uncertain: tab.is_some_and(|t| t.uncertain),
            snapshot_locked: tab.is_some_and(|t| t.snapshot_locked()),
            settings_match: tab.is_none_or(|t| {
                self.document_profile_available(&t.profile)
                    && (t.session.is_none()
                        || t.session_settings == self.profile(&t.profile).config)
            }),
            sql_document: tab.is_some_and(|t| t.kind == model::DocumentKind::Sql),
            catalog_document: tab.is_some_and(|t| t.catalog_document.is_some()),
            has_grid: tab.is_some_and(|t| t.grid.is_some()),
            has_results: tab.is_some_and(|t| !t.result_sets.is_empty()),
            saved_profile: profile.is_some_and(|p| p.config.is_some()),
            profile_busy: profile.is_some_and(|p| p.task.is_some()),
            can_store: self.profile_store.is_some(),
            has_exports: self.profiles.iter().any(|p| p.config.is_some()),
            transfer_pending: self.transfer_task.is_some()
                || (self.file_request.is_some()
                    || self.export_request.is_some()
                    || (self.run_file.is_some() && command != CommandId::Stop)),
            edit_available,
        }
    }
    pub(super) fn capture_command(
        &self,
        command: CommandId,
        origin: CommandOrigin,
        target: Option<ProfileId>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<CommandCapture, &'static str> {
        if target
            .as_ref()
            .is_some_and(|id| self.profile_index(id).is_none())
        {
            return Err("The captured connection is no longer available.");
        }
        let mut context = self.command_context(command, target.as_ref(), window, cx);
        let command = if command == CommandId::Copy && context.focus == CommandFocus::Grid {
            CommandId::GridCopy
        } else {
            command
        };
        if (command.execution() || command == CommandId::Complete)
            && let Some(tab) = self.tabs.get(self.active)
        {
            context.composing = tab.editor.update(cx, |state, cx| {
                state.marked_text_range(window, cx).is_some()
            });
        }
        availability(command, &context)?;
        let tab = self.tabs.get(self.active);
        let profile = target
            .and_then(|id| self.profiles.iter().find(|p| p.id == id))
            .or_else(|| {
                if command.document() {
                    tab.map(|t| self.profile(&t.profile))
                } else {
                    self.profiles.get(self.selected_profile)
                }
            });
        let fragment = if command.execution() {
            let id = context.document.ok_or("No SQL document is available.")?;
            Some(Arc::new(self.prepare_command_execution(
                id,
                command == CommandId::RunScript,
                cx,
            )?))
        } else {
            None
        };
        let table = if command.table()
            || (command == CommandId::CatalogRefreshDocument
                && tab.is_some_and(|t| matches!(t.kind, model::DocumentKind::Table { .. })))
        {
            if origin != CommandOrigin::Button && context.focus == CommandFocus::TextInput {
                return Err("Table navigation is unavailable in text fields.");
            }
            let tab = tab.ok_or("No table document is available.")?;
            let doc = tab
                .catalog_document
                .as_ref()
                .and_then(|d| d.table.as_ref())
                .ok_or("No table document is available.")?;
            let action = match command {
                CommandId::TablePrevious => tables::Action::Previous,
                CommandId::TableNext => tables::Action::Next,
                CommandId::TableSort => tables::Action::Sort(doc.filter_column),
                CommandId::TableAddFilter => tables::Action::AddFilter,
                CommandId::TableRemoveFilter => tables::Action::RemoveFilter(0),
                CommandId::TableFilterColumn => tables::Action::SelectColumn(doc.filter_column),
                CommandId::TableFilterOperator => {
                    tables::Action::SelectOperator(doc.filter_operator)
                }
                _ => tables::Action::Refresh,
            };
            Some(self.capture_table(tab.id, action, cx)?)
        } else {
            None
        };
        Ok(CommandCapture {
            command,
            grid_publication: if command == CommandId::GridCopy {
                Some(
                    tab.and_then(|t| t.grid.as_ref())
                        .and_then(|g| g.read(cx).delegate().publication())
                        .ok_or("Select result cells before copying.")?,
                )
            } else {
                None
            },
            table,
            origin,
            catalog: if command.catalog() {
                let target = self
                    .catalog
                    .selected
                    .clone()
                    .ok_or("Select a catalog object first.")?;
                self.catalog_action_available(command, &target)?;
                Some(target)
            } else {
                None
            },
            loaded_export: if command.loaded_export() {
                Some(Arc::new(self.capture_loaded_export(
                    if command == CommandId::ExportResultsCsv {
                        exports::Format::Csv
                    } else {
                        exports::Format::Json
                    },
                    cx,
                )?))
            } else {
                None
            },
            context,
            document: tab.map(|t| DocumentCapture {
                id: t.id,
                profile: t.profile.clone(),
                settings: self.profile(&t.profile).config.clone(),
                source_revision: t.generation,
                session_generation: t.session_generation,
                session: t.session.clone(),
                operation: t.operation.as_ref().map(|op| op.operation),
                grid: t.grid.as_ref().map(|grid| grid.entity_id()),
                selected_result: t.selected_result,
                grid_snapshot: t
                    .grid
                    .as_ref()
                    .map(|grid| grid.read(cx).delegate().snapshot),
                grid_draft_revision: t
                    .grid
                    .as_ref()
                    .map(|grid| grid.read(cx).delegate().draft_revision()),
                changes_preview: self.changes_preview_token(t.id),
            }),
            profile: profile.map(|p| (p.id.clone(), p.config.clone())),
            fragment,
            edit_focus: window.focused(cx),
            file: if matches!(
                command,
                CommandId::OpenSql | CommandId::SaveSql | CommandId::SaveSqlAs
            ) {
                Some(Arc::new(self.capture_file(command, cx)?))
            } else {
                None
            },
        })
    }
    pub(super) fn capture_catalog_command(
        &self,
        command: CommandId,
        origin: CommandOrigin,
        target: catalog::CatalogTarget,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<CommandCapture, &'static str> {
        self.catalog_action_available(command, &target)?;
        // Use common modal/file/closing gates and immutable capture representation.
        let mut capture = self.capture_command(
            CommandId::SelectProfile,
            origin,
            Some(target.profile.clone()),
            window,
            cx,
        )?;
        capture.command = command;
        capture.catalog = Some(target);
        Ok(capture)
    }
    pub(super) fn catalog_command(
        &mut self,
        command: CommandId,
        origin: CommandOrigin,
        target: catalog::CatalogTarget,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Ok(capture) = self.capture_catalog_command(command, origin, target, window, cx) {
            self.dispatch_command(capture, window, cx);
        }
    }
    pub(super) fn prepare_command_execution(
        &self,
        id: DocumentId,
        script: bool,
        cx: &App,
    ) -> Result<sql::PreparedFragment, &'static str> {
        if !script {
            return self.prepare_execution(id, None, cx);
        }
        let tab = self
            .tabs
            .iter()
            .find(|t| t.id == id)
            .ok_or("SQL document is unavailable.")?;
        self.prepare_execution(id, Some(tab.editor.read(cx).value().to_string()), cx)
    }
    pub(super) fn command(
        &mut self,
        command: CommandId,
        origin: CommandOrigin,
        target: Option<ProfileId>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.invalidate_native_actions(cx);
        match self.capture_command(command, origin, target, window, cx) {
            Ok(capture) => self.dispatch_command(capture, window, cx),
            Err(reason) => {
                if let Some(tab) = self.tabs.get_mut(self.active) {
                    tab.status = reason.into();
                }
                cx.notify();
            }
        }
    }
    pub(super) fn capture_table_action(
        &mut self,
        id: DocumentId,
        action: tables::Action,
        origin: CommandOrigin,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<CommandCapture, &'static str> {
        let index = self
            .tabs
            .iter()
            .position(|t| t.id == id)
            .ok_or("The table document is unavailable.")?;
        let active = self.active;
        self.active = index;
        let capture = self.capture_command(action.command(), origin, None, window, cx);
        self.active = active;
        let mut capture = capture?;
        if let Some(table) = &mut capture.table {
            table.action = action;
        }
        self.capture_valid(&capture, cx)
            .then_some(capture)
            .ok_or("The table request context changed.")
    }
    pub(super) fn table_command(
        &mut self,
        id: DocumentId,
        action: tables::Action,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Ok(capture) =
            self.capture_table_action(id, action, CommandOrigin::Button, window, cx)
        {
            self.dispatch_command(capture, window, cx);
        }
    }
    pub(super) fn command_for_document(
        &mut self,
        command: CommandId,
        id: DocumentId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(index) = self.tabs.iter().position(|t| t.id == id) else {
            return;
        };
        let active = self.active;
        self.active = index;
        let capture = self.capture_command(command, CommandOrigin::Button, None, window, cx);
        self.active = active;
        if let Ok(capture) = capture {
            self.dispatch_command(capture, window, cx);
        }
    }
    pub(super) fn capture_valid(&self, capture: &CommandCapture, cx: &App) -> bool {
        if let Some(export) = &capture.loaded_export {
            return self.loaded_export_capture_valid(export, cx);
        }
        if let Some(table) = &capture.table {
            return self.table_capture_valid(table);
        }
        if let Some(target) = &capture.catalog {
            return self
                .catalog_action_available(capture.command, target)
                .is_ok();
        }
        if let Some(file) = &capture.file {
            return self.file_capture_valid(file, true, cx);
        }
        if capture.profile.as_ref().is_some_and(|(id, settings)| {
            !self
                .profiles
                .iter()
                .any(|p| &p.id == id && &p.config == settings)
        }) {
            return false;
        }
        if capture.command.document() {
            let Some(original) = capture.document.as_ref() else {
                return false;
            };
            let Some(tab) = self.tabs.iter().find(|t| t.id == original.id) else {
                return false;
            };
            if tab.profile != original.profile
                || self.profile(&tab.profile).config != original.settings
            {
                return false;
            }
            if (capture.command.execution() || capture.command == CommandId::Stop)
                && (tab.generation != original.source_revision
                    || tab.session_generation != original.session_generation
                    || tab.session != original.session
                    || tab.operation.as_ref().map(|op| op.operation) != original.operation)
            {
                return false;
            }
            if capture.command == CommandId::Stop
                && self.changes_preview_token(tab.id) != original.changes_preview
            {
                return false;
            }
            if matches!(
                capture.command,
                CommandId::CopyRows | CommandId::GridCopy | CommandId::NextResult
            ) && (tab.grid.as_ref().map(|grid| grid.entity_id()) != original.grid
                || tab.selected_result != original.selected_result
                || tab
                    .grid
                    .as_ref()
                    .map(|grid| grid.read(cx).delegate().snapshot)
                    != original.grid_snapshot
                || tab
                    .grid
                    .as_ref()
                    .map(|grid| grid.read(cx).delegate().draft_revision())
                    != original.grid_draft_revision)
            {
                return false;
            }
            if capture.command.execution()
                && capture.fragment.as_ref().is_some_and(|fragment| {
                    tab.editor.read(cx).value().as_ref() != fragment.source().text()
                })
            {
                return false;
            }
        }
        true
    }
    pub(super) fn dispatch_command(
        &mut self,
        capture: CommandCapture,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let command = capture.command;
        let _ = capture.origin;
        if let Some(action) = command.edit_action() {
            if let Some(focus) = capture.edit_focus
                && window.is_action_available_in(action.as_ref(), &focus)
            {
                focus.dispatch_action(action.as_ref(), window, cx);
            }
            return;
        }
        // Revalidate modal/busy state but keep the original document/focus. A tab
        // switch never redirects a captured menu/button to the newly active tab.
        if !self.capture_valid(&capture, cx) {
            return;
        }
        let mut context = capture.context.clone();
        context.modal = window.has_active_dialog(cx) || window.has_active_prompt();
        context.closing = self.closing;
        context.transfer_pending = self.transfer_task.is_some()
            || (self.file_request.is_some()
                || self.export_request.is_some()
                || (self.run_file.is_some() && command != CommandId::Stop));
        if let Some(original) = capture.document.as_ref()
            && let Some(tab) = self.tabs.iter().find(|t| t.id == original.id)
        {
            context.busy = tab.busy() || tab.task.is_some() || self.run_file_pending(tab.id);
            context.uncertain = tab.uncertain;
            context.settings_match = self.document_profile_available(&tab.profile)
                && (tab.session.is_none()
                    || tab.session_settings == self.profile(&tab.profile).config);
        }
        if availability(command, &context).is_err() {
            return;
        }
        let original_focus = capture.edit_focus.clone();
        let id = capture.document.as_ref().map(|t| t.id);
        let profile_id = capture.profile.as_ref().map(|(id, _)| id.clone());
        let index = profile_id.as_ref().and_then(|id| self.profile_index(id));
        if let Some(table) = capture.table {
            self.dispatch_table(table, window, cx);
            return;
        }
        match command {
            CommandId::Complete => {
                if let Some(id) = id {
                    self.start_completion(id, completion_view::Invocation::Manual, window, cx);
                    self.start_signatures(id, signature_view::Invocation::Manual, window, cx);
                }
            }
            CommandId::ExportResultsJson | CommandId::ExportResultsCsv => {
                if let Some(export) = capture.loaded_export {
                    self.start_loaded_export(export, window, cx);
                }
            }
            command if command.table() => {}
            command if command.catalog() => {
                if let Some(target) = capture.catalog {
                    self.dispatch_catalog(command, target, window, cx);
                }
            }
            CommandId::CatalogRefreshDocument => {
                if let Some(id) = id {
                    self.refresh_catalog_document(id, window, cx);
                }
            }
            CommandId::OpenSql | CommandId::SaveSql | CommandId::SaveSqlAs => {
                if let Some(file) = capture.file {
                    self.start_file_command(file, window, cx);
                }
            }
            CommandId::RunToJson | CommandId::RunToCsv => self.start_run_file(capture, window, cx),
            CommandId::RunCurrent | CommandId::RunScript => {
                if let (Some(id), Some(fragment)) = (id, capture.fragment) {
                    self.run_prepared(id, fragment, window, cx);
                }
            }
            CommandId::Stop => {
                if let Some(id) = id {
                    self.stop_document(id, cx);
                }
            }
            CommandId::NewTab => {
                if let Some(index) = index {
                    self.select_profile(index, cx);
                }
                self.add_tab(DemoTable::Products, window, cx);
            }
            CommandId::NewProfileTab => {
                if let Some(index) = index {
                    self.select_profile(index, cx);
                    self.add_sql_tab(
                        format!("SQL {}", self.tabs.len() + 1),
                        "SELECT 1;".into(),
                        window,
                        cx,
                    );
                }
            }
            CommandId::CloseTab => {
                if let Some(id) = id {
                    self.request_close_from_command(
                        CloseIntent::Tab(id),
                        original_focus,
                        window,
                        cx,
                    );
                }
            }
            CommandId::Quit => {
                self.request_close_from_command(CloseIntent::Window, original_focus, window, cx)
            }
            CommandId::NewConnection => self.edit_profile(None, window, cx),
            CommandId::SelectProfile => {
                if let Some(index) = index {
                    self.select_profile(index, cx);
                }
            }
            CommandId::Connect => {
                if let Some(index) = index {
                    self.connect_profile(index, window, cx);
                }
            }
            CommandId::Disconnect => {
                if let Some(index) = index {
                    if self.profiles[index].config.is_some() {
                        self.request_close_from_command(
                            CloseIntent::Profile(self.profiles[index].id.clone()),
                            original_focus,
                            window,
                            cx,
                        );
                    } else {
                        self.disconnect(index, cx);
                    }
                }
            }
            CommandId::EditProfile => {
                if let Some(index) = index {
                    self.edit_profile(Some(index), window, cx);
                }
            }
            CommandId::DeleteProfile => {
                if let Some(id) = profile_id {
                    self.delete_profile(id, window, cx);
                }
            }
            CommandId::ImportProfiles => self.import_profiles(window, cx),
            CommandId::ExportProfiles => self.export_profiles(profile_id, window, cx),
            CommandId::ExportAllProfiles => self.export_profiles(None, window, cx),
            CommandId::SearchCatalog => self.search.update(cx, |state, cx| state.focus(window, cx)),
            CommandId::Appearance => self.show_appearance_settings(original_focus, window, cx),
            CommandId::ShortcutSettings => self.show_shortcut_settings(original_focus, window, cx),
            CommandId::ToggleTheme => self.toggle_theme(window, cx),
            CommandId::About => Self::show_help(window, cx),
            CommandId::History => self.show_history(window, cx),
            CommandId::CopyRows => {
                if let Some(tab) = self.tabs.iter_mut().find(|t| Some(t.id) == id)
                    && let Some(grid) = &tab.grid
                {
                    cx.write_to_clipboard(ClipboardItem::new_string(
                        grid.read(cx).delegate().copy_tsv(),
                    ));
                    tab.status = "Visible rows copied as TSV.".into();
                }
            }
            CommandId::GridCopy => {
                if let Some(data) = capture.grid_publication {
                    let result = native_clipboard::publish(data, window, cx);
                    if let Some(tab) = self.tabs.iter_mut().find(|t| Some(t.id) == id) {
                        tab.status = match result {
                            Ok(()) => {
                                "Selected cells published as TSV and typed result data.".into()
                            }
                            Err(reason) => reason.into(),
                        };
                    }
                }
            }
            CommandId::NextResult => {
                if let Some(index) = self.tabs.iter().position(|t| Some(t.id) == id) {
                    let active = self.active;
                    self.active = index;
                    self.cycle_result(window, cx);
                    self.active = active;
                }
            }
            // All unavailable workflows above are refused by availability, never
            // reported as success. Their tasks replace this arm with handlers.
            _ => return,
        }
        cx.notify();
    }
    pub(super) fn command_enabled(
        &self,
        command: CommandId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let context = self.command_context(command, None, window, cx);
        let command = if command == CommandId::Copy && context.focus == CommandFocus::Grid {
            CommandId::GridCopy
        } else {
            command
        };
        availability(command, &context).is_ok()
            && (!command.loaded_export()
                || self
                    .tabs
                    .get(self.active)
                    .is_some_and(|tab| self.loaded_export_snapshot_available(tab.id, cx)))
            && (command != CommandId::GridCopy
                || self
                    .tabs
                    .get(self.active)
                    .and_then(|t| t.grid.as_ref())
                    .is_some_and(|grid| grid.read(cx).delegate().has_selection()))
            && (!command.catalog()
                || self
                    .catalog
                    .selected
                    .as_ref()
                    .is_some_and(|t| self.catalog_action_available(command, t).is_ok()))
    }
    /// macOS development host gets real app menus. Windows/Linux use the same
    /// descriptors in toolkit popup menus, capturing before those menus focus.
    pub(super) fn refresh_native_menus(&self, window: &mut Window, cx: &mut Context<Self>) {
        if !cfg!(target_os = "macos") {
            return;
        }
        let menus = CommandId::GROUPS
            .iter()
            .map(|(name, commands)| {
                let items = commands
                    .iter()
                    .map(|&command| {
                        let available = self.command_enabled(command, window, cx);
                        let label = command.unavailable_reason().map_or_else(
                            || self.command_label(command),
                            |reason| format!("{} ({reason})", self.command_label(command)),
                        );
                        MenuItem::action(label, DispatchCommand { command }).disabled(!available)
                    })
                    .collect::<Vec<_>>();
                Menu::new(*name).items(items)
            })
            .collect::<Vec<_>>();
        cx.set_menus(menus);
    }
    pub(super) fn command_menu_bar(&self, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .items_center()
            .gap_1()
            .h(px(30.))
            .children(CommandId::GROUPS.iter().map(|(name, commands)| {
                let view = cx.entity().downgrade();
                Button::new(SharedString::from(format!("commands-{name}")))
                    .ghost()
                    .small()
                    .label(*name)
                    .dropdown_menu(move |menu, window, cx| {
                        let Some(view) = view.upgrade() else {
                            return menu;
                        };
                        view.update(cx, |this, wcx| {
                            this.build_command_menu(menu, commands, None, window, wcx)
                        })
                    })
            }))
    }
    pub(super) fn build_command_menu(
        &mut self,
        mut menu: PopupMenu,
        commands: &[CommandId],
        target: Option<ProfileId>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> PopupMenu {
        // The builder runs before PopupMenu focuses itself. Capture the complete
        // operation here and dispatch that value after menu focus has changed.
        // Preserve the original input scope across switching between open menus.
        // A popup's own focus must never upgrade a text field to workspace SQL.
        if !window
            .context_stack()
            .iter()
            .any(|context| context.contains("PopupMenu"))
            || self.command_menu_origin.is_none()
        {
            self.command_menu_origin = Some(MenuOrigin {
                focus: window.focused(cx),
                document: self.tabs.get(self.active).map(|tab| tab.id),
            });
        }
        let origin = self
            .command_menu_origin
            .as_ref()
            .expect("captured menu origin");
        let original_document = origin.document;
        if let Some(focus) = &origin.focus {
            focus.focus(window, cx);
            menu = menu.action_context(focus.clone());
        }
        for &command in commands {
            let capture = if command.document()
                && original_document != self.tabs.get(self.active).map(|tab| tab.id)
            {
                Err("The original menu document changed.")
            } else {
                self.capture_command(command, CommandOrigin::Menu, target.clone(), window, cx)
            };
            let reason = capture.as_ref().err().copied();
            let label = reason.map_or_else(
                || self.command_label(command),
                |reason| format!("{} ({reason})", self.command_label(command)),
            );
            let view = cx.entity().downgrade();
            let capture = capture.ok();
            menu = menu.item(
                PopupMenuItem::new(label)
                    .disabled(capture.is_none())
                    .on_click(move |_, window, cx| {
                        if let Some(capture) = capture.clone() {
                            _ = view
                                .update(cx, |this, cx| this.dispatch_command(capture, window, cx));
                        }
                    }),
            );
        }
        menu
    }
}

#[cfg(test)]
mod tests;
