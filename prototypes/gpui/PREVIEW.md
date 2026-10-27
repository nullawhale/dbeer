# GPUI changes preview and Apply preparation

Task 18 is code-ready; runtime checks are deferred to final integration. Targets
are Windows 11 x64 and Ubuntu 24.04 x64 (Wayland/X11). Mac GPUI is development
only; the macOS SwiftUI/AppKit product is unchanged. Task 2, all 171 frozen native
cells and Task 29's GNOME session-manager bridge remain open. Builds do not read
ignored docs. Task 19 now implements actual Apply with another fresh session;
see APPLY.md for submission, mutation uncertainty and recovery.

## Standalone Preview

Preview SQL freezes `changes_view::ChangesBatch` before reading credentials. It
contains the original owner/document/result/grid, exact ordinal metadata/columns/
snapshot fingerprint, draft revision, original row values and ordered assignments,
and original CatalogTarget profile/settings/generation/service session/helper.
`Workspace::changes_batch_valid` requires exact capture and request equality.
It is checked after credentials, connect, preview and assessment, immediately
before each submission, before presenting the review and after closing review.
Profile/TLS/environment/readonly changes, reconnection, helper replacement,
metadata/snapshot edits and every draft revision invalidate the attempt.

An explicit Preview action alone reads the original profile's OS credential store.
Passwords stay in the in-memory connect request, never argv/env/logs or storage.
There is no demo/config=None fallback and no implicit profile/service reconnect.
A new connect opens a fresh idle session on the original captured helper. Current
SQL-tab and catalog IDs are excluded at connect completion. Unexpected fresh
transaction/capability responses own teardown but cannot submit work. SQL-tab
transactions, SET and temporary state are never borrowed or changed.

Go generates each statement via existing `changes.preview`. Rust never assembles
mutation SQL or substitutes parameters into SQL. The readonly, selectable review
shows each exact generated statement, its ordered typed JSON parameters/kinds,
the helper's whole-batch classification/decision, and the exact frozen originals/
assignments. NULL, empty and literal NULL, DEFAULT, exact numeric/temporal text,
Base64 binary, Unicode and CRLF remain distinct. DEFAULT is an assignment/SQL
keyword, not an invented bound value. No query is executed to estimate row counts.
The original profile/endpoint/user/environment/readonly context is displayed.

Standalone Preview assesses `[OperationRequest::Apply { changes: exact_request }]`
on that same fresh session. The helper classifies changes.apply directly, with
empty statement ranges; generated SQL is never assessed as SQL execute commands.
The existing v3 parser still validates operation order/count, parameter types,
idle state, helper decision, policy, identity and grant scope. No wire fields,
version, frozen manifests/reference/shared fixtures or adapters are changed.

Every success, failure, stale callback and Stop revokes unused authorization and
awaits the original session's disconnect before review or unlock. A standalone
preparation cannot create an Apply approval; closed-session grants cannot authorize
anything. Return/Escape and Close Preview only close the standalone review. Each
retry opens another fresh session and preserves all local drafts after failure.

## Ownership, cancellation and close

`preview_view::Flow` owns a monotonically allocated token, immutable batch,
sticky shared Cancellation, original FreshSession, exact current preview OR
assessment query ID, phase/status and retained task. `begin_assessment` now
synchronously enqueues the existing operation.assess and exposes its query ID;
its `AssessmentRequest::finish` awaits the unchanged validated reply. Enqueue
and ownership publication occur in one UI turn. Stop captures the preview token,
so an old menu capture cannot stop a later attempt on the same table.

Cancel Preview and common Query Stop invalidate before any later submission and
send cancel only through the retained original client/session/query. Cancel ACK
is not the query terminal: readonly preview/assessment drains before cleanup.
A 30-second preparation deadline requests Stop once, without dropping a pending
credential/connect future and losing an eventual session ID. A hung connect or
query remains owned until its response/helper death. This intentionally keeps
locks and close refusal; no unknown mutation outcome is invented for Preview.

Cleanup invalidates all proof clones, waits up to five seconds for grant revoke,
then submits disconnect even if the revoke ACK was lost. A five-second teardown
notice keeps waiting for that same disconnect; it does not retry database work
or release ownership. An explicit disconnect error retains the original session
and a Cancel Preview cleanup retry. Original-client ownership also survives a
lost UI callback; cleanup never consults a replacement workspace.backend.

ReplacementLocks.previewing blocks browse/Refresh replacement at the existing
capture/submission/follow-up/completion boundaries. Local edits/Discard/Columns
cannot change the reviewed table while a flow owns it. Stop/failure leaves
original rows, editor entities and staged values intact. Table/grid/session/
preview/grant data stays outside SQL restoration/history DTOs.

Task 22 now captures Preview/Apply owners in the common close graph. Existing
review/picker UI and credential/connect futures remain retained; explicit Stop
uses the original helper/query and awaits terminal/revocation/disconnect cleanup.
A cleanup refusal retains the original owner for retry; transport failure alone
is not observed child exit. Close-owned Apply opens another fresh purpose-bound
session and exact review, never reusing standalone proof. Deferred Discard,
retained inline editors, unknown-local-close acknowledgment and latest SQL flush
are composed in CLOSE.md. Forced termination cannot promise asynchronous cleanup.

## Shared Apply preparation APIs

- Freeze a **new** `ChangesBatch` and call `changes_batch_valid` before/after
  every await and user decision. Keep the capture's original profile and helper.
- Connect another fresh idle session, exclude all live SQL/catalog/preview IDs,
  and adopt it as `FreshSession::adopt(..., Purpose::Apply, policy, cancel, ids)`.
  `valid` rejects nonidle/capability failures, Stop, teardown and helper loss.
- `Plan::new(exact_changes)` retains one ordered changes.apply operation.
  `Plan::preview(&session)` returns PendingPreview with `query_id` and `finish`.
  PendingPreview binds its exact Plan AND fresh session, returning Previewed.
- `Previewed::begin_assessment()` uses that same session and exact operation
  array; PendingPreparation exposes `query_id` and `finish -> Arc<Preparation>`.
  Checks require exact original policy and helper changes.apply response shape.
- `Preparation::{display,plan,session,requires_confirmation,rejected}` expose
  immutable review/context. Re-preview/assessment advances a session revision,
  invalidating all earlier preview/approval clones even in that same session.
- `Preparation::approval(explicitly_reviewed)` refuses Standalone, deny, stale
  proof or unreviewed confirm. `Approval::authorization_for(&same_arc)` requires
  exact Arc identity and live session revision. Apply also revalidates the
  immutable UI capture immediately before submitting exact `plan.request()`.
- Stop uses sticky Cancellation plus `FreshSession::invalidate`, original
  client/session/current query. `FreshSession::cleanup` revokes and disconnects.
  Task 19 adds one-shot Approval::begin_apply/PendingApply, explicit Apply review
  and mutation recovery in the same retained flow; see APPLY.md. No automatic
  retry is implemented.

## Prepared verification, not executed

Pure cases cover exact typed originals/assignments/DEFAULT, operation order,
readonly SQL plus separate parameter display, partial/truncated/nonidle previews
and shared pre-submission cancellation. Disposable backend fixtures cover unique
fresh sessions, standalone approval refusal, same-Arc/session/revision grants,
Stop before/after readonly submission, unused grant revoke, preview error/retry,
failed disconnect/retry and original helper cleanup with replacement untouched.
The Unix fake-helper fixture records command types only and accepts no DML/SQL.
Headless production validation/locks/Stop/close cases exercise mutable policy,
endpoint, service, generation, metadata, draft and helper context at asynchronous
boundaries, stale Stop captures and preserved drafts. They do not claim native
OS credential prompts, actual scheduling or UI timing acceptance.

Prepared disposable PostgreSQL/MySQL cases build composite-PK rows containing
NULL, exact numerics and binary, preview update/default insert/delete twice on
new sessions, assess the exact request, reject standalone approval, and compare
independent observer rows plus an unrelated open SQL transaction's SET and private temporary-table state.
Those tests are gated by DBEER_GPUI_DISPOSABLE_DATABASES=1. No database ran here.

Completed static checks only: default/native-smoke all-target check and Clippy
with warnings denied, fmt/whitespace; ignored logs build/gpui/task18-*.log. Existing
block 0.1.6 future notice remains. No Rust/Go/Swift/DB/UI/credential/clipboard test
or target Windows/Linux compilation ran. Run at final integration, retaining
completed summaries and explicit skips:

```sh
./scripts/gpui-prototype.sh test --locked -- preview:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- backend::contract_tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- preview_view::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- changes_view::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- commands::tests --test-threads=1
./scripts/test-gpui-databases.sh
```

Use matching target helpers/build runners. Verify actual OS credential prompts,
profile/draft changes during every stage, Cancel/Stop/query terminal gaps, failure/
helper replacement/cleanup timeouts, exact selectable large/binary/Unicode values,
Return/Escape/default buttons, native close and SQL transaction/temp-state
isolation on Windows 11, Ubuntu Wayland and Ubuntu X11. None is claimed complete.
