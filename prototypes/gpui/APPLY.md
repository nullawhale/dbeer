# GPUI atomic Apply and mutation recovery

Task 19 is code-ready on 2026-10-19. Runtime verification is deferred to final
integration. Targets remain Windows 11 x64 and Ubuntu 24.04 x64 (Wayland/X11).
Mac GPUI is development only; the macOS SwiftUI/AppKit product is unchanged.
Task 2, all 171 native cells and Task 29's GNOME session-manager bridge remain
open. Builds do not depend on ignored docs. Protocol v3, shared fixtures, frozen
baselines/manifests/reference/replay and the Go mutation adapters are unchanged.

## Fresh session and exact approval

Apply freezes a new `changes_view::ChangesBatch` containing original typed rows,
ordered assignments, exact ordinal metadata/capabilities, result/grid/snapshot,
draft revision and original profile/settings/policy/service/helper context.
`Workspace::changes_batch_valid` runs before credentials and after every await,
before each readonly submission, before review, after review and immediately
before Apply enqueue. Profile/TLS/environment/readonly, helper, service generation,
metadata or draft changes refuse further submission and preserve local edits.

Explicit Apply reads only that original profile's OS credential store, then opens
another idle physical session on the retained original client. SQL-tab, catalog
and current preview IDs are excluded at connect completion. Unexpected fresh
engine/transaction/capability responses still own cleanup; borrowed IDs are refused
without disconnecting the borrowed session. There is no implicit profile reconnect,
credential fallback or mutation SQL construction in Rust.

That new `FreshSession(Purpose::Apply)` requests helper-generated parameterized
preview and assesses exactly `[OperationRequest::Apply { changes: frozen_request }]`
on the same session. Generated SQL is displayed separately from ordered typed
parameters and exact frozen originals/assignments. NULL, empty text, text NULL,
DEFAULT, exact numeric/temporal strings, binary, Unicode and CRLF stay distinct.
All helper-allowed batches still require the explicit **Apply Reviewed Changes**
button. Denied batches cannot submit; Return, Escape and Cancel cancel review.
The profile/endpoint/user/environment/readonly and helper decision are visible.

`Preparation::approval(true)` and `Approval::authorization_for(&same_arc)` retain
same-Arc, purpose, session and assessment revision checks. `Approval::begin_apply`
consumes that revision before synchronously enqueueing exact `plan.request()`.
Every other approval clone becomes invalid, even on enqueue refusal. The returned
`PendingApply::query_id()` is published in the flow in that same UI turn. It retains
the original client/session until its terminal is drained. No retry is automatic.

## Stop, authoritative completion and cleanup

`preview_view::Flow` now owns either standalone Preview or Apply under the same
monotonic token, sticky shared Cancellation, immutable batch, original session,
current preview/assessment/Apply query ID, review channel and retained task.
Common Query Stop uses that captured flow token; stale menu captures cannot stop
a later attempt. Stop before/during credentials, connect or review prevents later
enqueue. Pending credential/connect work is never dropped: an eventual session is
adopted for teardown even after Stop or stale context.

Stop after enqueue invalidates proof, sends cancellation using the original
client/session/query and waits for that submitted Apply's authoritative terminal.
Cancel ACK does not establish rollback. A 30-second stage notice requests Stop
once and keeps waiting; review has no timer. A helper-authoritative success remains
committed after Stop or a later context change. A helper-known conflict/constraint/
missing-row/deadlock/cancel result preserves every original row and draft.

Only submitted Apply owns mutation uncertainty. Transport/helper loss after enqueue
(including before query.started or after COMMIT without ACK) is unknown. Readonly
preview/assessment transport failures are normalized before mutation submission and
cannot invent an unknown commit. There is no retry or inference from disconnect.

Every path revokes unused authorization and awaits disconnect on the original
client. Revoke waits at most five seconds before disconnect is submitted. A teardown
notice after five seconds continues awaiting the same disconnect. Explicit cleanup
failure keeps the session, frozen batch and authoritative completion in the flow;
Cancel/Stop retries cleanup alone. It never resubmits Apply or loses a known commit/
unknown terminal. Helper death releases that cleanup owner only after its terminal
classification is retained; it does not establish rollback. Task 22 now captures this flow in the common close graph and awaits its work,
cleanup and review without replacing the original owner. Explicit Stop is sticky;
close-owned Apply uses a new fresh session and exact review. Forced process termination cannot promise asynchronous cleanup.

## Known commit and unknown commit are different

`complete_changes_apply` consumes the retained terminal after cleanup. An
acknowledged commit clears only the matching committed draft revision and sets
`TableDocument.recovery = ChangesRecovery::ReloadRequired`. If the original UI
batch/context still matches, `reload_changes_snapshot(document, Some(original_target))`
starts one readonly columns/browse/columns refresh through the captured table
service. It never borrows the Apply session or SQL tab. Stale context prevents this
automatic refresh. A changed local revision is preserved for explicit Discard.

Failed, busy or unavailable reload leaves **ReloadRequired**, the known-commit
notice and Apply/edit/export refusal. **Retry Reload** calls
`reload_changes_snapshot(document, None)` and uses only an explicitly connected
current service; it cannot reapply changes. Only a successfully validated new
snapshot (`TableDocument::commit`) clears ReloadRequired. Regular explicit Refresh
can also supply that successful snapshot. No failure turns a known commit unknown.

An unknown terminal preserves original rows and drafts, sets
`ChangesRecovery::Unknown`, and keeps `locks.outcome_unknown`. Ordinary Refresh,
Discard, Preview and Apply are refused. Affected close/profile mutation now
requires Task 22's explicit unknown-local-discard acknowledgment. Disconnect/helper replacement does not clear recovery. Editing/Apply and
loaded table export are also refused in sibling documents for the same profile
and object while any such recovery remains unresolved. SQL-only Clear Drafts
remains scoped to SQL.

Recovery requires two explicit user actions:

1. **Inspect Data** opens a new table document for the same original object and
   profile/settings, through a currently explicitly connected catalog service. It
   never executes mutation SQL. Only successful validated columns/browse/columns
   publication creates `ChangesInspection { document, target, snapshot }`. An empty
   newly opened tab, failed load, stale result or changed service does not qualify.
   The retained proof requires the exact live helper/settings/service generation,
   unchanged loaded snapshot and an idle inspection document. Reconnection, another
   service generation, a pending refresh or closing that inspection tab invalidates
   the proof; inspect again. Inspection is a loaded page, not proof of the COMMIT
   outcome or exhaustive verification of every affected row; the user must inspect
   the affected data using the available table navigation.
2. Return to the original tab and click **Discard and Reload**. That action is the
   user's acknowledgment that they inspected the data and chooses to discard the
   local batch. It rechecks inspection proof, clears local edits, changes recovery
   to ReloadRequired and requests a readonly reload. Failed reload still blocks
   editing/Apply/export until a new validated snapshot succeeds. No old request or
   grant can be reused. Disconnect ACK never substitutes for either action.

These are volatile table states and remain outside SQL restoration/history DTOs.
Normal close cannot silently drop an unknown batch. Task 22 composes the
existing close token, deferred Discard, latest-state Finishing flush and profile
publication. Explicit Discard Local Changes permits local close without database
availability, matching Swift; retained documents still require the inspection and
successful reload path before Apply. Original helper process exit is observed
separately from transport liveness; no impossible ACK or rollback is invented.

## Go remains the transaction authority

Frozen Swift behavior is in `ApplicationWorkspace+Changes.swift`. PostgreSQL
`helper/internal/postgres/changes.go` uses a fresh idle session, a transaction/table
metadata lock, exact ordered snapshot metadata, full-row SELECT FOR UPDATE comparison
and one-row effects. MySQL `helper/internal/mysql/{changes.go,changes_plan.go}` uses
strict transactional base tables, metadata and row locks, full-row comparisons and
its cancellation/recovery gate. Conflicts, constraints, missing rows, deadlocks and
cancellation roll back the entire batch. Lost COMMIT ACK is explicitly unknown.
No adapter or mutation SQL was ported into Rust or weakened for frontend behavior.

## Task 20 export handoff

`Workspace::confirmed_loaded_table_snapshot(document, cx) -> Option<ResultSet>` is
the production capture boundary for loaded table exports. It refuses closing/file
work, inline/staged edits, browse/reload, Preview/Apply/review/cleanup and committed/
unknown recovery (including sibling documents for the same profile/object). It
checks retained grid/original/snapshot equality and clones `tab.result_sets[0]`,
which is the confirmed backend-loaded physical rows in original order. It never
uses `ResultGrid`'s projected edited rows or local filter/sort/selection, queries,
reconnects or reads credentials. A clean disconnected loaded snapshot is allowed.

Task 20 must capture document/result/grid/snapshot and recheck around the native
save dialog without the export's own file/modal owner invalidating itself. It
must preserve truncation/row-count disclosure and the chosen NULL marker rules.
Frozen Swift entry points are `Views/DataGridView.swift` and
`Views/ApplicationWorkspaceView.swift`, passing `ExportResultSet(result)` to
`ApplicationWorkspace.exportLoaded`; `ResultExport.swift` copies `result.rows`.
These entry points export all loaded physical rows, not selected/locally filtered
rows. Task 20 must inspect the reference itself for exact JSON/CSV and save behavior.

## Prepared verification, not executed

Pure/backend/fault cases cover exact immutable typed batches, single-use proof,
current query IDs, standalone refusal, Stop before enqueue/during review/after
submission, authoritative success versus rollback after Stop, known conflict,
lost terminal/helper death, original-client cleanup and cleanup retry without
reapply. The disposable Python fixture logs command types only and refuses SQL.
Headless production completion/locks cover stale context after submission, known
commit plus a failed TableDocument reload transition, unknown persistence across
disconnect, refusal of plain Discard/Refresh/reapply and explicit close acknowledgment, empty/stale inspection
proof, explicit acknowledgment and original loaded export rows. They do not prove
native scheduling, actual credential prompts or desktop focus/timing.

The extended disposable PostgreSQL/MySQL orchestration case uses independent
observer, catalog and open SQL sessions. It prepares/applies composite-key changes
with generated/default/NULL/exact numeric/binary values, proves later-operation
full-row conflict/missing-row/constraint rollback, checks metadata changes after
preview/assessment, and compares the unrelated SQL transaction, SET and private
temporary table before/after Apply. Existing Go integration suites independently
cover row-lock/deadlock/cancel recovery and real COMMIT-with-lost-ACK observer
faults for both adapters, with no automatic second commit. These cases are prepared,
not passing evidence. Disposable databases require DBEER_GPUI_DISPOSABLE_DATABASES=1.

Completed static checks only: default/native-smoke all-target check and Clippy with
warnings denied, formatting, Python fixture syntax and whitespace. Ignored logs:
`build/gpui/task19-*.log`. The existing block 0.1.6 future-incompatibility notice
remains. No Rust/Go/Swift/DB/UI/credential/clipboard runtime test or probe ran and
no Windows/Linux native build or acceptance ran.

At final integration, retain completed summaries and explicit skips:

```sh
./scripts/gpui-prototype.sh test --locked -- preview:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- backend::contract_tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- preview_view::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- changes_view::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- commands::tests --test-threads=1
./scripts/test-gpui-databases.sh
./scripts/test-postgres.sh ./scripts/test-mysql.sh ./scripts/test-go.sh
```

Use matching native helper/build runners and supported database versions. Verify
actual credentials, stage/context/Stop/current-ID races, cleanup failures/timeouts,
helper replacement/death, selectable exact values, review Return/Escape/default
buttons, SQL transaction/SET/temp isolation and both recovery paths on Windows 11,
Ubuntu Wayland and Ubuntu X11. Runtime/native acceptance remains unchecked.


Task 20 now consumes `confirmed_loaded_table_snapshot` for physical loaded-row
export and retains original document/result/grid/snapshot/profile generations
through Save. Inline/staged work, browse, Preview/Apply/review/cleanup and both
recovery states block table export, including affected sibling objects. The
export owner itself does not invalidate confirmation. No export path reconnects,
assesses or submits SQL; SQL file binding and drafts stay unchanged. See EXPORTS.md.
