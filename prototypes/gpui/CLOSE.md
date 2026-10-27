# GPUI workspace close decisions

Task 22 is code-ready; runtime verification is deferred until final integration.
GPUI targets Windows 11 x64 and Ubuntu 24.04 x64, with separate Wayland/X11
acceptance. Mac GPUI is development only; the macOS SwiftUI/AppKit product is
unchanged. Task 2 and all 171 native acceptance cells remain not-run. Builds do
not read ignored planning documents.

## One captured graph

Tab, profile Disconnect, immutable profile edit/TLS/policy save or deletion,
window/system close, application Quit and Clear SQL Drafts enter `request_close`.
`CloseFlow` retains one monotonic `CloseToken`, exact document/profile IDs,
profile generations/settings, original physical-session helper owners, draft
fingerprints/revisions and retained focus. Repeated requests never replace that
flow, a chosen Stop/Commit/Roll Back, or an existing owner. Obsolete callbacks
cannot advance a different token or phase. Menu close captures the original
input focus before the popup takes focus.

New operations and profile mutations are frozen while closing. Inline editors
retain their original entities, text, selection, scroll and Undo, with writes
locked. SQL edits allowed before Finishing remain local; the final flush checks
the latest source/history state. Finishing renders source editors read-only.
Cancel restores retained focus, releases only the close locks and retains all
uncommitted drafts, editors, sessions and original operations. Return and Escape
choose Cancel in close/transaction/changes decisions; they never approve SQL.

## Original work, picker futures and publication

The flow captures file_request, loaded export_request, Run to File and changes
Preview/Apply tokens before awaiting. An already active review or native picker
keeps its original modal/future and immutable source/path. Close does not dismiss,
drop or retarget it. After that review/picker returns, close offers Cancel, Wait
and Continue, or Stop and Continue for outstanding owners. SQL execution/script
review is likewise preserved before the running-work decision.

Only captured existing continuations may proceed while close waits. SQL Save
may publish its captured source and retain newer edits as dirty. Open SQL drains
its chooser/read without adopting new documents into a frozen close scope. A
Run to File destination capture returning during closing cannot submit new SQL.
Native chooser cancellation retains the future until its original callback;
Stop prevents publication/submission rather than abandoning the task. Encoding
and prepared writes drain before unpublished temporaries are dropped. A known
published destination is never deleted as cancellation cleanup. Loaded exports
do not alter SQL file bindings, source revisions, titles or history.

Stop acts on affected documents only. Unrelated captured file/changes owners
finish normally; closing one tab cannot Stop another tab's query. Full Run to
File uses its original SQL-tab operation_client/session/query and recovery,
including separate SQL and file-publication certainty. Successful SQL followed
by failed/unverified publication is never rerun. Cancel ACK is not a terminal.
Submitted scripts, exports and Apply drain their authoritative outcome, grant
revocation and original-session cleanup. A timeout is a notice/refusal, never
proof of rollback or permission to drop a connect/session future. Explicit
changes cleanup failure leaves the original owner available for cleanup retry.
Catalog work has a retained Wait/Cancel decision before service teardown.

## Transactions, staged changes and uncertain Apply

Running SQL offers Cancel or Stop and Continue. Its selected Stop waits for the
same operation to finish; source-stale terminals still reconcile original busy,
transaction, history and unknown state. Open transactions offer Commit, Roll Back
and Cancel, bound to the exact session generation and original helper. Commit is
absent for failed transactions. No replacement helper receives an old textual
session ID, and no other tab's session is borrowed.

Pending table changes offer Apply, Discard and Continue, or Cancel. Discard is a
revision-bound deferred approval: no draft clears before later decisions, final
flush and successful profile publication. A later Cancel, stale revision or store
failure preserves every previously reviewed draft. SQL-only Clear Drafts leaves
table edits, recovery and catalog service sessions outside its removal scope.

Close Apply projects any inline input into an immutable cloned draft. It does
not stage into, replace or destroy the live inline editor. It then uses the normal
Task 19 Apply pipeline: a new purpose-bound fresh idle physical session, a new
helper-generated preview, exact batch assessment, explicit Apply Reviewed Changes
and a one-shot grant. Standalone Preview proof cannot authorize it. Original
batch/context is rechecked around every await, review and submission. A known
rollback/cancel/error aborts that close and keeps drafts/editors. A known commit
clears only its matching committed revision; a failed/skipped reload remains
ReloadRequired and can close safely without reapplying the batch.

An unknown Apply has its own explicit Discard Local Changes/Cancel close decision,
matching `CloseConfirmation.swift` and `ApplicationWorkspace.prepareToClose`.
This local teardown acknowledgment does not claim commit/rollback and does not
require database availability merely to close. It is separate from reapply
recovery: any retained table document remains Unknown after Disconnect, profile
mutation or local close discard. Plain Refresh/Discard/Disconnect cannot enable
Apply. Another Apply still requires successful current-context Inspect Data,
explicit Discard and Reload, and successful validated reload. Unknown SQL outcome
acknowledgment likewise does not infer rollback from disconnect or process exit.

## Physical helper ownership and authoritative teardown

`QueryTab.session_owner` retains original helper instance, session ID and session
generation beyond success, cancellation and known errors. RunFileRecovery retains
its exact original client too. Next Execute/COMMIT/ROLLBACK and each close target
use this owner, even if Workspace.backend now holds another helper with the same
textual session ID. Missing/stale ownership refuses. Catalog sessions retain their
original helper separately and cannot reconnect through a replacement helper.

Each live target requires its matching disconnect.ack before local retirement.
A refusal retains its exact session and drafts; acknowledged earlier targets stay
completed if a later target fails. `is_alive()` describes transport usability,
not process exit. `owned_process_exited()` uses the retained Child and nonblocking
try_lock/try_wait; an unavailable mutex or broken transport proves no exit. Failed
transport retains ownership until actual exit is observed or a real ACK arrives.
Close may wait for that exact child's exit and refuse retryably if still unproven.
A demonstrably exited owned helper cannot ACK: explicit uncertainty acknowledgment
permits local teardown without an invented ACK or database outcome. This prevents
a dead original helper from permanently trapping an otherwise reviewed window.

Tab/profile close never initiates helper termination, preserving out-of-scope
sessions/transactions on a shared helper. Window close retains all original helper
Arcs through target ACKs, then awaits `await_owned_exit()` for each exact owned
child. It requests graceful shutdown, observes/reaps exit and bounds its fallback
kill to that retained Child only. Actual exit is process teardown evidence, not a
shutdown ACK or commit result. Reapers release the child mutex between polls;
a failed kill cannot lead to an unbounded wait holding that mutex. No foreign PID,
process-name lookup or system trust/signing change exists.

## Latest local state and later integrations

Finishing owns the SQL persistence writer, waits out older writes, saves the
intent-specific post-close snapshot and compares the latest state again in the
same UI turn before removal. A newer edit/history change repeats the flush; a
failure keeps the window and drafts available. Window/profile close preserves
SQL sources; tab/Clear Drafts removes only the explicitly intended SQL records.
Restoration remains source/history-only and disconnected, with no sessions,
credentials, table results, drafts, grants, file paths or editor runtime state.

`close::finalizers` is the purpose-bound integration seam for Tasks 23/26/27/28.
Register one Finalizer per LanguageService/Appearance/ThemeLibrary/Shortcuts owner
while not closing. Its prepare callback receives the immutable token/intent/
document IDs and returns an owned future plus revision. Finishing awaits it,
rechecks its current revision and reruns a stale flush. All participants are
rechecked after SQL publication before ownership release. Errors retain drafts.
Actual LSP document close/shutdown and preference/theme/shortcut stores are not
loaded by Task 22; those tasks must register their original retained owners.

Task 29's frozen accessibility/session_end modules and gpui-component/gpui-base
0.7.3 patches are now declared and compiled on the Mac development host. The
maintained Linux `attach_session_end` hook accepts the actual owned GNOME client,
tracks registration-generation events and publishes only current Absent/Waiting
common ownership. Response/Cancelled/Forced never dispatch Quit or open UI.
Window Finishing awaits its exact unregister/shutdown before the latest final
flush. This conservative hook never advertises premature Ready. Actual normal
production startup attachment and native Linux protocol acceptance remain Task 29.
GNOME Query/End are noninteractive, with one/ten-second reply deadlines; neither
signal authorizes UI review or grants Reviewed exit. See PLATFORM_CORE.md.

The existing Windows owned-HWND WM_QUERYENDSESSION veto bridge and Mac development
applicationShouldTerminate hook remain. Only final normal window removal calls
termination::permit_exit. Forced OS termination, display-server loss, crash or
process kill remains ExitOutcome::Unknown and cannot promise async flush/recovery.
Actual Windows compilation/subclass lifetime and GNOME/Wayland/X11 delivery stay
open. Task 29 must expose stable native selectors on real rendered controls;
local GPUI Button IDs alone are not verified UIA/AT-SPI automation identities.

## Prepared verification, not executed

Prepared pure/headless/backend cases cover every close origin, repeated phases,
failed-transaction Commit absence, terminal gaps/Cancel ACK, source-stale replies,
original-helper/same-ID replacement after success/cancel/error, exact disconnect
refusal, transport versus observed child exit, dead-helper explicit acknowledgment,
shared-helper sibling profiles, deferred Discard/later Cancel/stale/store failure,
immutable inline input/entity/selection, retained native chooser futures and
latest awaited SQL/preferences flush. Existing fake-helper and both-database
observer cases cover scripts/full export/Apply grant, terminal, publication and
physical-session isolation. No test or database/credential/UI/clipboard probe ran.
Existing Python/Unix-only fault factories still require Task 30's frozen portable
fixture integration before their Windows cases can count as coverage.

Final implementation-time static evidence is in IMPLEMENTATION.md and ignored
build/gpui/task22-*.log. Run matching native helpers/build runners and retain full
completed summaries at final integration, including precise skips:

```sh
./scripts/gpui-prototype.sh test --locked -- close:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- backend:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- close:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- workspace_tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- changes_view::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- preview_view::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- run_file_view::tests --test-threads=1
./scripts/test-gpui-databases.sh
```

Native acceptance must observe exact retained focus/caret/scroll/Undo, picker
publication/cancel, simultaneous terminals, original physical transactions and
both recovery paths on Windows 11, Ubuntu Wayland and Ubuntu X11. Headless/static
checks do not establish these observations. Frozen baseline/fixtures/manifests/
reference/replay artifacts are unchanged.

## Task 26 appearance participant

The production Workspace registers its original Appearance owner while open.
It captures latest preference revision, store and broadcast publication completion;
Finishing awaits it before the final SQL snapshot/removal. Only current Published
succeeds. A stale error or stale success reflushes the latest owner; Superseded
alone never proves publication. Failed writable edits retain drafts and offer
Settings Retry/explicit Reload. Unchanged corrupt/read-only startup and explicitly
labeled preview-only changes have no writable reservation and do not trap close.
Prepared production-graph revision/failure/drain cases compile but remain unrun.


## Task 27 original theme library participant

Common close first invalidates the original Appearance Settings preview/chooser
UI authority while retaining every native picker, parse, reload and dispatched
publication future. The registered ThemeLibrary finalizer captures its exact owner,
revision, outstanding completion channels and latest reserved mutation. Canceled
native pickers drain only after their original OS callback; the pinned picker API
has no cancellation handle. Parse/review cancellation never reserves a write.

A dispatched commit reconciles actual normalized publication even after Settings
closes, suppressing obsolete automatic selector choices. Only successful Removed
resets matching current preferences. Its completion records foreground reconciliation
and the separately required Appearance reservation. ThemeLibrary precedes Appearance;
latest required preference publication then drains before SQL snapshot/removal.
Old success/error rechecks revisions, Superseded is never publication proof, and
latest failure/unverified durability refuses close with fixed recovery guidance.
Unchanged read-only fallback reserves nothing and never forces corrupt recovery.
Prepared picker drain/latest-library-and-appearance/sibling-token cases compile;
runtime and actual target desktop observations remain unrun.


## Task 28 original shortcut participant

The original Workspace registers one Shortcuts finalizer beside ThemeLibrary and
Appearance. It retains exact latest reservation/store/broadcast publication and
all dispatched reload/recovery jobs through their foreground reconciliation.
Settings dismissal invalidates the original recorder synchronously; accepted IO
keeps its original ticket, blocks overlapping edits and drains before final SQL
snapshot/removal. Only current Published plus actual latest_saved() is save proof.
Superseded/failed publication cannot authorize exit. Current revisions are checked
before stale success/error interpretation; reflush retains the same CloseToken
and sibling scope. An unchanged corrupt/read-only startup or disposable preview
has no accepted writable mutation, so closing never invents a default overwrite
or forces recovery. Explicit retry/reload remains available after refusal.
Existing SQL/file/Stop/transaction/unknown/Cancel/session/helper gates are unchanged.
Prepared owner/store/common-graph cases compile and remain unrun; see SHORTCUTS_CORE.md.
