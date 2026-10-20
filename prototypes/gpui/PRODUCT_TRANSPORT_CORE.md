# GPUI paired helper transport integration

This bounded Task 31 integration connects the frozen identity codec to the real
Go helper and common Rust transport and validates optional metadata in the native
SwiftUI transport. Task 31 remains OPEN. GUI startup policy, native build and CI
flags, package execution and installed acceptance still require full integration.
The macOS product remains SwiftUI/AppKit with its existing signing/release route;
Mac GPUI remains a development host. No runtime test or probe has run here.

## Compiled authority and helper entry point

The native build writer must supply these exact Go linker targets:

- `-X main.productBuildIdentity=<canonical compact identity JSON without LF>`
- `-X main.productVersion=<exact trimmed root VERSION>`
- `-X main.productBuildNumber=<exact trimmed root BUILD_NUMBER>`

Use the ordinary Go linker argument quoting rules to preserve the complete JSON
as one `-X` value; do not apply shell evaluation to metadata. The identity must be
the existing `packaging/package.py` output with only its one terminal LF removed.
Do not base64 encode, compress, reorder or regenerate its fields. The packager
searches the executable for the exact plain canonical marker BEFORE it runs
`--build-info`. It separately verifies the bounded report and file checksums.
There is no environment override for these variables and no fixture release
value is hardcoded in production. Unmarked Mac/development builds leave them
empty and retain ordinary helper behavior.

`helper/cmd/dbeer-core/main.go` dispatches through `runCommand`. An exact lone
`--build-info` calls the frozen `productidentity.HelperJSON`, emits only bounded
helper BuildInfo JSON plus LF and exits. Missing/invalid metadata, mixed arguments
and unknown `--build-info...` variants fail with the fixed metadata diagnostic.
This happens before reading stdin, PostgreSQL environment preparation, framed
transport/session creation, language-server setup, databases or credentials.
Every ordinary marked startup also validates the identity before those paths.
Validation compares exact compiled version/build and actual runtime GOOS/GOARCH;
only Windows/Linux amd64 can be marked. The existing package/native GUI validation
still owns MSVC versus GNU and glibc proof; Go runtime labels alone cannot prove
those ABIs. A malformed nonempty marker never downgrades to an unmarked helper.

`runProduct` carries the once-validated immutable identity into
`runWithFactoryAndIdentity` and the actual hello response. Existing `run` and
`runWithFactory` retain unmarked development/test behavior. Protocol Response has
optional `BuildIdentity *productidentity.Identity`, emitted ONLY for hello.ack
and omitted completely when nil. The wire version remains 3 and the existing
`capturedExportV1` capability remains unchanged.

## Common pairing and original wire bytes

Rust `BuildIdentity::optional_embedded()` distinguishes absent compile-time
`DBEER_PRODUCT_BUILD_IDENTITY` from a present invalid value. The latter always
fails. `BackendClient::spawn` captures that validated compiled identity BEFORE
launching a helper; it never infers policy from a profile ID, active document or
later mutable state. Marked products require exact GUI/helper identity, including
version, build, source digest, target and semantic revision, wire protocol 3 and
the existing `capturedExportV1` before publishing ready. The same gate covers
connect, catalog, assessment, SQL, changes and exports. Product enqueue additionally
refuses all ordinary commands while not ready; only hello/shutdown may proceed.
Invalid pairing leaves the handshake waiter pending until the normal fatal
transport path settles it, so concurrent waiters cannot hang after removal.
Original session/process owners, actual-exit observation, streaming ACKs and
uncertain outcome handling are preserved.

`BuildIdentity::optional_from_frame` borrows the original nested JSON through
`serde_json::value::RawValue` (the existing serde_json dependency enables
`raw_value`). It calls the frozen strict 4096-byte `BuildIdentity::parse` before
generic Value decoding can normalize away the raw length or duplicate fields.
The existing `UniqueValue` still rejects every duplicate wire object key.
Only hello.ack permits buildIdentity, and absent/null remains compatible with
unmarked builds. Hello capabilities remain bounded, unique nonempty identifiers.
No new protocol version, fixture bypass or substitute export capability exists.

Swift BackendMessage carries optional `GPUIProductBuildIdentity`. The actual
`NDJSONFramer.decode` calls `optionalFromFrame` on the ORIGINAL frame bytes before
decoding BackendMessage. The existing raw preflight rejects duplicate/escaped
aliases, invalid UTF-8/structure/depth, raw nested oversize, unknown identity fields
and invalid identity values. It determines message type only after that preflight;
it never roundtrips a `[String: Any]` map. The validated raw identity is retained
in the reply. Ordinary absent/null Mac hello remains supported, and BackendClient
does not impose GPUI Windows/Linux product pairing on the native SwiftUI product.
Existing native full-export capability handling remains unchanged.

## Prepared verification and static evidence

The shared additive fixture index retains its 44 identity, 9 BuildInfo and 10
native-label cases and now contains 15 optional hello cases. New hello cases
cover invalid build/source/target/capability/semantic revision, original nested
oversize and escaped duplicate outer type. Go/Swift/Rust consume the same index;
Rust's previously undeclared `contract_fixtures` child is now declared.

Prepared Go entry-point cases use forbidden stdin and a synthetic PostgreSQL
environment marker to prove early build-info refusal/output before ordinary
setup. Actual hello output checks optional omission, strict identity serialization
and zero database factory calls. Swift tests exercise NDJSONFramer itself,
including absent/null, original duplicate/escaped keys and raw nested bounds.
Rust cases exercise the actual common Shared handshake and enqueue gate: no
connect frame before matching, build/version/source/target/capability/protocol
mismatches remain not ready, and a matching pair enables submission. The owned
test helper is retired using the existing actual-exit path; its test-only method
is available under `cfg(test)` for portable fault test consumers.

Compile-only checks and final runtime commands are distinct. Runtime execution
must wait until all remaining Task 32 code is integrated. Static completion
status and exact ignored logs are reported in the handoff; outputs live under
`build/gpui/task31-transport-*`. Required final commands include helper Go race
tests and native Swift suites through `./scripts/test.sh --all`, the GPUI default
and native-smoke test configurations with their owned native helper, plus the
existing exact target database, fault and installed acceptance workflows. Native
Windows/Linux acceptance is never inferred from host compilation or crossbuilds.

Completed bounded static evidence: Go `test -c` for `./cmd/dbeer-core`,
`./internal/protocol` and `./internal/productidentity` all returned exit 0;
ordinary host helper build and `GOOS=windows GOARCH=amd64` helper crossbuild also
returned exit 0. No produced executable was launched. Logs and binaries are in
`build/gpui/task31-transport-go/`. Full Swift `build --build-tests` returned exit
0 with `Build complete! (17.07 sec)` and compiled both the product identity and
pre-existing additive GPUI theme fixture consumers. Its log is
`build/gpui/task31-transport-swift/build.log`. The supported invocation requires
`--disable-sandbox`, explicit ignored scratch/cache/module paths,
`-debug-info-format none` and `-Xswiftc -load-plugin-library -Xswiftc` followed by
the active toolchain's `host/plugins/testing/libTestingMacros.dylib`, as in the
repository's native test runner. Initial compile attempts identified those
environment-only flags; the final build succeeded. Existing user-cache,
SecKeychain/accessibility deprecation and linker search-path warnings remain.
Tracked owned diff checks, scoped formatting and English/trailing-whitespace
scans completed cleanly. The shared Rust writer owns the final coherent root
check/Clippy/fmt record; no runtime or native acceptance follows from it.

## Remaining full Task 31 and Task 32 obligations

1. Dispatch exact GUI `--build-info` before GPUI/platform/feasibility, data owner,
   restore, helper launch, credentials or database work. Refuse missing, unknown
   or mixed metadata options without GUI fallback. Use BuildInfo::gui_json;
   preserve its debug/native-smoke refusal and the exact canonical embedded marker.
2. Apply actual product StartupPolicy, title, application/desktop ID, native icon
   and supported platform rules. Refuse unmarked/unsupported Windows/Linux
   product launch. Preserve explicit disposable Mac demo/smoke routes. Remove
   built-in product profiles/sample SQL/fallbacks, support an actual unbound empty
   document with zero profiles, and keep every restored document disconnected.
3. Retain the existing profile UUIDs, credential service/accounts and canonical
   compatible library directory. Acquire the same DataDirectory owner/lock before
   load/mutation and retain it in every store; validate simultaneous old/new owner
   refusal without copying credentials, changing namespaces or deleting locks.
4. Generate existing packager metadata after all source edits/freeze, before BOTH
   native builds. Supply the same exact root VERSION/BUILD_NUMBER and identity to
   Rust and all three Go link targets above. Never rebuild an unmarked helper
   afterward. Wire supported native scripts and CI to those paired builds and the
   existing package wrappers, retaining full notices and root release metadata.
   Preserve the separate Mac Swift build/sign/release route and owner identity.
5. Resolve the native manifest/resource collision and embed the actual Windows PE
   product icon/version/resource and Linux desktop/icon/app ID, rather than merely
   shipping image files. Refuse target overrides, cross-built product candidates,
   ARM, Linux musl, Windows GNU and Mac product targets. Keep unsigned development
   artifacts distinct from target-native accepted candidates.
6. Execute native build-info and package checks on Windows 11 x64 and Ubuntu 24.04
   x64 with the existing import/glibc/dependency/GPU/Secret Service requirements.
   Prepare fresh no-overwrite local portable ZIP/tarball artifacts, checksum,
   manifest, full licenses/notices, installation/update/remove documentation,
   changelog and Windows signing/Linux provenance policy. Do not publish, change
   trust/signing or overwrite release archives. Retain manual complete-folder
   update/rollback; no updater/MSI/MSIX/AppImage is implied.
7. After remaining Task 32 source, execute the prepared shared runtime suites and
   exact native UI/accessibility/session-end/fault/DB/credential/clipboard matrices
   on owned Windows and Ubuntu Wayland/X11 desktops. Run clean install, standard
   user launch/remove, complete-folder update/rollback, data retention and old/new
   ownership acceptance. Report completed summaries and all explicit skips. Task
   2, Task 31/32 and all 171 frozen native cells remain open until real evidence.
