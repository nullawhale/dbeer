# Portable fault test factories and physical cancellation barrier

This source integration is part of Task 30, not completion of its runner,
platform matrix or acceptance evidence. Runtime tests remain deferred until all
code through Task 32 is integrated. The frozen baseline and all 171 native
acceptance cells remain unchanged and not-run.

`src/preview/tests.rs` now uses the native Rust peer for its eleven existing
fault scenarios on every target. `src/run_to_file/tests.rs` does the same for
its two existing fault tests. The only remaining Unix gate in that file is its
Unix symlink API test. No Python, shell, cmd wrapper or production fixture
override participates in these factories. The older Python peer sources are
unused historical fixtures; they are not an alternate Windows path.

The preview cases retain separate fresh sessions, standalone approval refusal,
exact preparation/session/revision grants, sticky Stop before submission and
after preview, cleanup retry, one-shot Apply, authoritative late commit versus
whole-batch rollback, lost submitted terminal/COMMIT acknowledgment remaining
unknown, and known conflict without a retry. Export retains exact authorization,
one submission, progress beyond the display budget, late Stop, helper loss,
publication failure with known SQL completion, changed target refusal and
missing capability refusal before SQL. A synthetic lost acknowledgment proves
the client's unknown-state contract; it does not prove any real server commit.

## Wired final runner contract

The final native runner compiles the locked peer for the same native x64 host
and exports these controlled settings to default, native-smoke and DB stages:

| Setting | Exact requirement |
| --- | --- |
| `DBEER_GPUI_FAULT_HELPER_PATH` | Absolute regular native executable from `verification/fault-helper/Cargo.toml`, including `.exe` on Windows |
| `DBEER_GPUI_FAULT_HELPER_SHA256` | The same recorded 64 lowercase hexadecimal SHA256, rechecked before and after each stage |
| `DBEER_GPUI_TEST_ROOT` | Existing absolute current-user private `fixtures/` under the owned ignored run root |

The runner now exports its recorded peer hash. It validates the actual native
PE32+/ELF64 x64 bytes, file identity and private-root identity around selected
invocations. All eleven preview and two full-export assertions are listed by
exact qualified name and must run once in each root stage; absent, ignored or
zero-test/cfg-omitted cases fail. The conformance suites use `--self-checks` in
that same controlled environment. No inherited peer/path/hash is trusted.

The generic `gpui-prototype.sh test` entry point is unchanged. Direct runs that
select these fault suites must explicitly supply the same three verified values;
missing prerequisites fail rather than silently skipping Windows. Use the final
runner to prepare them at final integration. Neither path builds a peer lazily
inside a running test. Runtime execution remains deferred. See
[PARITY_RUNNER.md](PARITY_RUNNER.md) for the separate unmarked test build graph.

`src/main.rs` declares `#[cfg(test)] mod fault_test_support`. Test-only
`BackendClient::retire_owned_for_test` first fails pending requests with a fixed
transport error, then calls `await_owned_exit`. This is solely panic/failure
cleanup. Normal fixture cleanup first requests normal owned shutdown. Both
paths require actual retained-Child exit observation; neither `is_alive ==
false`, EOF, broken pipe nor a shutdown/cancel ACK is process-exit proof.

## Private files and cleanup

The factory reserves a fresh UUID child without changing the runner root's
permissions. Unix creation uses mode 0700, files use 0600 and the copied native
executable uses 0700. Windows uses `CreateDirectoryW` with a security descriptor
at creation: explicit current-token owner and protected inheritable one-user
full-access DACL. It verifies the current SID, actual owner and sole Allow ACE
using native token/security APIs, both for the supplied root and created paths.
`DataDirectory::acquire` is not used as Windows ACL evidence.

Each fixture verifies the source executable hash before copying and the copied
hash and source file identities afterward. Marker, flavor and mode are adjacent
exact bytes. Logs are precreated and contain command types only. The peer's
new ownership journal is checked against this marker, UUID and flavor; its PID
is descriptive and never used to find or stop a process.

After authoritative child exit, cleanup inventories only the exact captured
files. It compares parent/root and per-file native identities, immutable file
hashes, then captures and rechecks the final bounded log hashes before unlinking
each file. It never recursively removes a fixture tree. Missing required files,
unrelated entries, replacements, changed private permissions or unproven exit
refuse cleanup and preserve the remaining directory. Normal cleanup failure
fails the test; during an existing panic it emits a fixed diagnostic without
masking the original panic. No process name, PID discovery or foreign kill is
used. A fresh `disconnect-once` marker is retained for verified factory cleanup;
the peer remembers its one refusal rather than unlinking a pathname itself.

The native peer validates allowed modes, bounded identifiers and framing,
partial-frame refusal, log bounds and exact query/session stream ACK binding.
It releases a held terminal only for the matching cancellation. Export Stop
may overtake the stream ACK on the reserved lane: the peer ACKs that Stop and
retains the authoritative original terminal until its matching stream credit
arrives. Stale cancellation cannot release another query's terminal. Shutdown
has a real shutdown ACK followed by actual peer exit.

## Independent physical cancellation observation

`live_tests::verify_database` now opens an additional helper with a separate
read-only physical session using only the isolated test connection. It checks
that the observer differs from both SQL-tab physical IDs. Before Stop it polls
only the captured numeric target ID through `pg_stat_activity.wait_event` or
`information_schema.PROCESSLIST.STATE` and requires `PgSleep` or `User sleep`.
The ten-second bound is independent of the target's thirty-second sleep. A
five-millisecond timer paces unsuccessful polls; elapsed time is never proof of
execution. No app transaction or catalog service is borrowed as the observer.
Successful cleanup disconnects and observes the observer helper's exit; failed
assertions/connects/queries retire only that retained owned helper. Diagnostics
do not contain SQL, results, connection settings, passwords or DSNs.

## Verification status

Completed compile-only checks on the macOS development host with Rust 1.99.1:
scoped rustfmt and standalone peer all-target Cargo check/Clippy with warnings
denied. Root default/native-smoke all-target checks and Clippy are coordinated
with the shared production source owner; use its completed summaries, not this
document, for those final results. Logs for this subtask are ignored under
`build/gpui/task30-portable-peer-*.log`.

No Rust test executable, peer protocol probe, Python/Go/Swift suite, database,
GUI, credential, clipboard or installed app ran for this integration. Windows
DACL/executable cleanup and Linux desktop behavior need actual native runs;
macOS source checking is not evidence for them. The later Task 31 marked product
identity handshake must keep these explicitly unmarked test peers compatible
or prepare matching fake hello metadata without a production fixture backdoor.
The full Task 30 owner still owns runner/CI/environment/evidence wiring, final
runtime summaries, real server lost-commit observation and the complete matrix.


## Final joined fault layers

The current runner requires both exact db-live assertions
postgres_real_helper_death_awaits_original_exit_and_physical_session_loss and
mysql_real_helper_death_awaits_original_exit_and_physical_session_loss. The
original source executable is held open and bound to its private bin/native file
identity and DBEER_GPUI_TEST_HELPER_SHA256. The test waits for the independent
physical sleep barrier, retires only that original retained BackendClient child,
awaits actual exit and original physical-session disappearance, and requires the
independent observer to remain alive. Pending submitted work stays unknown and
no automatic reconnect occurs. These are prepared real-helper tests, unrun.

The same owned database pair also collects supported Go race/package summaries
and ten mandatory exact adapter ACK/type/readonly/cancel/deadlock assertions.
Task 32 separately prepares the opaque TLS SQL COMMIT and two-lease Apply
ACK-loss relay with independent physical effects and native UI/artifact evidence.
A fake peer, process exit, adapter ACK injection and installed physical ACK loss
exercise different boundaries; all remain required. No runtime layer was
substituted by source compilation or by another layer's passed flag.
