# Helper protocol v3 contract

The Rust boundary implements the existing Go/Swift v3 protocol. No wire version,
adapter SQL, dialect classification or macOS product behavior changes here.
`backend_contract.rs` owns request/value/metadata types; `backend.rs` validates
submissions, matches response identities and delivers outcomes to the existing
workspace. This document and the shared fixtures are tracked build-independent
resources. Implementation and verification status lives in IMPLEMENTATION.md.

## Requests and results

`WireCommand` covers hello/connect, execute/catalog, changes.preview/apply,
operation.assess, cancel/disconnect/shutdown and stream.ack. Every ordinary
submission passes its typed validation before serialization. Catalog requests
include every existing kind and overload identity, completion page, sort and
all nine filter operators. Binary filter values remain Base64 text; adapters
choose parameter types, quoting, stable ordering and mutation SQL.

`ChangesRequest` retains ordered metadata snapshots, original row arrays and
assignments. `CellValue` distinguishes NULL, DEFAULT, empty text, literal NULL,
exact numeric text and binary Base64. Request binary validation accepts the
existing Go StdEncoding rules; emitted binary results must be canonical. SQL
result columns retain ordinal identity and repeated names. Catalog metadata
uses unique known fields; typed column permissions/generated/default/PK data,
completion FKs/signatures and preview bound parameters are validated when the
originating request completes.

Backend methods expose batch assessment, authorized execute, Run to File,
Preview and Apply through the same validated transport. The originating context
checks assessment count/ranges, preview order, Apply status/count and export
destination/format. Authorization is the helper's ordered, one-shot grant.
Later callers must retain the immutable reviewed operation batch; the backend
does not classify SQL or reuse grants. Preview/Apply callers must create their
own fresh idle physical session, never borrow a SQL-tab transaction. Go remains
the final policy, metadata, concurrency and transaction authority.

Exports return destination, format and full row count separately from bounded
display sets. A failed publication remains an error with the helper's known
transaction status and completed results; it never causes a rerun. Missing or
mismatched export success fields cannot become a successful query result.

## Transport and failure boundaries

- Frames are newline-terminated and limited to 16 MiB. Duplicate JSON keys,
  inapplicable response fields, missing fields, invalid identities, row widths,
  encodings, counts, metadata and stream sequences fail with fixed diagnostics.
- Each execution retains at most 1,000 rows / 8 MiB across at most 1,024 sets.
  Progress queues are bounded and may omit intermediate progress; their terminal
  outcome is retained even when progress fills the queue.
- Ordinary commands have 128 pending/queue slots and a 32 MiB queued-byte budget.
  Saturation refuses the unsubmitted request without invalidating other sessions.
  ACK and first Stop for a submitted query share a separate bounded priority
  lane. Duplicate Stop and finished-query requests cannot occupy reserved slots.
  Exact ACK sequence/credit messages are never coalesced; UI callers never wait
  synchronously for pipe writes.
- Every response must belong to the submitted request/session/query. Connect is
  the sole response that assigns a new session ID. An unrelated session cannot
  contribute transaction status or rows to an owned operation.
- Terminal errors retain only their completed set prefix; an unfinished streamed
  set is discarded. A malformed terminal preserves independently valid completed
  prefix sets and typed transaction status before failing the helper. Loss or
  invalid post-submission state remains uncertain; no known commit or rollback
  is invented. Previously queued successful terminals still use the originating
  helper/session generation in the workspace.

## Deferred verification

The user explicitly deferred test execution to final integration. Task 4 adds
shared `protocol/fixtures/contract-v3.json` consumers in Go, Swift and Rust, plus
portable identity/metadata/value/partial-terminal/queue/control/helper-death cases.
Existing framing, byte/row/set budgets and terminal-queue cases remain. Compile
and static checks do not establish native or database acceptance. The final
integration commands and open target-native exercise are in IMPLEMENTATION.md.

Task 18 adds begin_assessment/AssessmentRequest to publish the existing assessment
query ID synchronously with submission, without wire changes. Preview preparation
binds exact changes.apply operations, generated SQL/typed parameters and helper
assessment to one fresh purpose-bound session. No generated SQL is classified as
execute. Standalone grants are revoked and the session closed before review; Apply
must prepare again on another fresh idle session. See PREVIEW.md.

Task 19 adds one-shot Approval::begin_apply/PendingApply on that same preparation
session, synchronous Apply query-ID publication and original-client authoritative
terminal/cleanup ownership. Pre-mutation readonly failures cannot create unknown
commit state; submitted transport loss can. Disconnect never clears mutation
uncertainty, and known commit plus failed reload cannot authorize another Apply.
No protocol or adapter change was required. See APPLY.md for exact recovery and
prepared independent-observer/fault cases. Runtime execution remains deferred.

## Task 21 additive full-export contract

Protocol v3 now optionally advertises hello capability capturedExportV1. The paired
helper consumes destination existence/hash/size/time/native file+parent identity
in the exact assessed export, and emits ACK-sequenced query.progress beyond display
limits. Optional sqlCompleted/sqlNotExecuted/exportPublication error fields keep
known SQL completion, pre-execution refusal and filesystem uncertainty separate.
Rust and Swift reject inconsistent flags and refuse captured export when the
capability is absent; legacy missing fields never prove SQL success. Frozen
fixtures remain unchanged; additive run-to-file-v1.json has three consumers.
RUN_TO_FILE.md records publication, compatibility and Task 22 recovery ownership.
Task 31 additionally requires exact packaged GUI/helper build matching.
