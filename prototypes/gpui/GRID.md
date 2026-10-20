# GPUI grid selection, clipboard and row details

Task 16 is code-ready; tests are prepared but not executed. Windows 11 x64 and
Ubuntu 24.04 x64 (Wayland and X11) require native compilation and acceptance.
Mac GPUI is development only; the macOS SwiftUI/AppKit product is unchanged.
Task 2 and all 171 frozen native cells remain open. Builds read no ignored docs.

## Retained results and original rows

`QueryTab.grid_views` owns one `TableState<ResultGrid>` entity per SQL operation
and result ordinal, or the table document's committed browse context. Render
borrows entities. Switching statements/results restores each entity's widths,
horizontal/vertical viewport, local sort, selection and details presentation.
The document's loaded-row filter remains document-local. New SQL operations
retire previous context actions before submission, then discard old entities
after inheriting compatible ordinal widths/viewport into the new result.
Selection never carries into another operation/result, even with identical data.

`ResultGrid.original` retains the actual protocol columns and row arrays;
`metadata` retains table capabilities by ordinal. `visible_rows[visible_index]`
is a **source ordinal**, and `row_ids[source_ordinal]` is the **original row ID**.
These are distinct values. Local sort/filter changes only `visible_rows`; it
never moves selection onto whatever row happens to occupy an old visible index.
Row numbers are one-based positions in the loaded view; they are not database
keys or total-row estimates. Copies use selected source ordinals in visible
order. Hidden selected rows are retained but excluded from a visible selection
copy/details until shown again; an entirely hidden/empty selection copies nothing.

Same-context table Refresh retains widths, local sorting and viewport only with
exact ordinal result-column and typed metadata equality. It reconciles original
row IDs by unique primary-key tuples; without a key, only unique exact full rows
can retain IDs. Duplicate/changed/missing identities lose selection safely.
Selection anchors/focus retain their IDs, never clamp to a different row index.
Changing committed page, server sort or server filter is a new row scope and
clears selection even if columns match. Schema/capability changes also reset
incompatible sorting, widths and viewport. Every accepted replacement advances
the table snapshot, invalidating captured copy/context actions. Failures keep
the previous complete snapshot and all its view state. This supersedes Task 15's
earlier blanket instruction to reset selection on every replacement.

## Input and copy

GPUI Kit's table supplies virtualized rows/columns, resize handles and scroll
geometry. Its single-cell/row selection is disabled for workspace results;
`grid_selection::Selection` supplies the actual rectangle or sparse full rows.
Click selects a cell; Shift-click/drag extends a rectangle. Row-number clicks
and Alt-click select complete rows; primary-click toggles sparse complete rows
(Ctrl on Windows/Linux, Cmd on the Mac development host). Row-number drag keeps
full-row mode. Dragging to a visible edge advances the loaded viewport.

Arrows move a cell; Shift extends. Home/End move within the row; primary Home/End
and primary arrows reach loaded edges. Page Up/Down uses the visible row count.
Shift+Space selects whole rows, primary+A selects the loaded view, Escape clears,
Space/Enter/double-click toggles or opens details. Tab/Shift+Tab traverse focus.
Horizontal keyboard movement uses the table's synchronized column scroll API.
Columns resize by ordinal between 70 and 2,000 pixels; duplicate names cannot
merge widths. No extra double-click column-fit feature is introduced.

`CommandId::GridCopy` is distinct from the existing **Copy Rows** loaded-view
TSV action (which retains headers and its previous formatting). Standard Edit
Copy and primary+C on a focused grid route through GridCopy's common immutable
document/entity/result/snapshot capture. A focused details/text editor retains
normal toolkit text Copy/selection/IME behavior. SQL commands refuse grid/text
field focus and dialogs; grid keys install no global input hook.

The context menu offers Copy Cell, Copy Selected Rows, Copy Range and Row Details.
It captures the original grid, snapshot, exact payload and context cell before
the popup takes focus. A stale replacement/retired operation cannot publish it,
and a late callback never reads another active result. Copy Cell honors the
right-clicked cell even inside a larger selection. Empty selection is a no-op,
with no clipboard clear or whole-grid fallback. Copying is explicit user action;
clipboard paste/import is not added.

## Interoperable native formats

`grid_clipboard::Payload` matches Swift `ResultClipboardPayload` version 1:
`columns`, `sourceRows`, `sourceColumnIndices`, and typed `values` with `kind`
and optional `value`. Column metadata retains original ordinals, names, engine,
native type, OID and encoding. Exact numbers remain strings. SQL NULL, empty
text, literal `NULL`, marker collision `\N`, multiline/quotes and binary Base64
remain distinct. PostgreSQL legacy bytea hex is normalized to Base64 like Swift.
TSV contains only selected values, with unquoted `\N` for SQL NULL; empty strings,
literal `\N`, tabs/newlines/CR/quotes use doubled-quote TSV escaping. Binary TSV
contains raw Base64, without a display-only prefix. Both representations are
prepared before native publication. Nothing is logged or persisted.

| Platform | Native text | Native typed representation |
| --- | --- | --- |
| Mac development | Official GPUI NSString pasteboard path | NSPasteboard `dev.dbeer.result-selection+json`, exact UTF-8 JSON bytes |
| Windows | CF_UNICODETEXT, UTF-16LE plus NUL | Registered `dev.dbeer.result-selection+json`, UTF-8 JSON plus terminal NUL |
| Ubuntu Wayland | Existing native UTF-8 text offers and `text/tab-separated-values` | `dev.dbeer.result-selection+json` and MIME alias `application/vnd.dbeer.result-selection+json`, identical UTF-8 JSON bytes |
| Ubuntu X11 | UTF8_STRING/text target aliases and `text/tab-separated-values` | The same two typed TARGETS, identical UTF-8 JSON bytes |

Windows prepares both HGLOBALs and registers the format before EmptyClipboard,
uses the owned HWND and releases only unpublished handles. A partial SetClipboardData
failure is reported as partial publication, never as success or atomic restoration.
Mac prepares NSData/type before the official text copy; typed attachment failure
explicitly reports TSV-only publication. Native acceptance must use external
consumers; reading GPUI's cached item does not establish interoperability.

GPUI's public ClipboardItem cannot express arbitrary external formats. The
maintained, bundled `vendor/gpui-pre-linux` patch consumes an internal bounded
fixed-format envelope and **publishes actual native targets**, rather than
calling internal metadata a native format. Ordinary text copy remains ordinary
text. Wayland uses the existing owned data source, real input serial and async
FD sender; it advertises each target and answers with that target's bytes. Missing
device/focus/serial is a visible copy failure. X11 interns all atoms/buffers
before ownership and uses the existing selection thread, TARGETS/INCR transfer
and clipboard-manager handover. No xclip/wl-copy, third-party daemon or global
hook is required. The local publication status confirms backend submission,
not external consumer acceptance. Provenance/license/patch scope are in the
vendor README and must enter Task 31's notices.

## Row details and Task 17 handoff

Details follows exactly one visible selected original row ID. Multiple/zero rows
show a count/prompt. It retains plain read-only EditorState entities per field,
supports selectable large/multiline text and full Base64, and shows duplicate
column ordinals, engine/native type/OID, NULL/empty/binary kinds, nullable,
generated/editable metadata and adapter/profile/view/no-PK read-only reasons.
The toolbar, context menu and keyboard share the same state; changing the row
replaces its field entities once, while ordinary render/focus does not.
Closed details create no field editors. Cell layout previews at most 256 Unicode
characters; full original values remain available to Copy and row details.

Task 17 consumes `original`, `metadata`, `snapshot`, `row_ids`, `visible_rows`,
`selected_sources()` and `grid_clipboard::Value::original`. Capture the owning
document/result entity plus snapshot and column/capability fingerprint before
staging; do not reinterpret visible indices or use column names as identity.
Original values must remain separate from draft values/default/deletion state.
The current inspector is read-only; adding editing must keep field precedence,
IME and retained editor entities. Use `TableDocument.locks` (`inline_draft`,
`staged_changes`, `previewing`, `applying`, `outcome_unknown`, `closing`) before
any edit workflow, retaining capture/submission/follow-up/completion checks.
No Preview/Apply, SQL-tab session borrowing, auto-connect or restoration DTO
widening belongs here. CloseToken/Finishing/latest-state flush and file/modal
guards remain intact. Ubuntu GNOME logout remains Task 29's obligation.

## Prepared verification, not executed

Pure cases cover rectangles/sparse/full rows, duplicate ordinals, original-source
mapping under local sort/filter, NULL/empty/literal/marker/exact numeric/binary/
multiline, legacy hex, large strings/1,000 rows, unique-key/exact-row refresh,
duplicates/missing identities/new pages/schema/new results and ordinal widths.
Headless cases exercise actual cell/key callbacks, retained result entities,
synchronized details, field focus and stale common-copy snapshots. Native format
serialization and the exact Linux envelope parser compile on the development
host. Native Windows ABI and Linux backend source branches have **not** compiled
or run here. No clipboard, database, UI, credential or Rust/Swift/Go test ran.

Completed static checks and final commands are recorded in IMPLEMENTATION.md.
At final integration, record completed summaries and explicit skips:

```sh
./scripts/gpui-prototype.sh test --locked -- results:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- native_ --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- results:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- commands::tests --test-threads=1
```

On owned Windows 11 and Ubuntu Wayland/X11, compile the actual cfg branches and
verify external format enumeration/readback, multiline/empty/binary/duplicate
columns, locked/busy clipboard and missing serial, large-grid input/resize/scroll,
drag/Shift/Ctrl/Alt/IME/field focus, context-menu/result/refresh races and row details.
Native accessibility and timing budgets remain Task 2/29/30 acceptance work.

## Task 17 staged-edit extension

Task 17 supersedes the read-only editing handoff above. See [CHANGES.md](CHANGES.md)
for immutable originals versus projected drafts, typed values, markers/counts,
retained inline/expanded editors, Columns, full captures and the immutable
ChangesBatch handoff. Selection copy/details display projected values, with the
existing Swift v1 `default` kind and `<DEFAULT>` TSV. Snapshot plus draft revision
invalidate stale copy/context actions. SQL results remain read-only; staging sends
no helper request. Existing native copy adapters/vendor notices are unchanged.


Task 20 JSON/CSV export uses the original physical ResultSet arrays, not these
local sort/filter/selection or staged projected rows. Export retains the exact
grid entity/snapshot/draft revision and refuses table/sibling pending edits,
browse, Preview/Apply/cleanup and recovery. A clean disconnected snapshot remains
exportable without database work. Count/truncation and CSV marker review precede
the native Save picker. Copy Rows/selection formats are unchanged. See EXPORTS.md.
