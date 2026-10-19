# Changelog

## Next release — unreleased

- SQL completion highlights matching parts of each name, such as the `o` and `i` in `order_items` for `oi`. Highlighting supports abbreviations, typos, and Unicode, uses bold text and editor theme colors, and persists when the selected row or theme changes.
- Completion search supports word-part abbreviations (`oi` → `order_items`), snake_case and camelCase names, minor typos, and adjacent letter transpositions. Columns in the current query and CTEs take priority among candidates of comparable match quality; exact names rank above typo corrections. Candidates are ranked before the completion count limit is applied.
- Function signature help shows argument names and types, return types, and highlights the current argument while typing or moving the caret. It follows nested calls, overloads, named/default/variadic arguments, and SUBSTRING FROM/FOR syntax. Common built-ins work offline; PostgreSQL/MySQL stored-function signatures load through the connected profile's metadata service. The non-focusing panel supports editor themes, Escape, and native Undo.
- SQL completion uses a separate offline helper module with clause-aware candidates, CTE and subquery scopes, projected columns, correlated/LATERAL visibility, and qualified ambiguous columns. Foreign keys from PostgreSQL/MySQL provide ready-to-insert JOIN/ON suggestions, including reverse, composite, and self joins. Contextual results replace the temporary keyword list, and completion also opens after clause whitespace.
- Result tables have a fixed row-number gutter: click to select a whole row, drag or Shift-click for a range, and Command-click for individual rows. Row numbers are excluded from copied data and stay below the column header while scrolling.
- Query results show displayed and total row counts on the right, such as `13 from 13 rows shown`, without a separate SELECT command heading.
- Fixed clipped hover feedback on the application theme and editor color scheme pickers in Settings.
- Table browsing: double-click a cell to open row details and edit its value, or choose Row Details from the cell context menu; Space also toggles the inspector. The separate inspector toolbar button is removed. Sorting is available through column headers, and filters sit beside the connection picker above the table. Selection, export, and applying changes share the bar directly below the table; pagination, Columns, and row actions sit beneath it. Preview SQL appears only when a preview is available.
- Fixed freezes during mouse and keyboard multiple selection: selection changes no longer reload data, and noncontiguous selected rows are preserved. Editors respect column types and distinguish empty strings, NULL, and DEFAULT.
- All data tables and the SQL completion table use a style without outer horizontal padding or rounded rows.
- Removed the persistent cell-editing hints above the data grid and SQL query results.
- A green checkmark beside the first line number confirms successful SQL fragment execution. Scripts mark each completed statement; errors, cancellation, and unknown outcomes receive no mark. Editing text, changing connections, or starting another run clears previous marks.
- Settings → Appearance: independent application and SQL editor color schemes, live previews, and changes without restarting. The application supports System/Light/Dark and the shared scheme library: DBeer Light/Dark, VS Code Light+/Dark+, Solarized Light/Dark, JetBrains Light, Darcula, and imported themes. The application palette applies to panels, tabs, controls, and tables; the editor inherits it in Follow App Appearance mode or uses a separate scheme. Import standard VS Code JSON/JSONC, TextMate `.tmTheme`, and JetBrains `.icls` files, persist imports and selections locally, and remove custom schemes. Switching schemes preserves text, cursor position, scrolling, and Undo; the background, syntax, selection, cursor, line numbers, and completion popup use the selected palette.
- Refreshed SQL editor layout: the background fills the panel to its edges without an outer padding border, while retaining internal text padding, line spacing, the current line and its number, adaptive light/dark colors, Undo, selection, and execution highlighting.
- Bundled local SQL language server over LSP: contextual PostgreSQL/MySQL completion while typing and with ⌃Space, loaded catalog tables and columns, functions and aliases, keyboard navigation, and undoable insertion with identifier quoting. Diagnostics for unclosed strings, comments, and parentheses are tied to the document version. Switching profiles or dialects discards stale responses; completion never opens database connections or executes SQL, and an unavailable LSP does not block the editor.
- After connecting, user tables, views, functions, and columns load in the background for completion without manually expanding tree branches. Profile Refresh updates completion metadata; batches use a separate service session without executing SQL in tabs or connecting restored drafts.
- Catalog feedback follows native rows during tree expansion and collapse without a duplicate border during animation. The green connection indicator stays in place when the loading indicator appears or disappears.
- Aligned the Connections header and search dividers with the SQL tab bar and execution toolbar.
- Shared execution registry for the Query menu, buttons, and keyboard, respecting the active tab, focus, and modal windows. The default ⌘Return and ⇧⌘Return shortcuts are preserved; the SQL fragment to execute is highlighted inside the editor instead of a separate block. Highlighting and execution follow the cursor, including immediately after `;`.
- Configurable Run, Run Script, Stop, and Run to File shortcuts: recording, persistence, conflict detection, protected system editing shortcuts, clearing, and restoring defaults.
- Individual shortcut clear/reset actions use icons without button borders.
- Profile environments: unset, dev, stag, and prod, with text and color context in profiles and confirmations.
- Hidden the unset environment label in the connection list and removed environment labels from SQL tabs and the connection picker. The Readonly indicator now appears only beside the connection picker as RO, with a full tooltip and VoiceOver description.
- Environment labels and the RO indicator use the same small, muted gray text to keep status information unobtrusive.
- Shared helper policy for Execute, scripts, Run to File, and Apply. Destructive and unknown SQL requires confirmation; production confirms every write. Multi-statement runs show the entire batch before execution; Cancel sends no user SQL.
- A separate readonly setting rejects writes and unknown operations in the helper, disables grid editing, and enables server-side read-only mode. Changing profile policy uses the existing session and transaction shutdown workflow.
- Added small horizontal padding inside the Readonly toggle in the connection editor.
- Protocol v3 binds approval to the exact operation, statement order, and session; cancellation, errors, reconnection, and content changes invalidate it.
- Profile formats v1/v2 migrate to v3 while preserving UUIDs and backing up the original bytes. Profile transfer v2 retains environment and readonly settings, and legacy v1 imports remain supported; secrets are still excluded.

## 0.1.0

First internal DBeer release for macOS 14+ on Apple Silicon.

- PostgreSQL 16/17/18 and MySQL 8.0/8.4, multiple profiles, and independent SQL tab sessions.
- Lazy object tree, search, structure, definitions, and table browsing with filters, sorting, and pagination.
- SQL editor with syntax highlighting, undo, completion, selection/statement execution, and sequential scripts, including stored routines.
- Drafts, `.sql` files, and managed history; restoration never connects or executes SQL.
- Chunked results with backpressure, range copying, CSV/JSON export, and a separate complete Run to File export.
- Local INSERT/UPDATE/DELETE changes, SQL preview, parameterized Apply in a separate transaction, conflict detection, and complete batch rollback.
- Secret-free profile import/export, local CA selection, and cancellable closing with transaction and pending-change handling.
- Light and dark themes, a consistent amber accent, database icons, uniform hover feedback, and native control focus handling.
- Versioned ZIP archives, SHA256 checksums, the owner's persistent signing identity, and a separate temporary CI signature.
- Swift 6.1 / Xcode 16.4 compatibility and application builds using Command Line Tools.

See [INSTALL.md](INSTALL.md) for installation instructions and the limits of the verified distribution.
