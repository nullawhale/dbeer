# Changelog

## Unreleased

- SQL history searches the complete SQL text and combines connection, date and
  outcome filters. Searches run in the background and cancel obsolete requests.
  Opening an entry creates a disconnected SQL tab; entries whose original
  connection was deleted require choosing a connection before execution.
- Native SQL history records start and finish times, duration, typed execution
  outcomes, separate loaded/affected/exported row counts, truncation and partial
  counts, SQLSTATE and safe error descriptions. Each executed script statement
  gets one terminal entry; skipped and locally rejected commands are excluded.
- History preserves the profile context captured when execution starts, excluding
  credentials, SSH settings, certificate paths and result values. History storage
  advances to v2 with exact v0/v1 backups before migration; missing legacy
  execution details remain unavailable rather than being inferred.
- Native macOS connection profiles can use an SSH bastion through supervised
  system OpenSSH, with agent, private-key or password authentication. SSH
  passwords and key passphrases use separate Keychain entries; profile exports
  exclude credentials, private keys and trust decisions.
- SSH host keys require explicit fingerprint review before first use. Database
  TLS continues verifying the original database identity. PostgreSQL/MySQL
  cancellation and Cassandra node connections use the same SSH transport;
  Cassandra SSH contact points currently require numeric IP addresses.
- Native profile storage advances to v4, portable profiles to v3 and the native
  app/helper protocol to v5. Existing profiles migrate with SSH disabled.
  Windows/Linux GPUI compatibility remains deferred.

## 0.2.0 prerelease — build 8 — 2026-10-20

This prerelease targets the native macOS client and bundled Go helper.
The full local Go race and native Swift runners completed successfully for this
build; native database integration cases without configured fixtures were skipped.
Earlier intermittent editor completion and signature-help failures remain tracked.
Installed-archive acceptance for 0.2.0 remains pending.

- Connected Cassandra profiles expose a Cluster Nodes snapshot with node addresses, driver status, datacenters, racks and host IDs. Refresh reads the driver's current observations; statuses describe this connection's view rather than cluster-wide health.
- Plain Cassandra fault-injection tests now intercept connections to discovered peers as well as contact points, preserving real node addresses and requiring exactly one lost write acknowledgement without retrying the write.

## 0.2.0 prerelease — build 7 — 2026-10-20

This local prerelease targets the native macOS client and bundled Go helper.
Windows/Linux GPUI candidates and their pending acceptance are outside this release.
The full native UI suite is not green: editor completion and signature-help checks
have intermittent failures. Installed-archive acceptance for this version is pending.

- DBeer is now licensed under GNU GPL version 3 only (GPL-3.0-only). The license text is included in macOS application bundles and release ZIP archives.

- Cassandra table grids show pinned, color-coded partition labels with key tooltips. Clicking a label selects every loaded row in that partition, including nonadjacent and offscreen rows. The status beside Apply counts partitions in pending edits, and atomic Apply is disabled when edits span partitions or a partition key is unavailable. Labels are local to the loaded page and stay out of copied/exported data.

- Connection environments now appear beside the profile name in the macOS sidebar, retaining their muted gray styling.

- Added native macOS Apache Cassandra support: contact points, keyspace/datacenter and consistency settings, verified TLS, CQL scripts and batches, schema catalog, cursor browsing, and streamed CSV/JSON exports. Each tab retains an independent keyspace and driver session. Cassandra reports unsupported transactions, local read-only enforcement and unknown write outcomes honestly. Windows/Linux work is deferred.
- Cassandra grid cells in scalar tables can be edited through Preview/Apply, with multiple rows saved atomically in one conditional batch within a single partition. A conflict rejects every row and retains all pending edits. Cross-partition requests are rejected before writing. Uncertain batch outcomes block further edits and are not retried. Keys and static fields remain read only, and the UI explains TTL behavior. Inserts, deletes, all-NULL regular rows and tables with complex/counter/duration types require explicit CQL.
- Cassandra preserves acknowledged write completion when result delivery or export fails, bounds wide empty-result metadata, and labels generated schema definitions as partial. Conservative UDF assessment and native function completion preserve CQL selector syntax.

- Fixed PostgreSQL numeric table filters rejecting fractional operands for integer columns. Native macOS filter and shortcut settings views also build with Swift 6.1.

- macOS app packaging materializes database logo resources before signing, including SwiftPM 6.1 bundles that preserve source symlinks.

- Improved segmented-control keyboard focus and kept inline grid editors fully visible after opening row details on older macOS versions.

- Catalog menus avoid the native blue row outline on older AppKit versions. Return and Escape cancel SQL review even when the preview has focus, and timed-out completion requests return before helper process cleanup.

- GPUI keyboard commands preserve native editing and composition, including Return/Shift+Return, shortcut recorder Tab navigation and exact Run shortcut modifiers.

- Offline completion keeps its current request during harmless refreshes; source changes, replacement and close cancel only the original owned request.

- Fixed GPUI popup rendering and retained grid mouse/focus updates. Disabled buttons now expose their disabled accessibility state.

- Legacy profile migration now retains its validated primary file and parent across backup work, refuses intervening external edits or replacements, and keeps the exact old private backup for recovery. Full runtime and native acceptance remain pending.

- Theme import, removal and explicit recovery now share captured private publication with atomic no-replace handling for absent files. Exact corrupt-library copies and foreign destinations/staging are preserved; unknown Windows publication requires inspection and Reload before close. Full runtime and native acceptance remain pending.

- Workspace/profile migration and shortcut recovery backups now become private before writing on Windows and Unix, preserve exact original bytes and foreign files after failures, and abort primary replacement when required backup publication is unconfirmed. Full runtime and native acceptance remain pending.

- SQL Save and Save As now capture the native chooser destination and parent ownership before background work, refusing newly appeared or externally changed files while retaining original-binding conflict checks. Full runtime and Windows/Linux native acceptance remain pending.

- New SQL Tab can create independent disconnected local drafts before a profile is saved. Shortcut saves and explicit recovery now verify staged ownership and exact content through the shared publisher before acknowledging a saved mapping or normal close, preserving exact recovery backups and foreign replacements. Full runtime and Windows/Linux native acceptance remain pending.

- Hardened experimental GPUI candidate publication against changed source and legal inputs. Completed parity proofs must match the exact candidate-reviewed source inventory; unavailable Mac database coverage stays explicit and still requires separate real database/TLS proof. Required export-test cleanup preserves foreign files and fails its proof on refusal. Package, installed and Windows/Linux native acceptance remain pending.

- Corrected GPUI local-file and persistence recovery: fresh unbound and missing-profile SQL can Open/Save/Save As without a saved connection, Open works from inspection tabs, and accepted large sources/history persist without the former 8 MiB/64 MiB cutoffs. Windows private staging now installs its protected descriptor at CREATE_NEW before content. Profile exports and connection/workspace/appearance stores share captured destination and retained temporary identity/content checks, preserving external replacements. Completion and signature help resume after connection/import Cancel or success while failed-save recovery and stale-owner guards remain active. Windows UNC parent normalization is corrected. Full runtime and Windows/Linux native acceptance remain pending.

- Prepared the isolated GPUI parity/fault runner and exact installed-artifact acceptance contracts, including physical helper/session loss and controlled real database acknowledgement-loss evidence. The complete matrix and Windows/Wayland/X11 installed acceptance remain pending.

- Windows/Linux DBeer now has stable app identity, empty disconnected startup without demo profiles or sample SQL, and exact paired GUI/helper build metadata including the offline language helper. Native wrappers prepare unsigned portable Windows ZIP / Ubuntu tar candidates with original icons, one Windows host manifest, full source/dependency/runtime notices, installation/update instructions and SHA256 without replacing previous archives. Original GPUI data, UUIDs, credential service and kernel ownership lock remain unchanged; macOS still uses the independent SwiftUI/AppKit build/sign/release route. Runtime, native packaging and installed Windows 11 / Ubuntu Wayland/X11 acceptance remain pending.

- GPUI now connects native accessibility to retained SQL/review editors, typed virtual result grids, row inspectors, named dialogs and Settings. Guarded actions preserve original focus, editing and Preview/Apply ownership; keyboard context menus, F2 and staged Delete share existing controls. Linux startup owns a GNOME session-manager registration whose noninteractive replies depend only on completed common close review. Runtime, screen-reader, native input/scaling and Windows/Linux session-end acceptance remain pending.

- GPUI Settings now records, rebinds, clears and restores Run, Run Script, Stop and Run to JSON/CSV File shortcuts. Private mappings preserve explicit unbinding and conflict/protected-key rules, with deliberate corrupt recovery and reload. Exact native input safety and common command gates keep keyboard, menu and toolbar behavior synchronized; normal close drains the latest accepted save. Runtime and Windows/Linux native acceptance remain pending.

- GPUI Appearance now imports VS Code JSON/JSONC, TextMate XML/binary and JetBrains schemes through native selection and explicit normalized review. Eight bundled schemes and original notices ship independently of Mac builds; safe local includes, private normalized persistence, removal and deliberate corrupt-library recovery preserve existing bytes and selections. Late callbacks cannot overwrite newer choices, and normal close drains original theme work plus required appearance saves. Runtime and Windows/Linux native acceptance remain pending.

- GPUI appearance settings now offer persisted System/Lager/Porter and named application schemes, independent editor schemes and Follow App Appearance, with retained live previews. OS changes reapply the selected palette without changing SQL/editor/grid/session state; normal close awaits the latest reserved appearance save. Fixed errors, retry and explicit reload preserve unreadable originals. Runtime and Windows/Linux native acceptance remain pending.

- GPUI SQL editors now show Go function signatures with names, parameter and return types, the active argument and overload navigation. Source/caret changes and manual completion refresh the non-focusing popup; Escape suppresses pending help, and completion acceptance retains native Undo. Built-ins work offline and connected functions use explicit metadata refreshes. Runtime verification and Windows/Linux native acceptance remain pending.

- GPUI SQL editors now show contextual Go completion with fuzzy match highlights, automatic typing and protected Ctrl+Space invocation, native popup navigation, Tab/Return insertion and Escape dismissal. Source/context/caret/focus/IME checks reject stale work; insertion uses one Atomic Undo step and retains the original editor. Version-correct syntax diagnostics have a separate source decoration path from execution feedback. Runtime verification and Windows/Linux native acceptance remain pending.

- GPUI SQL editors now synchronize with a separate offline language helper through a bounded background worker. Explicit Connect and Refresh load completion metadata on the original catalog service; typing and restoring remain disconnected. Assistance supports safe Retry, version/context invalidation and awaited close teardown without changing editor Undo or SQL-session ownership. Runtime verification and Windows/Linux native acceptance remain pending.

- GPUI close decisions now compose scripts, full/loaded exports, native SQL file work, inline edits and fresh-session Apply with captured Stop/transaction/Discard/Cancel decisions. Physical SQL sessions retain their original helper across later commands and teardown; explicit unknown-outcome close acknowledgment keeps reapply recovery blocked. Final removal awaits original operation outcomes, live-session disconnect acknowledgments, owned window-helper teardown and the latest local draft flush. Runtime and Windows/Linux native acceptance are pending.

- GPUI Run to JSON/CSV File now captures one exact statement and destination before credentials, assesses and executes once on the original SQL-tab session, and streams full results with progress and Stop. Private publication checks destination identity and output bytes, uses explicit Windows replacement, and separates successful SQL from failed or unverified file publication without rerunning SQL. Shared Swift/Go/Rust contract consumers are updated; runtime and Windows/Linux native acceptance are pending.

- GPUI loaded JSON/CSV export now captures the original physical result rows, discloses loaded/reported counts and truncation, and uses native Save dialogs without reconnecting or running SQL. Exact values and duplicate columns are retained, CSV requires a collision-free NULL marker, and pending table edits, Apply, browse and recovery block export. Captured atomic publication preserves SQL file state and refuses stale destinations. Runtime and Windows/Linux native acceptance are pending.

- GPUI Apply now re-previews and assesses the exact frozen typed batch on a fresh idle session, requires explicit review and retains authoritative completion through Stop and original-session cleanup. A known commit reloads through the captured table service; failed reload blocks reapply. Lost COMMIT confirmation preserves local changes and requires successful inspection followed by explicit Discard and Reload; disconnect does not prove rollback. Runtime and Windows/Linux native acceptance are pending.

- GPUI standalone Preview SQL now shows exact helper-generated SQL and separate typed parameters for a frozen changes batch, with original profile/policy context and helper assessment. Each attempt owns a fresh idle session, supports Stop/Cancel, revokes unused grants and awaits original-session cleanup; stale context keeps local drafts. Fresh-session Apply and recovery are described above. Runtime and Windows/Linux native acceptance are pending.

- GPUI table grids now stage typed updates, inserts and deletes locally, with immutable original values, pending markers/counts, inline and expanded editors, Columns metadata and explicit NULL/DEFAULT/empty/binary values. Adapter capabilities and visible reasons preserve read-only tables/columns; drafts lock snapshot replacement. Discard/Cancel guards protect tab/window/profile changes and retain drafts on later cancellation or failed profile publication. Standalone Preview and fresh-session Apply are described above. Runtime and Windows/Linux native acceptance are pending.

- GPUI result grids now retain each result's widths, viewport and selection, with rectangular/sparse/full-row input, native typed JSON plus TSV selection copy and synchronized read-only row details. Refresh reconciles original row identities safely; new pages, schemas and operations cannot move selection onto different rows. Windows/Linux native compilation and external clipboard/input acceptance remain pending; full runtime verification remains pending.

- GPUI table/view documents now retain independent 200-row server navigation, typed explicit filters and server sorting, separate from local loaded-view controls. Refresh publishes validated metadata and rows together; failure preserves the previous complete page. No automatic count is requested, and no-PK paging warns about unstable ordering. Shared helper MySQL numeric filters preserve exact decimal/integer comparisons without rounding, and missing browse objects remain known failures. Runtime and Windows/Linux native acceptance remain pending.

- GPUI catalog now lazily loads tables, views, functions, procedures, triggers and relation detail groups, with connected-profile server search, captured object actions and explicit retry/Refresh. Adapter-generated names and overload identities remain authoritative. Structure/definition inspection and the first real read-only table browse snapshot use isolated service sessions; generated SELECT opens disconnected. Runtime and Windows/Linux native acceptance remain pending.

- GPUI SQL drafts and history now retain document UUIDs, source, titles, opaque connection bindings, order and selection with debounced private storage and a fallible final close flush. Versioned migration preserves exact backups and refuses corrupt/future files. Managed history supports recording preferences, statement outcomes, retention, clear and disconnected reopen; clearing drafts uses close guards and keeps saved SQL files. Missing connections preserve SQL for explicit recovery. Runtime and Windows/Linux native acceptance remain pending.

- GPUI SQL files: native UTF-8 Open, Save and Save As now retain the original tab, source and destination across picker callbacks. Files open disconnected; Unicode/CRLF text and file titles are preserved, atomic saves refuse stale targets, and saving older captured text leaves newer edits unsaved. Cancel/errors retain the original binding. Windows/Linux runtime, permissions and native chooser acceptance remain pending.

- GPUI basic close now retains one captured review through Stop, Commit/Roll Back and acknowledged disconnects. Cancel preserves running work; repeated close/Quit cannot replace a chosen resolution, and helper loss or unacknowledged teardown cannot silently remove a document. An owned-window Windows session-end bridge queues cancellable review; native Windows validation remains pending; the Ubuntu session-manager adapter is integrated as described above. Runtime and native acceptance are deferred.

- GPUI Run Script now reviews the entire captured source and helper classification before ordered execution on its original tab session, including helper-allowed read scripts. Each statement retains its outcome and multiple result sets; first failure or Stop skips later work, unknown outcomes block retry, and one cumulative display budget bounds retained results. Original-source error navigation, active highlighting, elapsed/row/truncation feedback and success gutter marks preserve Unicode ranges and clear on edits/profile changes/new runs. Runtime and Windows/Linux native acceptance remain pending.

- GPUI SQL Run now captures the selection or current statement from unchanged source and rejects malformed/client-command/multiple-statement fragments before helper startup. The execution splitter follows the Swift dialect scanner and preserves original Unicode/newline/delimiter spans with explicit byte, UTF-16, LSP and adapter error mappings. Reviewed scripts now use whole-source policy review and ordered execution as described below; runtime/native acceptance remains pending.

- Portable profile transfer: GPUI now previews and imports Swift-compatible v2/legacy-v1 connection files with individual/all selection, explicit CA remapping, fresh identities and one atomic disconnected import without credential changes. Export captures settings before the native chooser and replaces files atomically. Swift accepts Windows drive/UNC CA hints while requiring local remapping and preserving TLS/policy. Runtime and Windows/Linux native acceptance remain pending.

- GPUI connection lifecycle: guarded profile edits/deletion, context actions, native CA selection, Save versus Save & Connect, and a bounded one-shot --connect-stdin channel. Session decisions precede profile/password changes; restored profiles remain disconnected and startup never executes SQL. Windows/Linux runtime and TLS acceptance remain pending.

- GPUI profile persistence: versioned metadata restores selection by stable ID and migrates the former GPUI library with an exact-byte backup. Serialized profile/password updates and deletion restore credentials after a failed metadata replacement and report rollback failures. New profiles use an unspecified environment with readonly disabled; existing policy values and legacy defaults are preserved. Windows/Linux runtime acceptance remains pending.

- Windows/Linux GPUI development builds: native CI archives with the Go helper, platform credential stores and settings paths, Ctrl shortcuts, and executable-relative helper discovery. The macOS product and CI remain SwiftUI/AppKit; the separate GPUI Mac app remains available for development.
- Experimental GPUI client: real PostgreSQL/MySQL connections through the existing bundled Go helper, separate profiles and Keychain passwords, independent SQL sessions, catalog browsing, streamed results, cancellation, transaction state, and helper policy confirmations. The Swift application and protocol remain unchanged.
- GPUI workspace foundation: stable document/profile identity and captured session contexts keep delayed results, cancellation and helper-death outcomes with their original tab. SQL editors retain selection, scroll and Undo across tab/theme changes and accept exact plain-text input. Repeated normal launches sharing a profile directory now refuse safely while the existing process owns its OS lock; ownership is released on exit/crash. Windows/Ubuntu native acceptance remains pending.

- GPUI prototype: Dock Quit now offers Commit, Roll Back, and Cancel for open transactions, waits for helper cleanup before exiting, and keeps repeated Quit requests in the same dialog.

- Renamed the native application appearance choices Light and Dark to Lager and Porter.
- Fixed missing menu text and white Settings icons in light themes by preserving native menu materials and template toolbar icons when switching themes.
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
- Settings → Appearance: independent application and SQL editor color schemes, live previews, and changes without restarting. The application supports System/Lager/Porter and the shared scheme library: DBeer Light/Dark, VS Code Light+/Dark+, Solarized Light/Dark, JetBrains Light, Darcula, and imported themes. The application palette applies to panels, tabs, controls, and tables; the editor inherits it in Follow App Appearance mode or uses a separate scheme. Import standard VS Code JSON/JSONC, TextMate `.tmTheme`, and JetBrains `.icls` files, persist imports and selections locally, and remove custom schemes. Switching schemes preserves text, cursor position, scrolling, and Undo; the background, syntax, selection, cursor, line numbers, and completion popup use the selected palette.
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
