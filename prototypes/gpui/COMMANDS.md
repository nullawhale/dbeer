# GPUI desktop command contract

Tasks 9-13 are code-ready with runtime execution deferred to final integration.
The macOS product remains SwiftUI/AppKit. This implementation targets Windows
11 x64 and Ubuntu 24.04 x64 (Wayland and X11); Mac GPUI is development only.
Task 2 and all 171 native acceptance cells remain open. Builds do not depend
on ignored planning files.

## Capture, availability and dispatch

`src/commands.rs` defines `CommandId`, titles/menu groups, explicit unavailable
workflow reasons, `DEFAULT_SHORTCUTS`, `CommandContext`, `CommandCapture` and
one command dispatcher. Commands are not authorization to execute SQL: the
helper's classification, policy, assessment and captured-session review remain
authoritative. SQL-bearing captures intentionally have no Debug implementation.

- `Workspace::command(id, origin, profile_target, window, cx)` synchronously
  captures and dispatches a top-level action. UI buttons, profile/catalog
  controls, desktop menus and shortcuts enter this path or dispatch an already
  captured value. Profile targets are stable IDs; missing targets fail closed.
- `capture_command(...) -> Result<CommandCapture, &'static str>` captures the
  original document ID, profile/settings, source revision, session identity and
  generation, operation identity, selected result/grid entity, exact immutable
  source/selection fragment and focused Edit target before asynchronous work.
- `availability(id, &CommandContext)` is pure. `command_context` supplies editor,
  grid and text-input focus, active dialog/prompt, closing/transfer state,
  document busy/unknown state, session-setting compatibility and profile/storage
  availability. A cell field editor remains a text input even inside a grid.
- `dispatch_command(capture, ...)` checks availability again against the
  original target, then `capture_valid(&capture, cx)` checks stable identities,
  source revision and exact source text, session/operation identity and result
  snapshot identity where relevant. A tab switch does not retarget an operation.
  An obsolete Stop cannot cancel a later operation. Menu focus is not reused as
  the original command focus.
- `command_for_document(id, document_id, ...)` captures an explicitly addressed
  tab action, including a close button on a background tab. It restores the
  current tab before dispatch. No close button calls tab removal directly.

New SQL Tab always reaches the established local-document constructor after
selecting a still-valid captured profile, if any. Ordinary zero-profile startup
therefore creates independent empty unbound drafts without helper, credential or
session authority. A captured saved/demo profile stays the intended target across
selection changes; stale captures, active modal state and closing still refuse.
Explicit NewProfileTab retains its separate profile requirement. Deleting the
last saved profile preserves existing drafts and their retained missing binding;
creating another local tab remains usable and disconnected under that existing
binding policy. The actual startup/command/deletion and guard regressions are
prepared and unrun.

A transaction/session snapshot does not prohibit SQL on its own matching
session. Unknown outcomes and changed session settings prohibit another Run;
profile edits, deletion, disconnect and every close request enter the existing
captured close decisions. Save/Delete confirmation callbacks and execution
review/transaction continuations retain their original immutable requests;
they are workflow continuations, not new commands targeted at current focus.
Task 22 now supplies the composed captured token/phase close graph for staged
edits, fresh-session Apply, files and full/loaded exports (CLOSE.md).

## Desktop menus and input

Windows/Linux render File, Edit, Query, Connections and Settings menus with
GPUI Kit 0.7.3 `DropdownMenu`/`PopupMenu`. Menu construction captures operations
before the popup takes focus, retaining the first input/document origin across
switching between open menus. Each item carries its immutable capture, disabled
items explain their gate, and dispatch revalidates the original target. The Mac
development host also installs actual GPUI application menus with `set_menus`.
Titlebar close, compositor/system window close, workspace Quit and existing Mac
Dock termination requests enter the guarded close flow; only acknowledged
window removal permits the existing last-window application exit.

Undo/Redo/Cut/Copy/Paste/Select All dispatch the toolkit's original input action
on the captured focused control. Input shortcuts remain toolkit bindings, so
text selection, password handling, Undo, paste and IME use that control's own
semantics, including fields in dialogs. Task 16 routes focused grid Edit Copy and primary+C through GridCopy with
captured document/entity/result/snapshot and prepared actual-selection payloads.
Focused text/details field editors retain normal text Copy. The separate Copy
Rows action retains loaded-view TSV behavior; see GRID.md for native formats.

| Default on Windows/Linux | Command / scope |
| --- | --- |
| Ctrl+N | New Connection; workspace |
| Ctrl+T | New SQL Tab; captured selected profile or unbound local draft |
| Ctrl+W | Close captured tab through close decisions |
| Ctrl+Q | Guarded workspace Quit |
| Ctrl+F | Find in Connections |
| Ctrl+Enter | Run Selection or Current Statement; SQL editor only |
| Ctrl+Shift+Enter | Run Script; immutable whole-source review, then ordered execution |
| Ctrl+O / Ctrl+S / Ctrl+Shift+S | Native Open SQL / Save SQL / Save SQL As; captured document/source |

The Mac development host uses Cmd in place of Ctrl. Stop has no reference
default shortcut. The former prototype Ctrl+. and Ctrl+Shift+L bindings are
removed; Stop and the temporary theme toggle remain explicit menu/buttons.
Configurable SQL shortcuts require original focused editor scope and use the
Workspace's exact native capture callback before native input actions. They do not install global key observers,
intercept ordinary typing, or bind Alt/AltGr combinations. Marked editor text
refuses Run. Exact-modifier checks are prepared, but actual keyboard layouts,
IME, AltGr/synthesized native modifier sequences and native menu focus remain
required desktop acceptance; static checks do not establish those observations.

## Extension points for later tasks

- **Task 10 implemented:** `RunScript` shares the common dispatcher and captured
  `Arc<PreparedFragment>` with Run. `prepare_command_execution(document, script,
  cx)` captures the whole unchanged source for scripts. `run_prepared` and
  `run_live_prepared` accept it without rereading current selection. Every script
  reviews the complete source/classification, including helper allow; Cancel is
  the Return/Escape default. Ordered statement terminals retain their own result
  sets and share one cumulative display budget. Current/selection Run preserves
  the MySQL selected-routine/multiple-statement refusal. See [SCRIPTS.md](SCRIPTS.md)
  for exact grant, Stop, source-feedback, close and persistence boundaries.
- **Task 11 implemented, Task 22 extension:** keep every close origin in `Quit`,
  `CloseTab`, `Disconnect`, profile mutation and captured `CloseFlow`/`CloseToken`
  continuations (CLOSE.md). Repeated commands never replace a selected resolution.
  Owned-HWND Windows session-end requests queue the same system Quit command;
  its native compilation/runtime remains open. Task 29 must attach its frozen Ubuntu
  GNOME session-manager adapter through the maintained common-close hook. No direct exit/tab-removal UI path is allowed.
- **Task 12 implemented:** OpenSql/SaveSql/SaveSqlAs dispatch captured full
  source/file metadata to native pickers and prepared atomic writes (FILES.md).
  Dispatch requires exact source; continuations retain original ownership while
  allowing newer edits to remain dirty. file_request blocks overlapping work and
  Task 22 close now captures that owner and drains its original future before teardown.
  DocumentState.file exposes exact saved-source/file-revision hooks for Task 13.
- **Task 13 implemented:** History is enabled and opens the managed source/outcome
  panel with recording toggle, disconnected new-UUID reopen, clear history, guarded
  clear drafts and storage retry. See RESTORATION.md for the explicit safe DTO,
  ordered debounce and awaited intent-specific final close flush. Physical sessions
  and authorizations never restore.
- **Task 16 implemented:** GridCopy and focused native Edit Copy retain immutable
  document/grid/result/snapshot plus prepared actual selection payloads. Keyboard,
  context copy and row details preserve source row IDs and ordinal columns.
  Text-input precedence and SQL grid/field refusal remain. Copy Rows is separate;
  see GRID.md for reconciliation, native-format mapping and Task 17 APIs.
- **Task 20 implemented:** ExportResultsJson/ExportResultsCsv menu/toolbar actions retain the immutable physical loaded result and original document/grid/snapshot/profile/settings across review, native Save and atomic publication. Counts/truncation and CSV marker review precede the picker. See EXPORTS.md. TSV remains the separate Copy Rows view action.
- **Task 21 implemented:** RunToJson/RunToCsv capture exactly one resolved SQL statement, format/marker and native destination before credentials, then assess and execute the exact export once on the original SQL-tab session. Full progress/Stop/terminal and SQL-versus-file recovery retain the original helper. See RUN_TO_FILE.md.
- **Tasks 26/27:** Appearance and the normalized theme library are enabled in
  the original retained Settings dialog, with native import/review/removal,
  independent live palettes and original latest-save close owners.
- **Task 28:** `DEFAULT_SHORTCUTS` remains the sole default/fixed descriptor source.
  Five configurable commands use current persisted Preferences through the exact
  synchronous native callback, entering Workspace::command with Shortcut origin.
  Their generic alias bindings are skipped; native editor/marked-text/dead-key,
  field/modal/close and original-operation gates remain. Settings > Shortcuts
  mounts the focused retained recorder in the same dialog. Menu/toolbar labels
  and tooltips read that same preference value; explicit Unbound/reset/reload/
  recovery refresh all consumers. See SHORTCUTS_CORE.md for persistence/finalizer
  authority and pending runtime/native verification.

## Verification status

Task 10 script-specific prepared cases and static verification are in SCRIPTS.md
and IMPLEMENTATION.md. All runtime/native acceptance remains deferred.

Prepared pure and headless cases cover unavailable workflows, editing focus,
modal/busy/unknown/settings locks, marked text, scoped primary versus Alt
modifiers, equal button/menu/shortcut captures, tab switches, source/session/
operation staleness, parse refusal before helper startup and focused fields.
They are test code, not executed evidence.

Completed static checks only: default/native-smoke `check --locked
--all-targets`, default/native-smoke all-target Clippy with warnings denied,
formatting and whitespace checks. Logs are ignored `build/gpui/task9-*.log`.
No Rust, Swift, Go, database, native UI or credential tests ran. The existing
`block 0.1.6` Cargo future-incompatibility notice remains.

Run at final integration, then record completed summaries and explicit skips:

```sh
./scripts/gpui-prototype.sh test --locked -- commands::tests
./scripts/gpui-prototype.sh test --locked --features native-smoke -- commands::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- workspace_tests --test-threads=1
```

Use the supported native Windows/Linux build runners for their matching host.
On Windows 11 and Ubuntu Wayland/X11, verify each menu/button/shortcut origin,
background-tab close, dialogs/settings fields, grid field editing, Undo/Redo,
clipboard, AltGr and IME, busy/unknown outcomes, selection/current/script defaults,
source edits/tab switches during review and chooser callbacks, titlebar/system
close and guarded Quit. None of these native observations is claimed complete.

Task 14 adds typed CatalogTarget capture and common catalog buttons/context/desktop menu dispatch, including object actions and document Refresh (CATALOG.md). Node identity includes exact helper overload identity; actions never re-read selection after awaiting. Modal/file/closing gates remain common.

Task 15 adds common Table previous/next, server sort and typed filter/draft control
commands. Table captures retain original document, service/settings/helper,
committed navigation, revision and snapshot. Dropdown items capture on menu
construction. Busy/unknown/file/modal/closing and typed future replacement locks
are rechecked before submission and atomic completion. Local loaded-grid sort and
filter remain distinct from server actions. See TABLES.md for apply/Enter and
fixed-page semantics; no table command executes/classifies SQL or auto-connects.

Task 17 local editing controls/context Edit use `changes_view::Capture`, retaining
original document/grid/result/snapshot/capabilities/draft revision and original
profile/service ownership. Copy captures additionally retain the draft revision.
Inline/expanded text fields receive explicit focus precedence, so grid navigation
and SQL Run cannot consume their editing input. Local staging sends no helper
requests; Preview/Apply remain unavailable. See CHANGES.md for exact APIs/cases.

Task 18 routes Query Stop through captured changes-preview tokens as well as SQL
operations. The exact original preview/assessment query and helper session remain
owned through drain/cleanup; an old Stop capture cannot cancel a later preview.
Preview SQL/Cancel Preview are explicit captured table controls. Apply stays disabled.
See PREVIEW.md for session, policy, close and final-integration boundaries.

Task 22 routes native/system window close directly into the same captured graph
while preserving an existing owned review/picker. Menu/tab/disconnect commands
retain their pre-popup input focus for close Cancel. New commands stay blocked
while closing; captured existing owner continuations use their exact tokens.
Original physical SQL helper identity survives terminal completion, and neither
transaction resolution nor disconnect can route old IDs to Workspace.backend.
The temporary Appearance/Shortcut UI notes above remain pending Tasks 26/28.
