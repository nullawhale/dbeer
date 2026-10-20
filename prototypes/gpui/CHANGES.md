# GPUI typed staged grid changes

Task 17 is code-ready; all runtime tests are deferred to final integration.
GPUI targets Windows 11 x64 and Ubuntu 24.04 x64, with separate Wayland/X11
acceptance. Mac GPUI is development only; the SwiftUI/AppKit product is unchanged.
Task 2, every frozen native cell and Task 29's GNOME logout adapter remain open.
This contract is tracked and self-contained; builds do not read ignored docs.

## Immutable originals and local projection

`ResultGrid.original` remains the exact protocol snapshot. `grid_changes::Draft`
keeps original typed values separately from projected values and ordinal assignments.
`Row.original` is immutable and absent only for an inserted row. Stable row IDs
are independent of visible positions/source ordinals and database primary keys.
All original columns, including every composite key and exact comparison value,
enter update/delete requests. Reverting a value to its original removes that
assignment. Deleting an updated row emits only Delete with its original values;
deleting an inserted row removes it locally. Inserts begin with typed DEFAULT in
all fields, including generated/identity fields, and only explicit assignments
enter the request. Discard removes inserts and restores existing originals.

Text, binary, SQL NULL and DEFAULT use the existing `backend::CellValue` DTO.
Text `NULL`/`DEFAULT`, empty strings, exact numerics and temporal values remain
strings; staging does not parse numbers or synthesize SQL. Binary input validates
the existing protocol's Base64 rules without decoding/re-encoding or losing bytes.
Go alone validates database values, SQL, column privileges and supported types.

The helper's ordinal `editable`, `edit_reason`, generated/default/nullable/PK
metadata determines capabilities. Query results, views, missing configuration,
readonly profiles, no-PK tables and adapter-rejected engines/types stay read-only
with visible reasons. PostgreSQL may mark every column unsupported; MySQL can
reject individual columns. Rust's string/multiline presentation choices mirror
Swift's `GridColumnEditing`; they never establish editability. The reference's
generated-only DEFAULT insertion exception accepts only adapter-generated-column
reasons; an engine/type/privilege reason takes precedence.

Projection drives display, local sort/filter, selection copy and read-only row
details without changing originals. Row markers distinguish inserts, updates and
deletes; modified cells and pending row counts remain visible. Copy captures the
draft revision as well as grid/snapshot/result. Swift already uses clipboard v1
kind `default` and TSV `<DEFAULT>`; GPUI preserves those exact semantics. No new
clipboard version, probes, paste/import or native adapter changes are introduced.

## Editors and snapshot locks

Edit Cell/context Edit and Expanded Editor capture the original document,
result key, grid entity, protocol columns, ordinal capabilities, snapshot,
draft revision and catalog target. `CatalogTarget` retains the full original
profile/settings/generation/service session/helper context. No config=None or
demo fallback permits editing. A stale context disables staging while local
Cancel/Discard can still safely retain or remove the original local draft.

An inline editor sets `TableDocument.locks.inline_draft` before publication,
including when an older browse request is pending. Stage transitions to the
staged_changes count in the same UI turn. Page, server sort/filter and Refresh
recheck locks at capture, submission, each follow-up and atomic completion.
Direct late grid rendering also refuses replacement while any draft exists.
Local loaded-row sort/filter only changes projection and stable-ID selection.

Editors retain one plain EditorState across inline/expanded presentation and
ordinary render/focus changes. Short values appear in the cell; binary,
multiline/large values expand. Controls explicitly choose Value, NULL, DEFAULT
and supported Empty String. Typing into a NULL/DEFAULT placeholder changes it to
Value. Plain Return stages an inline value; expanded Return retains newlines.
Marked text blocks staging. Cancel restores the captured grid selection/focus
without editing SQL, adding Undo or recreating unrelated editor entities.
Row-detail editors remain selectable read-only projections; editing uses the
same captured cell workflow. Focused field input/copy/navigation takes precedence
and cannot run SQL. Actual desktop IME/focus/input behavior remains unverified.

No local editor/staging action calls the helper, opens a session, classifies SQL,
or executes mutation SQL. Standalone Preview SQL is available through Task 18
(PREVIEW.md); fresh-session atomic Apply and explicit recovery are now implemented
through Task 19 (APPLY.md). Runtime/native acceptance remains pending.

## Task 18-19 API handoff

- `Workspace::changes_capture(document, cx)` captures one retained result.
- `Capture { owner, grid, fingerprint, revision }` and
  `Owner { document, result, target, workspace }` keep exact ownership.
- `Fingerprint { columns, metadata, snapshot }` is exact ordinal equality,
  not a name-keyed or inferred-type digest. `Draft.revision` advances on edits,
  editor input/kind/open/close, insertion/deletion and Discard.
- `Workspace::changes_valid(capture, require_revision, cx)` validates the original
  document/grid/result plus original profile/settings/service/helper and snapshot.
- `Workspace::changes_batch(capture, cx)` refuses a live inline editor and freezes
  `ChangesBatch { capture, request }`. Request holds exact originals and sorted
  ordinal assignments; it is not live selection or a later draft projection.
- `sync_changes_locks(document, cx)` synchronizes inline/staged state. Keep
  `ReplacementLocks.previewing/applying/outcome_unknown/closing` for later work.
  Preview/Apply must revalidate metadata and policy, own fresh idle sessions and
  recheck this immutable batch before every asynchronous submission/completion.
- `ClosePhase::Changes(DocumentId)` and `CloseToken` capture each grid's exact
  fingerprint/revision. Discard approval does not clear data immediately. Later
  Cancel, stale revision, failed flush or failed profile publication preserves
  reviewed buffers. Finalization rechecks entity ownership and revisions before
  clearing; profile mutation clears only after successful persistence, skipping
  any newly changed draft. Return/Escape on review both choose Cancel.

Tab/window/profile edit/delete/disconnect all enter the same close flow before
rebinding or discarding. Existing Stop, transaction/unknown decisions, original
helper teardown ACKs, file_request guards and Finishing/latest SQL flush remain.
Clear SQL Drafts now includes SQL documents only and leaves table edits/service
sessions intact. Table drafts never enter SQL workspace/history DTOs. Task 22
now composes the complete Apply/export/running/file close graph in CLOSE.md.

## Prepared verification, not executed

Pure cases cover composite-key originals, revert-to-original, update/insert/delete,
generated defaults, exact numeric/temporal strings, NULL/empty/literal values,
binary validation, ordinal metadata, capability/engine/privilege reasons and v1
DEFAULT clipboard semantics. Native-smoke headless cases exercise production
editing/retained expansion/cancel, immutable batches, selected source mapping,
Run/field focus, late browse locks, helper-call counters, repeated close,
Return/Escape, later transaction Cancel, stale revisions, SQL-only clear, stale
profile contexts and failed profile publication retaining drafts. Existing close,
commands and table cases remain relevant. No runtime case was executed.

Completed static checks: default/native-smoke all-target check and Clippy with
warnings denied, formatting and whitespace. Logs: ignored build/gpui/task17-*.log.
The existing block 0.1.6 future incompatibility notice remains. No Rust/Go/Swift,
database, UI, credential or clipboard test/probe ran; no native compilation or
acceptance on Windows/Linux is claimed. Frozen baseline/manifests/shared fixtures
and the native Swift product remain unchanged.

Run at final integration and retain completed summaries and precise skips:

```sh
./scripts/gpui-prototype.sh test --locked -- grid_changes::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked -- results:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- close::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- changes_view::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- commands::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- catalog::tests --test-threads=1
./scripts/test-gpui-databases.sh
```

Use matching helper/build runners on supported target hosts. Verify actual grid
markers, short/large/binary editors, native focus/IME/keyboard/caret/Undo, Columns,
copy DEFAULT/exact values, read-only engines/types/permissions, late browse/DDL,
all Discard/Cancel origins and profile failure combinations on Windows 11 and
Ubuntu Wayland/X11. Compilation is not desktop, database or acceptance evidence.

Task 18 consumes ChangesBatch in preview_view.rs and preview.rs. Standalone
Preview SQL revalidates the frozen batch after every await and review, displays
helper-generated SQL/typed bindings, assesses exact changes.apply and revokes/
awaits its fresh original session teardown before review. Flow locks block local
edits/replacement and close/profile mutations while cleanup/review owns the batch.
Purpose-bound Apply preparation cannot reuse standalone approval/session/grants;
Task 19 now submits only after new same-session preview/assessment and explicit
review, retains authoritative completion across Stop/cleanup, and gates unknown or
committed-but-unreloaded data. See APPLY.md for APIs, recovery and deferred cases.

Task 22 close Apply projects live inline input into an immutable draft clone and
uses the ordinary new fresh-session preview/assessment/explicit Apply pipeline.
Cancel/known rollback keeps the original inline entity, text, selection and Undo.
Discard stays revision-bound and deferred through later review, final flush and
successful profile publication. Native focus/IME/Undo acceptance remains open.
