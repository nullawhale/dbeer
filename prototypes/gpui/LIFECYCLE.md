# GPUI connection lifecycle and explicit startup

Task 6 is code-ready; runtime tests and Windows/Ubuntu desktop acceptance are
**deferred to final integration**. The macOS product remains SwiftUI/AppKit.
See IMPLEMENTATION.md for the implementation/execution distinction. No frozen
parity baseline, artifact or native acceptance result is changed by this work.

## Profiles and decisions

The sidebar has selection, connection actions, a right-click context menu and a
keyboard-focusable actions button. Saved profiles support New SQL Tab,
Connect/Refresh, Disconnect, Edit and Delete. New and restored SQL documents
remain disconnected. Selecting another profile changes the default for new
documents and persists its saved ID; it never reassigns an existing SQL session.
Save and Save & Connect share persistence; only the latter requests a connection.

The form retains an immutable original profile separately from editable values.
Saving captures the candidate, optional replacement password, expected original
snapshot, stable profile ID, originating form and originating window. It emits a
request; the form itself cannot write the library or credentials. Canceling the
form does not disconnect or change selection/settings/credentials.

Workspace routes save/delete through the same captured close intent as profile
disconnect. A running operation offers Cancel or Stop and Continue; Cancel does
not send Stop. Stop waits for the actual terminal before continuing. Open/failed
transactions retain Commit/Roll Back/Cancel choices; unknown outcomes require
explicit acknowledgement and offer Cancel. Cancel returns to the unchanged form
when applicable. Catalog work must finish before a mutation can proceed. No
metadata or credential mutation starts until these decisions and physical
session disconnections finish. A disconnected transport never proves rollback.

The captured expected snapshot is checked before decisions, before teardown and
again under ProfileStore's owner-scoped mutation lock. No callback uses current
selection or an old vector index to identify the profile. Stale requests fail
closed. Metadata/credential errors preserve the store's original metadata and
rollback behavior from PERSISTENCE.md and leave the form retryable. Delete
removes profile documents/UI state only after the atomic store deletion succeeds.
Editing endpoint/TLS/policy (including password replacement) crosses a disconnect
boundary; Save leaves it disconnected and Save & Connect creates a fresh session.
The existing editor entities/source remain attached to their original documents.

Task 11 now owns the token/phase and acknowledged teardown contract in [CLOSE.md](CLOSE.md). Windows owned-HWND session-end review is implemented but uncompiled/unrun on Windows; the Ubuntu GNOME session-manager adapter remains a concrete Task 29 implementation gap.

This is the basic profile/session close graph. File/draft/grid/Apply/export
combinations remain with their later tasks and are not claimed here.

## TLS and CA selection

Choose... invokes the actual platform file chooser for one file, bound to the
original form/window. Cancellation preserves the previous path. Paths use the
platform's absolute-path rules and Unicode validation. Choosing a certificate
never changes TLS mode or trust policy. Manual paths remain supported; the Go
adapter owns certificate reading and TLS validation. Missing/unreadable CA,
untrusted chain and hostname errors remain failures; there is no retry with a
weaker mode or removed CA.

PostgreSQL modes: disable, allow, prefer, require, verify-ca, verify-full.
MySQL modes: disable, require, verify-ca, verify-full. Changing engine preserves
an applicable mode; an unsupported PostgreSQL-only mode becomes verify-full.

Prepared real-helper coverage is in tls_tests.rs. Final integration must supply
an owned private JSON array via the **path-only** DBEER_GPUI_TLS_MANIFEST setting
and set DBEER_REQUIRE_GPUI_TLS=1. Each case has engine, scenario, host, port,
database, user, passwordFile and nullable sslRootCert fields. Password files and
CA material are generated privately under ignored build/; no credential value
enters arguments, environment or diagnostics. Each case connects exactly once,
executes no SQL and disconnects an accepted session. Both engines require these
scenario IDs:

| Scenario | Mode | Expected |
| --- | --- | --- |
| disable | disable | Connect |
| require | require | Connect using the TLS-enabled server |
| trusted-ca | verify-ca | Connect |
| trusted-host | verify-full | Connect |
| ca-only-hostname-mismatch | verify-ca | Connect |
| hostname-mismatch | verify-full | Refuse |
| untrusted-ca | verify-ca | Refuse |
| untrusted-host | verify-full | Refuse |
| missing-ca | verify-full | Refuse |
| unreadable-ca | verify-full | Refuse |

PostgreSQL additionally requires allow and prefer cases on the owned TLS-enabled
server. Native observers must independently confirm negotiated TLS and engine
identity. Real adapters, system roots, file permissions, chooser cancellation,
missing/remapped paths and mismatch recovery require Windows 11 plus Ubuntu
Wayland/X11 execution; the prepared matrix is not passed evidence.

## Explicit --connect-stdin

Ordinary launch does not construct, lock or read stdin. Dedicated feasibility
modes retain their strict separate dispatch and disposable-store rules. Explicit
startup cannot be combined with demo/smoke modes. A normal process must acquire
its data-directory lock before opening the input channel, so a competing launch
refuses before reading any credentials or creating another workspace.

The explicit channel reads one JSON ConnectionSettings object to EOF with a
64 KiB cap and five-second deadline. It accepts the Swift field shape, defaults
to PostgreSQL/unspecified/readOnly=false, validates engine/port/TLS/policy and
refuses SQL/unknown fields. The reader owns and closes stdin on every path.
Unix uses bounded poll/read; Windows polls redirected pipes with PeekNamedPipe
and bounded reads, accepts redirected files and refuses console/missing handles.
There is no detached blocked reader to consume a later retry. Input/scratch
buffers and retained request secrets are overwritten on release. No payload or
raw parse/native-reader error is printed, saved to the library or sent through
arguments/environment.

After the component root exists, Workspace consumes the startup request once.
It saves settings/password using normal guarded persistence, preserving the ID
of an exactly matching saved profile, then requests one catalog connection.
Creating its SQL document never executes its sample text; startup sends no
query.execute or policy-approved user SQL. An invalid, empty, oversized, missing
or timed-out channel opens an editable form with a fixed generic error. A save
failure retains the valid submitted fields/password in that form for manual
retry. Retry uses form fields; it never rereads stdin or repeats an automatic
startup connect. A successfully saved profile remains editable/reconnectable
after helper/authentication/TLS failure.

Prepared cases include ordinary no-read, decode/default/empty-password behavior,
engine/TLS validation, fixed invalid/oversize/missing recovery, owned Unix pipe
EOF/timeout/oversize/descriptor cleanup and GPUI transaction/running/unknown/
delete/stale-request cancellation. These cases are compiled but **not executed**.
Final integration must additionally observe exactly one startup connect and no
SQL using the native helper, stalled Windows pipes, and successful/manual retry
on the target desktops. No secure-store roundtrip, Rust/Go/Swift test, database
operation, native UI test or acceptance run was executed for this task.
