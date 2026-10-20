# GPUI script execution contract

Task 10 is code-ready; all test execution and native acceptance remain deferred.
GPUI targets Windows 11 x64 and Ubuntu 24.04 x64 (Wayland and X11). Mac GPUI
is development only; the macOS product remains SwiftUI/AppKit. Task 2 and all
171 native acceptance cells remain not-run. Builds do not depend on ignored docs.

## Immutable review and dispatch

Run Script enters `CommandId::RunScript` through the same capture/availability/
dispatch boundary as Run, menus and scoped shortcuts (COMMANDS.md). The captured
`Arc<PreparedFragment>` includes the entire unchanged source and original ordered
statements. No continuation rereads selection, reparses SQL after removing MySQL
DELIMITER directives, concatenates the batch into one execution, or redirects
work to the current tab. Current/selection Run still refuses multiple parsed
statements, including Swift's ambiguous custom-delimiter current-routine case.

`scripts::validate` refuses diagnostics, empty input and over 1,024 statements
before helper startup or credential lookup. The live path assesses one exact
ordered `Vec<OperationRequest>` on the captured tab's physical session, checks
returned policy and classification coordinates, and retains the originating
client. Go remains authoritative for classification and authorization.

A denied batch sends no execute and shows no approval dialog. Every accepted
script, including an all-read helper allow decision, opens an immutable whole-
source preview with original byte/UTF-16 classification ranges, reasons and
captured engine/endpoint/user/environment/readonly context. Classification fills
use original statement offsets; no SQL is silently omitted from the scrollable
preview. Return/Escape cancel; Run Reviewed SQL requires explicit activation.
Cancel or stale approval revokes the unused session grant and awaits its ACK
before releasing the busy lock. Demo review explicitly identifies synthetic
fixtures without claiming database classification or opening a helper.

## Ordered execution and bounded results

`live::execute` validates and enqueues each exact authorized statement in one UI
turn, installs its query ID and drains the original stream through its terminal.
The next statement starts only after that terminal reconciles transaction state.
It uses the same client, grant, physical session and immutable source/settings.
A source/profile/session change, Stop, first error or helper failure halts later
dispatch. Remaining statements become Skipped. Submitted work keeps the busy
lock until terminal recovery, even after edits or Stop; unknown outcomes block
another Run until the existing explicit disconnect/acknowledgement flow.

`DocumentState` retains each statement's original range, outcome, result-set
range, elapsed time, total rows, truncation, failure and optional typed adapter
position. Ordered sets include command-only sets. Successful completed prefixes
and their transaction state survive a later failure or a helper failure between
statements. Per-statement selectors and result cycling expose their context.
A cancelled/unknown/stale statement receives no success mark. Original-source
error navigation uses adapter scalar coordinates mapped through the captured
statement, including Unicode and CRLF; absent positions stay absent.

One `DisplayBudget` applies to the entire run: 1,024 sets, 1,000 rows and 8 MiB
including encoded metadata/row overhead. It preserves retained values exactly.
Exhausting it marks display truncation and continues authorized SQL, ACK/draining,
command terminals and final transaction reconciliation. Transport progress and
terminal queues retain their existing bounds; each stream's accumulator is also
bounded. No query is repeated to recover omitted display data.

Active range decorations and success gutter marks use the existing editor
entity and byte geometry; they do not change selection or Undo. Source edits,
profile saves and new runs clear source marks/error navigation. Explicit close
transaction commands use bounded independent source snapshots and never mark
unrelated editor text successful. Demo execution uses the same ordered outcomes
and display budget, stops at its first unsupported fixture and sends no SQL.

## Close and persistence extension boundary

- `DocumentState::busy()` means `operation.is_some()` throughout preparation,
  review, running, cancellation/revocation and terminal reconciliation. Reviewing
  deliberately has `task == None`, `phase == Reviewing` and no submitted query.
- `operation_source_valid(context, cx)` checks original identity/revision, exact
  editor source (for editor-bound runs) and profile settings. `operation_valid`
  adds Stop/unknown gates. `owns` ignores source edits for terminal ownership.
- `QueryTab::operation_client`, session/session generation and `query_id` retain
  original Stop ownership. `stop_live` sets Stop before dispatching cancellation;
  it never clears submitted work on cancel ACK. The async loop drains terminal
  and revokes unconsumed grant scope before ending. Demo Stop cancels local work.
- `record_live_statement` records one terminal without ending the batch;
  `end_live_batch` releases the final busy lock. `fail_live` retains completed
  prefixes/known transaction status and sets unknown locks where necessary.
  `finish_live` remains the single-operation/transaction-close compatibility
  entry. `finish_cancelled` ends work only after pre-submission/revocation safety.
- Task 11 now captures `CloseIntent` into `CloseFlow` and `CloseToken` through
  `request_close`/`stop_before_close` and actual disconnect ACKs (CLOSE.md).
  `run_live(..., Some("ROLLBACK;"), Some(token), ...)` and Commit use independent
  control snapshots on the original live helper/session without restarting it.
  Editor revisions cannot cancel that control source or receive success marks.
  `resume_close(token, ...)` advances only the original close; late callbacks
  cannot cancel a newer flow. Task 22 extends the staged-edit/export graph.
  Ubuntu session-manager logout integration remains an explicit Task 29 gap.
- Task 13 now consumes `execution_source` and submitted terminal outcomes once
  per StatementExecution::history_recorded, honoring history_allowed for internal
  close controls. Safe DTOs persist source/history only; no session, results,
  operation/query/grant/task/client/transaction state serializes. See RESTORATION.md
  for managed history, disconnected restore/reopen and fallible final close flush.

## Deferred verification

Prepared cases cover MySQL routine/current refusal, original Unicode/CRLF
classification/error positions, whole-run row/byte/set limits (including later
command terminals), completed multiset prefixes, terminal-gap Stop, cancellation/
unknown/retry locks, demo whole-source review/keyboard Cancel, edit/tab races,
partial failures and original error navigation. Backend cases check assessment
count/boundaries. Isolated DB cases check ordered read scripts on one physical
session, failed-grant invalidation, grant order/session binding/revocation/replay
and opt-in MySQL DELIMITER routine multiple sets with exact typed values. Existing
physical server-observation cancellation checks remain unchanged.

Only static checks ran: default/native-smoke all-target check and Clippy with
warnings denied, formatting and whitespace. Test targets compiled; no Rust,
Swift, Go, database, native UI or credential tests ran. Logs are ignored
`build/gpui/task10-*.log`; the existing `block 0.1.6` future notice remains.

Run at final integration with completed summaries and explicit skips:

```sh
./scripts/gpui-prototype.sh test --locked -- scripts::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked -- model:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- backend::contract_tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- workspace_tests --test-threads=1
./scripts/test-gpui-databases.sh
```

Run matching Windows/Linux helpers via the supported native build runners.
Actual Windows 11 / Ubuntu Wayland / Ubuntu X11 source review, keyboard defaults,
Stop/late terminal/helper-loss, session isolation, Unicode error navigation,
scroll/wrap/fold gutter geometry, both engine families and source/tab/profile
races still require native acceptance. Compilation establishes none of these.
