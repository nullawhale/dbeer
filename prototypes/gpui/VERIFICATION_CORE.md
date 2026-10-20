# GPUI final verification core

Task 30 preparation is additive and self-contained. **Runtime tests remain
unrun until all Task 32 code is ready.** Task 30's Run checkboxes remain open.
Compilation, static manifest validation and runner preparation are not acceptance.
The frozen F01–F57 registry, reference artifacts and all **171 not-run desktop
cells are unchanged**. The macOS product remains SwiftUI/AppKit; GPUI on Mac is
a development check only. Supported GPUI desktops remain Windows 11 x64 and
Ubuntu 24.04 x64 with separate Wayland and X11 sessions.

## Files and contract

- `verification/matrix.json` lists exact default/native-smoke, transport,
  persistence, dependency-unit and private GNOME bus stages. It retains the
  existing Go race, PostgreSQL 16/17/18, MySQL 8.0/8.4, TLS and SwiftUI CI jobs.
- `fixtures/parity-matrix/cases.json` maps 25 behavior groups to actual prepared
  Rust/Go assertion symbols and existing Swift behavior suites. It covers exact
  NULL/empty/literal NULL/DEFAULT/numeric/binary values, Unicode/CRLF, duplicate
  names, multi-set routines, first/middle script errors, independent sessions,
  composite/generated/no-PK/views/non-InnoDB, read-only policy, stale callbacks,
  cancellation/grants/late ACK, helper loss, atomic Apply, lost COMMIT ACK,
  blocked publication, credential rollback and corrupt/future persistence.
  These are behavior mappings; AppKit implementation code was not translated.
- `fixtures/parity-matrix/fault-plan.json` gives the allowed disposable-peer
  modes and explicitly separates simulated faults from physical DB/native faults.
- `verification/run.py` collects exact native test artifact hashes, helper and
  portable-peer hashes, source digests, commands, retained child PIDs, host/arch,
  times, exits, nonempty completed summaries, assertion IDs and explicit skips.
  `verification/proof.schema.json` describes its completed ledger.
- `scripts/test-gpui-parity.sh` and `.ps1` are thin native entry points. Python
  3.10+ is required. Neither changes the existing build/test runners.
- `verification/owned_databases.py` owns local-image-only DB/TLS fixtures and
  journals exact Docker IDs, image IDs/architectures, reserved names, nonces,
  labels, bound loopback ports, fixture setup and cleanup state.
  Anonymous image-created volume IDs are recorded and removed only with their
  exact owned container; no volume or container pruning is used.
- `verification/test_runner.py` contains prepared safety cases for missing/empty
  summaries, failed exits, ignored tests, output suppression/bounds, duplicate
  JSON, inherited DB settings, cross-build refusal and foreign-owner cleanup.
  These cases have been syntax-compiled only, not executed.
- `verification/test_fault_peer.py` prepares native peer conformance checks for
  mandatory ownership markers, exact held terminal ordering, lost Apply ACK,
  full-count export and oversized-frame refusal; execution remains deferred.

## Execution boundary

The execution CLI requires `--final-integration`. Supply it only after the
remaining Task 32 implementation is ready. It is an explicit execution gate,
not a way to waive missing native environments or required assertions.

Static validation is safe during implementation and starts no application,
helper, database, credential service or test:

```sh
./scripts/test-gpui-parity.sh --validate
```

At final integration on actual native Windows/Linux x64 hosts:

```sh
# Ubuntu 24.04 native host; Windows uses the matching .ps1 entry point.
./scripts/test-gpui-parity.sh --final-integration --all-headless --self-checks
# Focused replay is available without rerunning unrelated stages.
./scripts/test-gpui-parity.sh --final-integration --stage transport-faults
./scripts/test-gpui-parity.sh --final-integration --stage persistence-faults
./scripts/test-gpui-parity.sh --final-integration --self-checks
```

`--all-headless` runs default and native-smoke test binaries plus the separate
vendor targets and Linux's explicitly ignored owned-private-bus case. The
focused transport/persistence selectors are already covered by default and are
not repeated in that full run. Root `--all-targets` does **not** compile or run
dependency unit tests; the collector compiles each dependency's actual test
executable separately and then runs its selected assertion filter.

Equivalent direct dependency commands, with the same native Rust toolchain,
Cargo cache and ignored target directory as the supported runners:

```sh
cargo test --locked --manifest-path prototypes/gpui/vendor/gpui-base/Cargo.toml --lib -- dbeer_explicit_alpha --test-threads=1
cargo test --locked --manifest-path prototypes/gpui/vendor/gpui-component/Cargo.toml --features tree-sitter,tree-sitter-sql --config "patch.crates-io.gpui-base.path = '$PWD/prototypes/gpui/vendor/gpui-base'" --lib -- input::accessibility::tests --test-threads=1
cargo test --locked --manifest-path prototypes/gpui/vendor/gpui-component/Cargo.toml --features tree-sitter,tree-sitter-sql --config "patch.crates-io.gpui-base.path = '$PWD/prototypes/gpui/vendor/gpui-base'" --lib -- dbeer_ --test-threads=1
./scripts/gpui-prototype.sh test --locked -- session_end::gnome::protocol_tests --ignored --test-threads=1
```

A zero-test filter, missing completion summary, failed exit, timeout or missing
required critical assertion fails proof collection. Default/native-smoke stages
require the key preview/export/close assertions by name, so a Windows `cfg`
omission cannot silently be accepted. Ignored test names and conditional DB/TLS
returns remain explicit in the ledger. A passing headless summary does not cover
real desktop secure stores, rendering, external clipboard formats, IME, native
accessibility, file pickers, mixed-DPI behavior or installed upgrade acceptance.
Container runs are refused as native-host execution evidence.

## Real DB and TLS matrix

Images must be present locally. The runner never downloads implicitly and never
accepts an inherited DSN, password, profile or arbitrary image argument. It
clears `DBEER_*` settings before creating its own environment. Native Windows
requires a reachable local Linux Docker engine plus OpenSSL; absence remains a
not-run prerequisite, not Linux coverage of Windows behavior.

```sh
./scripts/test-gpui-parity.sh --final-integration --database-pair 16 8.0
./scripts/test-gpui-parity.sh --final-integration --database-pair 17 8.4
./scripts/test-gpui-parity.sh --final-integration --database-pair 18 8.4
```

Each pair uses fresh separate servers with temporary CA/server certificates,
random credentials, no production settings, a reserved disposable marker and
nonce-labeled exact Docker IDs. Before starting a server, its ID is journaled.
The frozen SQL corpus is installed only inside those disposable servers; it
refuses replacement of an existing namespace. MySQL setup grants the existing
disposable `dbeer` user only SELECT/INSERT/UPDATE/DELETE/EXECUTE/SHOW VIEW on
`dbeer_parity_v1.*` so independent installed observers and GUI cases can access
that synthetic corpus; it adds no global privileges. Existing actual Rust cases then
exercise both engine families: live sessions and policy/scripts/routines,
independent observer Apply atomicity, exact-once full export/counts, GPUI
workspace transaction/cancellation routing and the complete helper TLS manifest.
Readiness polls a physical server condition; cancellation tests must observe the
actual operation through their independent observer, never infer state from a
fixed delay.

TLS covers disable/require/verify-ca/verify-full, trusted chain/hostname,
CA-only hostname mismatch, rejected hostname mismatch, untrusted chain, missing
CA and a nonregular unreadable CA. PostgreSQL additionally covers allow/prefer.
The unreadable-CA automated fixture is a directory that cannot be read as
certificate bytes; a real permission-denied regular file remains a separate
native desktop requirement. Trusted setup does not establish native picker/CA
remapping or real desktop permission behavior.

Shared helper coverage remains in the existing supported commands and unchanged
`ci.yml`, including the real PostgreSQL TLS suite's separate `dbeer_tls` fixture:

```sh
./scripts/test-go.sh
./scripts/test-tls.sh
./scripts/test-mysql.sh
./scripts/test-postgres.sh ./scripts/test-mysql.sh ./scripts/test.sh --all --require-postgres
```

Run the versioned Go/TLS commands for every server version as already configured
by existing CI. The supplemental workflow adds GPUI DB observers; it does not
replace or duplicate the shared Go version matrix. It also does not replace the
existing macOS SwiftUI/AppKit native UI/Keychain CI job or its supported signing
and temporary test-Keychain workflow.

## Portable fault peer and required integration

`verification/fault-helper` is a separate, locked Rust executable fixture with
only `serde_json`. It never connects to a database or accesses credentials or
profiles. It logs command types only and emits only the deliberate framed v3
peer responses. Invalid/oversized commands fail with a fixed diagnostic. Its
16 MiB frame limit and 64 KiB command-type log bound are independent of the
product's transport limits.

Native fixture build, at final integration (compilation alone is also allowed
beforehand):

```sh
CARGO_TARGET_DIR="$PWD/build/gpui/task30-fault-target" cargo build --locked --manifest-path prototypes/gpui/verification/fault-helper/Cargo.toml
```

The collector builds it offline for the actual native x64 host, validates the
completed Cargo build and executable header, then exports the exact path and
SHA256 plus its absolute private `DBEER_GPUI_TEST_ROOT`. All root/default,
native-smoke and owned-database stages inherit the same controlled values. The
thirteen exact qualified assertion names in `fault-plan.json` are required once
in each root stage. Missing peer/hash/root, empty filter, duplicate assertions,
ignored critical assertions or any `cfg` omission fails the selected stage.

The eleven preview and two run-to-file factories are now portable. Each copies
the verified native executable into its own private UUID child, retains original
helper/session/grant ownership and observes actual child exit before exact-file
cleanup. Only actual Unix symlink cases retain Unix gates. Native Windows
current-user DACL creation/verification, file identity/hash and immutable-file
checks are in the real factory; Unix mode alone is not ACL proof. See
[FAULT_TEST_INTEGRATION_CORE.md](FAULT_TEST_INTEGRATION_CORE.md) for the frozen
source contract. The physical live cancellation test polls the independent
observer for the actual captured server sleep condition before Stop; elapsed
time is not execution evidence. These source changes have not been run.

## Evidence, privacy and cleanup

Runs reserve a new private directory under
`build/gpui/task30-runs/<32-hex-nonce>/`. POSIX directories use mode 0700 and files
0600; Windows sets an explicit current-token owner and protected inheritable one-user DACL at directory creation, then checks the actual owner and DACL with the native launcher's checker. Newly created files inherit that DACL and are checked before publication.
Inherited production DB settings are removed. No credentials, SQL, results,
connection strings, arbitrary exception text, compiler source snippets or raw
child diagnostics enter proof records. Summaries, assertion names, fixed errors,
hashes, timing, paths and exact owned process/container identities are retained.
The optional shared Go proof invokes the supported runner with `GOFLAGS=-json`
and retains package completion plus skipped root test symbols, never arbitrary
subtest labels or Go event Output. Swift skip events retain a safe method symbol
or an explicitly redacted label; diagnostic reasons may contain private values
and are not copied into evidence.

`request.json` and `completed.json` publish atomically without replacement;
separate cargo `*-build.json` records retain completed-build status and exact native test executables. Exactly one successful Cargo terminal, native executable identity and nonempty Rust assertion rows matching the completed summary are required. Go JSON must complete every actual source package with tests, with root assertion events; Swift's supported full runner must complete both those Go packages and its nonempty Swift Testing run. A ledger's `passed` refers only to its declared layer;
`nativeAcceptance.status` always remains `not-run`. Source hashes before/after
must match. A test binary's SHA256 and native helper SHA256 bind executable bytes
rather than filenames/version labels. Installed product build identities are a
separate Task 31/32 requirement.

Cleanup uses retained `Popen` handles only. It never enumerates or kills foreign
processes, process groups or descendants by name. DB cleanup checks the recorded
exact Docker ID's nonce label; an interrupted create may recover only its
pre-reserved exact name with the same nonce label. It never prunes Docker or
removes an unowned container. Generated private keys/password files are erased
from the exact owned fixture directories only after their recorded device/inode,
size, modification time and SHA256 match. A same-byte foreign inode, changed
file, symlink or changed directory is preserved and makes cleanup incomplete.
No foreign inode is read as a credential merely to compare its hash.
Incomplete cleanup fails the run and
retains a sanitized journal for bounded explicit recovery. After a hard process
or host loss, inspect only that reserved name/ID and exact nonce label before
removing it; never apply a broad process/container cleanup command.

Upload only `request.json`, `completed.json`, `*-build.json` and
`database-fixtures/journal-*.json`. Never upload private config/data/temp trees,
TLS private keys/password files, SQL drafts or export results. The manual-only
`gpui-parity.yml` workflow follows this allow-list and requires the explicit
all-Task-32-code-ready input. It does not create automatic self-hosted desktop
jobs or wait on nonexistent stand labels. Windows Server CI is native headless
Windows evidence, not Windows 11 GUI evidence; Ubuntu hosted headless CI is not
Wayland/X11 desktop evidence.

Task 31 package identity is `{component,identity}` from the bounded `--build-info`
hook. Identity schema 1 contains product `app.dbeer.DBeer`, shared version and
string build number, target `windows-x86_64-msvc` or `linux-x86_64-gnu`, protocol 3,
contract `gpui-v3-captured-export-v1`, source SHA256 and `capturedExportV1`.
Package/installed collectors must first verify canonical identity bytes embedded
in each candidate, as described in `PACKAGING_CORE.md`; never probe an old unknown
GUI binary with an unsupported flag that could open personal state. Task 32's
separate `acceptance/` harness owns native windows/UIA/AT-SPI and installed
prior/candidate evidence. Neither collector mutates frozen baseline acceptance.

## Compile environment and current preparation results

On 2026-10-19 the available host was Darwin arm64. Python 3 was available;
PowerShell and a globally available Cargo were absent. The repository's pinned
local Rust 1.99.1 toolchain was used. Docker nonsecret inventory was explicitly
authorized: daemon Linux arm64, existing `dbeer-gpui-check:local` ARM64 image and
local PostgreSQL 16/17/18 and MySQL 8.0/8.4 images. Those are not native x64
Windows/Linux desktop environments.

Completed implementation-time checks only: matrix JSON and actual Rust/Go
symbols/Swift suite references validate; Python files syntax-compile; Bash entry
point and supplemental workflow YAML parse; portable fixture `cargo check --locked --offline` and all-target
Clippy with warnings denied complete. Rust formatting completes. No runner
self-test, product Rust/Go/Swift/database/UI/credential/clipboard/protocol test,
installed acceptance or workflow dispatch ran. PowerShell parser validation is
pending a host with PowerShell.

`verification/Dockerfile.ubuntu24` prepares a compile-only Ubuntu 24.04 amd64
environment with Rust 1.99.1, Go 1.27.1 from `helper/go.mod` and the actual GPUI
libraries already used by CI. `.dockerignore` allows only this Dockerfile into
the image context: no checkout, `.git`, ignored `build/` or local settings.
The owned image build completed with exit 0 and tag
`dbeer-task30-ubuntu24-x64:0282e61aa8114cdda118b5dbab00e2ac`, nonce label
`app.dbeer.task30-run=0282e61aa8114cdda118b5dbab00e2ac` and `--platform linux/amd64`.
Its private request/log live under
`build/gpui/task30-build-0282e61aa8114cdda118b5dbab00e2ac/`.
The image ID is
`sha256:8a3bf109710797f6b79ffd396e0c100a90ca4c07ca8195fbf13959da960d29df`.
A separate exact-CID, network-disabled, automatically removed metadata container
confirmed `rustc 1.99.1` host `x86_64-unknown-linux-gnu`, `cargo 1.99.1`,
`go1.27.1 linux/amd64` and all requested GPUI pkg-config libraries (exit 0).
This metadata check ran no application, helper protocol or tests.
This is x64 emulation on an ARM64 daemon. Image preparation and any later Linux
`cargo check` are compile evidence only. Source compilation waits for the shared
writer's freeze; no Rust test binary or GUI is run during image preparation.

The former live-helper 150 ms cancellation assumption has been replaced by an
independent original physical-session barrier using
`pg_stat_activity`/`information_schema.PROCESSLIST`. The current live-helper and
Workspace cases require actual server sleep observation before Stop; elapsed
time is not execution proof. Separate new real-helper-death assertions await
original owned child exit, physical target-session loss and the still-live
independent observer without reconnect. The source contract is in
FAULT_TEST_INTEGRATION_CORE.md; all runtime cases remain unexecuted.

`verification/platform-harness` separately wires the actual frozen
`gpui-base`, `gpui-component` and `gpui-pre-linux` crates. Its lock retains the
root application's exact dependency versions (only the harness package is
additional). `verification/prepare_platform.py` stages those four explicit
source trees and only the public crates.io cache/index into a fresh ignored
directory; Cargo credentials, private registry directories, checkout metadata,
app settings and moving application sources are excluded. The initial offline
metadata step required an uncached `accesskit_atspi_common` source; the pinned
container compile may fetch that public package without host credentials.

The isolated check started in owned container
`dbeer-task30-platform-f7f2d338b35e4cad90b454d5f38a6b6f`, with nonce label
`app.dbeer.task30-run=f7f2d338b35e4cad90b454d5f38a6b6f`, two Cargo jobs, two CPU
quota and an 8 GiB memory bound. The exact CID, request, allow-listed source
manifest and compiler output are under
`build/gpui/task30-platform-f7f2d338b35e4cad90b454d5f38a6b6f/`.
Its command was `cargo check --locked --all-targets --manifest-path
/work/source/prototypes/gpui/verification/platform-harness/Cargo.toml`.
The source snapshot SHA256 is
`4dc815e7e860d84aafbedd667e0c1fc27f58c5f46b82c3293c277bb94f6b833a`.
This checks actual Linux dependency branches, including Wayland/X11 paths;
it does not compile the moving app, execute dependency tests or establish a
native Ubuntu graphical result. Dependency-unit targets still require their
own separate compile/run commands described above.

That dependency harness completed successfully (exit 0, 8m 50s); its staged
source and the original frozen vendor/harness hashes both remained unchanged.
The owned container exited with automatic removal. `completed.json` records the
exact CID, image, source hash, emulation and scope. No tests ran.

A separate compile-only dependency-unit check was then started under
`build/gpui/task30-platform-units-daf34924af2d4f6d80318aa4099be129/`, owned container
`dbeer-task30-platform-units-daf34924af2d4f6d80318aa4099be129`. It typechecks
`--all-targets` for the actual base/component/pre-linux manifests with all three
local path patches; component enables tree-sitter and tree-sitter-sql. Only owned
staged Cargo locks may resolve added standalone dev-dependencies from root pins;
original vendor files and lock files are untouched. It reuses the isolated public
cache, two jobs and x64 emulation. Per-crate logs/stages retain actual compiler
outcomes. Test binary execution remains deferred to final integration.

The first unit attempt stopped at `gpui-base` lib-test compilation (exit 101,
442 seconds): `src/text/text_view.rs:1483` includes the public parent
`prototypes/gpui/README.md`, which the isolated snapshot omitted. The original
vendor include path is valid in the complete checkout; no vendor code was
changed. The complete diagnostic and failed proof remain in that first run.
Component/pre-linux unit checks were not reached in the first attempt.

The authorized fresh retry adds only that exact public README and reuses the
isolated compile cache. It is **pending**, not a passing unit check:

- Run: `build/gpui/task30-platform-units-76a091159617488a984a29a47ea00d85/`.
- Owned container: `dbeer-task30-platform-units-76a091159617488a984a29a47ea00d85`.
- Exact CID: `656dca9fc9d77aa65ba8a3089fa097251301398a039df48cf58d3603b5493a11`.
- Nonce label: `app.dbeer.task30-run=76a091159617488a984a29a47ea00d85`.
- Original compiler tool session: `68216`; proof-watcher tool session: `15487`.
- Each actual Cargo check has a 600-second limit; the independent watcher has a
  1200-second deadline and stops only this recorded CID after checking its nonce.
  Docker `--rm` removes only that owned container. No image/volume pruning occurs.

`verification/watch_compile.py` runs independently after the preparing agent's
handoff. It atomically publishes `completed.json` with actual per-crate commands,
exit codes/times, staged-code and original-source comparisons, resolved lock
hashes/root-version drift, exact container cleanup and `testsExecuted=false`.
It never invokes a test binary. Missing stage proof, root-version drift, changed
staged code, unknown cleanup, a failed stage or deadline fails the compile proof.
`stages.json`, per-crate `gpui-base.log`/`gpui-component.log`/`gpui-pre-linux.log`,
`container.log` and `watcher-request.json` remain under that exact run directory.
The parent may mechanically poll the watcher session or completion file and
forward the full terminal diagnostic to the sole writer; source debugging and
vendor edits require the appropriate worker. Later proof-only documentation may
record the actual outcome. The preparing source freeze does not promote this
pending retry, any compile result or the dependency-harness pass to acceptance.

## Current runner integration source freeze

The 2026-10-20 runner/CI/evidence integration is prepared, not executed. See
[PARITY_RUNNER.md](PARITY_RUNNER.md) for exact environment, output, assertion,
standalone-lock and Task 31/32 contracts. Historical emulated Linux compile
attempts above are retained descriptions, not current integrated evidence;
[LINUX_UNIT_PROOF.md](LINUX_UNIT_PROOF.md) records their actual separate outcomes
and component development-graph differences. No historical proof was modified.
All Task 30 Run checkboxes, Task 2 and 171 desktop cells remain open.


## Final current source join

The final runner now preserves the original 25 behavior groups and adds 22,
with explicit required execution bindings, all 57 feature mappings and immutable
57-feature/190-assertion/171-cell baseline pins. Source-symbol presence alone
cannot mark a behavior covered: completed per-stage actual unique test rows are
joined at runtime. Native and F57 acceptance always stay false here.

The current matrix has seven owned Rust database stages plus a separate supported
shared Go race stage in the same original fixture lifetime. The two additional
Rust stages exercise actual catalog-service isolation and connected signature
metadata. Real helper death, private peer orchestration, adapter ACK injection
and installed opaque physical ACK-loss are explicitly distinct requirements.
The producer captures original public CA/server/extension/untrusted certificate
identities under a local private OpenSSL subprocess umask; existing private keys,
passwords, fixed SQL APIs, grants and exact cleanup remain unchanged.

Task 28/29 original controls, latest save, native source/selection guards, same-live
and reopened dialog ownership, GNOME terminal readiness/private bus and the
separate actual Windows 11 owned-HWND stage are mandatory. Actual native author
IDs/input/accessibility remain Task 32 observation, not a source-property claim.

`dependency-inputs.json` reviews all four maintained path patches and 698 actual
source/provenance/input files. Current root/base/component/pre-linux package
counts are 850/807/709/628. Exact additions, omissions, the component's fifteen
standalone dev-only alternate versions and unchanged root-known source/checksum
identities are recorded. Runtime refuses any unreviewed source/lock/patch drift.
See PARITY_RUNNER.md and LINUX_UNIT_PROOF.md for exact separate graph scope.

No runtime Rust/Go/Swift/Python/database/helper/app/clipboard/store/native test
was executed for this final source join. The final static summary and source
freeze manifest are under ignored build/gpui/task30-final-*.json. Historical
compile evidence above remains separate; current native and installed gates
remain open.
