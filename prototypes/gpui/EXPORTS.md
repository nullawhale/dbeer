# GPUI loaded-result exports

Task 20 is code-ready on 2026-10-19. Tests are prepared for final integration;
none were executed during implementation. Targets are Windows 11 x64 and Ubuntu
24.04 x64, with separate Wayland/X11 acceptance. Mac GPUI is development only;
the macOS product remains SwiftUI/AppKit. Task 2 and all 171 native cells remain
open. Builds do not depend on ignored planning documents.

## Loaded scope and encoding

Query menu and result toolbar JSON/CSV actions use the same command capture and
dispatch. Before opening any dialog they retain the original document, kind,
result ordinal, execution, physical result arrays, grid entity/snapshot/draft
revision, source/session revisions, title and profile/settings/generation.
Subsequent callbacks never read the active tab to choose an export origin.
Changing tabs, local sort/filter or selection does not restrict the captured
physical rows: all already loaded rows retain their original backend order.
The reference is `ResultExport.swift`, `ApplicationWorkspace.exportLoaded` and
the export controls in `DataGridView`/`ApplicationWorkspaceView`.

A review always displays the loaded count, reported result count and explicit
truncation disclosure before the native Save picker. It explains that unloaded
rows are excluded and that export runs no SQL. CSV also requires an explicit
nonempty marker that differs from every non-NULL loaded value, including empty
text, literal NULL and Base64 values. Invalid markers remain editable in review;
Cancel/Return/Escape cancels review. Binary values remain raw Base64 strings.

JSON is the shared version-1 metadata plus value-array representation: ordinal
columns preserve duplicate names, engine/native type, optional nonzero OID and
encoding. Exact numbers remain strings; NULL, empty text, text NULL, Unicode,
CRLF and binary values remain distinct. Reported rowCount, displayedRowCount and
truncated are never replaced with a full-export claim. JSON uses sorted pretty
UTF-8 without escaping slashes. CSV has ordinal duplicate headers, doubled
quotes for commas/quotes/CR/LF, UTF-8 and CRLF record endings. The empty zero-column
set emits one CRLF. `displayNotice` is local display state, outside export JSON.

Suggested names match the reference `title-loaded-N-rows.json/csv`; title path
separators are neutralized. GPUI's real Save picker owns overwrite confirmation.
The pinned picker API has no content-type/extension filter or message accessory,
so scope/marker review is a preceding accessible dialog. The confirmed native
path is preserved exactly, including an explicitly chosen custom extension;
no suffix is silently appended after overwrite confirmation. Native Windows,
Wayland and X11 picker/overwrite/accessibility behavior still needs acceptance.
The old speculative TSV export menu item is removed; Copy Rows remains its
separate loaded-view TSV action. Run to File is implemented separately in RUN_TO_FILE.md.

## Confirmation gates and lifecycle

Export accepts an idle, clean disconnected snapshot without reconnecting. It
never calls helper startup, credentials, connect, operation assessment, execute,
catalog or cancellation APIs. SQL results must retain the original loaded result
and valid grid context. Table results consume Task 19's
`Workspace::confirmed_loaded_table_snapshot`: `result_sets[0]` physical rows,
never the projected `ResultGrid.result` or local visible rows.

Table inline/staged drafts, pending browse/refresh, Preview/Apply/review/cleanup,
unknown outcomes and known-commit ReloadRequired block export. The same profile
and object in any sibling document also blocks export while it has drafts,
browse work, Apply or unresolved recovery. Disconnect never clears Unknown.
Inspection/discard/reload requirements remain exactly as documented in APPLY.md.

One monotonic `Workspace.export_request` owns Review -> Choosing -> Encoding ->
Writing phases and the immutable capture, chosen target and encoded bytes.
Repeated review callbacks cannot start a second picker or cancel a later owner.
Every picker, encoding, temporary-write and final-publication continuation checks
its token and original capture. Removed documents, changed source/session,
profile/settings/generation, result selection/replacement, stale grids/snapshots,
new drafts/browse/recovery/Apply or an unrelated close owner refuse publication. The owner's own
export request is deliberately excluded from snapshot invalidation.

Common commands and direct table/file/preview entry guards exclude overlapping
export work. Task 22 now captures and awaits this export owner through the common
close graph, preserving active native picker futures and original publication
checks. Explicit Stop marks cancellation and drains before unpublished cleanup;
a published destination is preserved. A native picker Cancel or
stale callback drops the unpublished work. No callback mutates SQL file binding,
file revision, saved source, title, history, restoration DTOs or source clean state.
Success/cancel/error status is attached to the original surviving document.

## Atomic destination and failure behavior

`files::CapturedDestination::capture` records the confirmed path and explicit
absence or original identity/stamp/exact bytes before asynchronous encoding.
Existing export destinations need not be UTF-8. `PreparedSave::prepare_captured`
refuses changed/appeared destinations before preparing a temporary. Encoding
failure writes nothing. `exports::PreparedExport` wraps the same owned mechanism
as SQL Save; it cannot update a SQL binding.

PreparedSave creates a private exclusive same-directory temporary, retains the
original directory/file handles, locks and original bytes, syncs and checks its
bytes and target before returning. Publication matches the captured encoded
bytes and confirmed path, then revalidates original UI ownership and immediately
performs atomic replacement in one synchronous UI boundary. New targets use
no-replace rename. Windows CREATE_NEW installs a protected current-user-only
DACL before encoded bytes are written, including absent destinations. Destination
permissions and Windows DACL/protection transfer only at authorized publication;
 symlink/reparse/retargeted-parent, external edit, denied sharing,
read-only Windows and cooperative lock behavior is inherited from FILES.md.

Dropping stale/failed/unsubmitted work removes only its owned unpublished
temporary. Cleanup now checks the retained handle's file identity before removing
a named temporary; an unrelated replacement at that name is preserved. The
previous destination survives Cancel, encoding, temporary-write/sync, stale target
and known replace failure. Windows ambiguous publication stays explicitly
unverified and is never described as an unchanged destination or retried.
A directory-sync failure after observed publication is not reported as failure.
Advisory locks and stamps are not an adversarial filesystem compare-and-swap;
power-loss, Windows ACL/locked-file and native filesystem behavior need final
fault acceptance. No destination delete/retry fallback exists.

## Task 21 and Task 22 handoff

- `exports::Format::{Json,Csv}`, `extension`, `suggested_name`, `validate_marker`,
  `json/csv/encode` are the format/loaded-byte APIs. They own no connection.
- `files::CapturedDestination::capture(&Path)` and `PreparedSave::prepare_captured` preserve an existing
  target or explicit absence across encoding. `PreparedExport` retains prepared
  bytes/path matching and one-shot publish. Do not use a SQL file binding for
  result exports or call `DocumentFile::record_saved`.
- `CommandCapture.loaded_export: Option<Arc<ExportCapture>>` and
  `Workspace::capture_loaded_export`, `loaded_export_capture_valid`,
  `start_loaded_export` own only loaded-result scope. Task 21 must capture its
  SQL fragment/destination before credentials or execution and use the helper's
  existing full export protocol, original session/authorization/Stop/outcome,
  never the bounded loaded rows or rerun after export failure.
- Task 22 composes export/file ownership with CloseToken/Finishing and retained
  staged/unknown/cleanup decisions. Preserve phase/token identity and publication
  acknowledgements; never drop a submitted full-export operation to close.

## Prepared verification and remaining acceptance

`protocol/fixtures/export.json` remains frozen and is consumed unchanged by Rust
alongside the existing Swift/Go consumers. New `loaded-export-v1.json` is consumed
by Rust, Swift and Go cases: metadata duplicates/OIDs/Base64, exact numeric strings,
NULL/empty/literal/marker, Unicode/CRLF, truncation and empty sets. Rust/Swift compare
loaded CSV bytes exactly. Go's full exporter intentionally retains truncated=false
and LF record endings; its new consumer checks identical metadata/values and
parsed CSV semantics, preserving the established protocol and full-export scope.
No frozen fixture, manifest, source/reference hash or replay was rewritten.

Prepared Rust cases include malformed ordinals/counts/widths, CSV collisions and
quoted markers, large values/all 1,000 loaded rows, cancelled preparation, changed
or appeared targets, locked/Windows deny-sharing destinations, unowned temporary
replacement, chooser Cancel/stale origins, phase/token replacement, original-tab
publication after focus/local-filter changes, unchanged SQL file state and zero
helper request counters for table export gates. Existing FILES.md cases cover
injected sync/temp corruption/permissions/Windows DACL and rename reconciliation.
These are code, not passed tests or native evidence.

At final integration run with completed summaries and explicit skips:

```sh
./scripts/gpui-prototype.sh test --locked -- exports:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- files::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- export_view::tests --test-threads=1
./scripts/test.sh --filter ResultExportTests --filter LoadedExportFixturesTests
./scripts/test-go.sh
```

Use matching native Windows/Linux build runners and owned destinations for actual
picker cancellation/overwrite, stale operations, light/dark focus, permissions,
locked file and publication fault checks on Windows 11, Ubuntu Wayland and X11.
No Rust/Go/Swift/database/UI/credential/clipboard tests or probes ran during this
implementation. Static check results and ignored logs live in IMPLEMENTATION.md.

Task 21 now carries its separate run_file owner through captured native destination, one exact SQL operation and helper full streaming. Loaded export remains independent and runs no SQL. Task 22 captures and awaits both active owners before teardown. See RUN_TO_FILE.md.
