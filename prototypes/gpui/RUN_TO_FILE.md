# GPUI complete Run to File

Task 21 is code-ready on 2026-10-19. Runtime tests are prepared and deferred until
final integration after Task 32 implementation. Targets remain Windows 11 x64 and
Ubuntu 24.04 x64, with independent Wayland/X11 acceptance. Mac GPUI is development
only; the macOS product remains SwiftUI/AppKit. Task 2 and all 171 native cells
remain open. Builds do not depend on ignored planning documents.

## Capture and exactly-once execution

Query menu Run to JSON File and Run to CSV File use common command capture. The
Task 8 resolver supplies the original complete source, exact selected/current
statement and byte/UTF-16 ranges. Exactly one statement is required; malformed,
incomplete, client commands and multiple selected statements are rejected before
helper startup or credentials. There is no loaded-result encoding in this path.

One monotonic `Workspace.run_file` token owns Review, Choosing, Capturing and
Executing phases. Its immutable command capture retains original document,
profile/settings, profile generation, source/session revisions and physical SQL
session. Review explains full scope and exact-once execution. CSV requires an
explicit nonempty NULL marker. The native Save picker owns overwrite confirmation;
its exact path and custom extension are retained. The destination is captured on
a background worker before credentials or query submission: explicit absence or
regular-file SHA256/size/modification time, and native file/parent identities.
Capture reads existing file bytes in bounded chunks without retaining them.

Chooser Cancel, stale source/profile/session or replaced token submits no SQL.
Every pre-submission continuation checks the original capture. Profile generations
are checked even when new settings happen to equal old settings. The retained
editor and SQL file binding are unchanged. Direct and common entry guards exclude
other file, export, browse, changes and profile work while the owner is active.
Tab selection can change without redirecting this operation.

The live SQL execution coordinator carries the typed ExportRequest alongside the
same prepared fragment. It uses the tab's own session, including existing temp
tables, SET values, open/failed transaction state, and original helper; it never
borrows the profile's catalog session or assumes a fresh connection. A missing
SQL session is opened explicitly for that operation. Helper assessment receives
exactly one execute operation with the same SQL, destination fingerprint, format
and marker that will be enqueued. The helper's one-shot authorization binds all
those fields and the physical session. Policy confirmation uses the existing
whole-source classification review and original-client revocation on Cancel.

A single `BackendClient::run_to_file` submission performs the complete database
execution. Full rows stream in Go directly into the export writer before display
limits. JSON retains ordered result sets, ordinal duplicate columns, NULL/empty/
literal NULL/DEFAULT text, exact numeric strings, Unicode/CRLF and Base64 metadata.
CSV rejects a second result set or a collision with its NULL marker. Such writer
errors do not stop SQL terminal draining. Loaded CSV remains CRLF; the established
full helper CSV format remains LF. No frozen format fixture was rewritten.

## Progress, Stop and authoritative recovery

The original operation owns preparation, policy review, submission, current query
ID, terminal recovery and history. Assessment IDs are published synchronously with
enqueue; execute IDs are published in the same UI turn as submission. Stop during
preparation records cancellation intent and awaits outstanding work. Review Cancel
revokes the original unused grant. Stop after submission addresses the original
client/session/query; cancel.ack never clears busy state or proves SQL completion.

`query.progress` reports cumulative full rows and the current result ordinal,
including counts beyond 1,000 rows, 8 MiB and 1,024 retained display sets. It shares
the ordered sequence/stream.ack credit with display chunks. This bounds delivery
and prevents progress from overtaking a terminal. It does not enter the result
accumulator or reset its display budget. Stop continues to work while progress is
being acknowledged or file publication is pending.

After submission, source edits and changed UI context suppress stale displayed
results but do not drop the original stream. The original tab still reconciles
transaction status, busy ownership, statement history and unknown outcome. A
successful export reports its full exported count even when Stop arrives after
publication. No callback writes to the newly active tab or a replacement helper.
History records one exact submitted statement at its authoritative terminal;
preparation, rejected review and helper-reported SQL-not-executed failures do not
record. Internal transaction close SQL and safe restoration DTOs are unchanged.

`DocumentState.run_file_recovery` is transient and contains operation/query/session
IDs, session generation, original helper client, exact export request, SQL-completion certainty and
Published/NotPublished/Unknown publication state. It is never serialized in SQL
restoration/history/profile DTOs. A known SQL completion plus failed publication
is distinct from SQL failure, lost terminal and uncertain commit. There is no
SQL replay or automatic retry for a failed save. Private incomplete/unpublished
work is cleaned up; the app does not offer a save retry by rerunning a mutation.

## Helper contract and compatibility

Protocol version stays 3 with additive optional fields. The matching helper's
hello.ack advertises `capturedExportV1`. That capability covers captured destination
checks, complete streaming/progress, exact grant binding and explicit publication
outcomes. Rust and Swift refuse a captured export before SQL when it is absent.
Legacy error replies without completion fields never imply SQL success or rollback.
Task 31 must additionally bind packaged GUI and helper to an exact build identity.

- ExportRequest.destination contains exists, size, sha256, optional decimal
  modifiedNanoseconds and optional native `identity`/`parentIdentity` strings.
  IDs use decimal device/inode on Unix and volume/file index on Windows. Field
  lengths and syntax are validated. No existing bytes or secrets enter messages.
- `query.progress` contains correlated request/session/query IDs, positive shared
  sequence, resultIndex and cumulative rowCount. It requires stream.ack.
- An error may carry sqlCompleted=true only after the adapter's successful
  authoritative terminal. It then carries exportPublication=notPublished/unknown.
  An error before adapter invocation may carry sqlNotExecuted=true. These flags
  are mutually exclusive and cannot accompany outcomeUnknown=true.
- exportPublication=unknown refers to filesystem publication, independently of
  SQL outcomeUnknown. No file outcome substitutes for transaction status.

The additive `run-to-file-v1.json` fixture is consumed by Go, Rust and Swift. The
existing contract/export fixtures, baseline hashes, manifests and replay remain
unchanged. Swift also captures destinations before execution and handles ordered
progress/structured errors; the product UI remains native SwiftUI/AppKit.

## Publication and filesystem limits

The helper captures and compares the confirmed target before adapter invocation,
then retains directory/file identities and a cooperative Unix lock. It creates an
exclusive same-directory private temporary: 0600 on Unix; a protected owner-only
DACL on Windows atomically at CREATE_NEW, with explicit retained read/write,
delete and security access rights before writing query bytes. Existing target permissions/DACL are
retained on publication. Symlink/nonregular targets, appeared/edited/removed files,
retargeted parents, read-only targets, sharing and cooperative-lock failures refuse
replacement. Captured absence uses no-replace publication.

All generated bytes pass through an incremental digest. After successful SQL the
writer flushes, syncs, rechecks the temporary's native identity and exact digest,
and revalidates the destination before publication. Cancellation and publication
share a mutex; cleanup removes only the owned unpublished temporary. A substitute
at its name is preserved. There is no delete-destination fallback.

Unix replaces an existing destination with rename and publishes an absent target
with same-filesystem no-replace link/unlink. Windows uses ReplaceFileW for an
existing target, preserving its DACL/attributes, and MoveFileExW without
REPLACE_EXISTING for captured absence. Documented partial ReplaceFile failures
1175/1176/1177 remain explicitly unverified; the app does not claim destination
preservation for them. Other known failures and cancellation preserve the previous
destination. A directory-sync failure after observed publication does not become
a SQL/export failure. Authoritative SQL success is retained on any save failure.

The Windows API behavior was checked against Microsoft's
[ReplaceFileW documentation](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew)
and [MoveFileExW documentation](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw).
Cross-compilation is type evidence only. Actual Windows sharing/DACL/partial-replace
faults remain native acceptance. Locks/identities/digests are cooperative protection,
not an adversarial external-writer compare-and-swap or a power-loss guarantee.

## Task 22 handoff and prepared verification

Task 22 now captures Run to File in CloseFlow, retains native chooser/capture
futures, and awaits original authoritative SQL/export recovery after explicit
Stop or Wait. A destination capture returning during closing cannot submit SQL.
Successful SQL plus a file error remains non-retryable; close never reruns it. Preserve CloseToken/latest Finishing SQL
flush, deferred draft discard and retained editor identity when extending this.

Task 22 now composes these separate owners: run_file token/phase/immutable command,
run_file.export/operation; tab.operation/phase/query_id/operation_client/task;
run_file_recovery original client/operation/query/session/generation/SQL/publication certainty;
loaded-only export_request; file_request; Preview/Apply cleanup and unknown/reload
recovery. Never cancel a Task or disconnect a replacement helper as proof that a
submitted full export ended. Known SQL success with a file error permits no rerun.

Prepared cases include pure single-statement refusal/fingerprint/identity/symlinks;
original-document chooser Cancel/stale source/profile/token and close guards;
fake-helper exact grants, execute counts, full progress, late Stop/ACK/terminal,
helper loss, missing capability and publication failure; Go private temporary,
external target, lock/read-only/temp corruption/sync/cancellation and Windows
sharing faults; complete JSON beyond all display limits and CSV multiple sets;
Go full-drain SQL-success/file-failure separation; and disposable PostgreSQL/MySQL
observer counts, exact-once mutations, independent temp/SET/transaction state.
These are prepared tests, not passed runtime evidence.

Final integration commands (after all remaining implementation):

```sh
./scripts/gpui-prototype.sh test --locked -- run_to_file:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- run_file_view::tests --test-threads=1
./scripts/test-go.sh
./scripts/test.sh --filter RunToFileContractTests --filter ResultExportTests --filter LoadedExportFixturesTests
./scripts/test-gpui-databases.sh
```

Run matching native Windows/Linux build runners and both disposable databases;
observe exact full counts, SQL effects and pre-existing files through Cancel,
disk failure, helper loss, locked files, light/dark native pickers and close races.
Static results and ignored build/gpui/task21-*.log are recorded in IMPLEMENTATION.md.

The recovery record retains the original helper client after the terminal when an open SQL session still belongs to it. A subsequent captured operation on that same session chooses that retained client rather than a replacement Workspace.backend. Task 22 now uses exact original physical-session ownership for transaction resolution and disconnect as well. A dedicated headless terminal case replaces Workspace.backend and checks retained helper identity.

Task 22 now retains a generation/session-bound SessionOwner for every physical
SQL session, beyond full-export recovery. Next Execute/COMMIT/ROLLBACK and each
close Disconnect use the original helper instance; identical textual IDs on a
replacement helper confer no ownership. Actual owned child exit is separate from
transport liveness. See CLOSE.md for acknowledgment and finalization semantics.

Phase 1 quality preparation adds a Windows helper test inspecting the protected
DACL before the first write, then publishing exact synthetic JSON/CSV without
weakening private creation. Windows ordinary/verbatim drive and UNC parent forms
normalize separately while preserving the chosen submission path; different
shares/drives remain distinct. Target-module metadata and Windows Go compilation
are type evidence only. Standard-user DACL/publication and controlled native UNC
chooser execution still require Windows acceptance.
