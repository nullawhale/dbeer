# Native feasibility probes (Task 2)

Targets: owned **Windows 11 x64** and **Ubuntu 24.04 x64**, with separate
Wayland and X11 logins. macOS DBeer stays SwiftUI/AppKit. At preparation time
(2026-10-19), the user has no target graphical environments: **every native
acceptance gate remains not-run**. No headless build or Mac development check
can accept those gates.

The dedicated, explicitly enabled probe dispatches **before Workspace creation**.
It never loads saved profiles or starts a database/helper session. It reuses the
existing EditorState and ResultGrid/DataTable, displays 1,000 synthetic rows,
invokes real GPUI open/save choosers, checks a clipboard marker and captures
structural scene/visible-range facts. Separate bounded children exercise the
actual Windows/Linux credential adapter in an isolated service namespace.
Ordinary application builds refuse all `--feasibility-*` flags clearly.

## Prepare and build on each desktop

Use an owned standard-user desktop/account with a real GPU or VM GPU/driver that
can display GPUI. Record OS/build, GPU/driver/renderer, physical/VM/remote session,
monitor scale, keyboard layout/IME and reader/inspector versions. A remote run's
results apply only to that configuration. Windows needs an unlocked interactive
desktop. Ubuntu needs a local Wayland or X11 login, user session D-Bus, GPU
runtime and an installed/unlocked Secret Service. Log out and choose the other
Ubuntu session to repeat the run. The driver does not provision OSes, download
images, elevate, alter system trust/input settings or stop another app/reader.

Follow [the prototype prerequisites](../README.md). The existing package scripts
build the helper and normal development client. Build the **test-only feature**
explicitly afterwards; use its exact executable for `operator` and `smoke`:

```sh
# Ubuntu 24.04 x64, repository root
./scripts/build-gpui-client.sh --test
./scripts/gpui-prototype.sh build --locked --features native-smoke
# Probe: build/gpui/target/debug/dbeer-gpui
# Helper: build/gpui/dbeer-core
```

```powershell
# Windows 11 x64, native PowerShell/toolchain, repository root
./scripts/build-gpui-client.ps1 -Test
$env:CARGO_HOME = "$PWD/build/gpui/cargo"
$env:CARGO_TARGET_DIR = "$PWD/build/gpui/target"
cargo build --locked --manifest-path prototypes/gpui/Cargo.toml --features native-smoke
# Probe: build/gpui/target/debug/dbeer-gpui.exe
# Helper: build/gpui/dbeer-core.exe
```

These remain unsigned experimental builds, not published releases. Python 3.9+
x64 is a launcher prerequisite, not a product runtime dependency. Retain the
exact source/revision and working patch used for the executable. The launcher
records source, Cargo.lock, launcher, app and helper hashes; a revision alone
does not identify uncommitted source.

## Run the exact disposable probe

Substitute exact **absolute** paths on the target host:

```sh
python3 prototypes/gpui/native/run.py preflight --desktop wayland \
  --executable /absolute/path/dbeer-gpui --helper /absolute/path/dbeer-core
python3 prototypes/gpui/native/run.py operator --desktop wayland \
  --executable /absolute/path/dbeer-gpui --helper /absolute/path/dbeer-core --timeout 900
```

Repeat with `--desktop x11` in the actual X11 login. Windows:

```powershell
python prototypes/gpui/native/run.py operator --desktop windows `
  --executable C:\absolute\path\dbeer-gpui.exe --helper C:\absolute\path\dbeer-core.exe --timeout 900
```

`preflight` performs no launch or store access. It refuses wrong OS/architecture,
root/elevated users and absent graphical sessions. Windows 11 Client build
22000–29999 is the explicitly accepted build family; unknown future OS families
need an explicit update. Native Windows architecture is checked to exclude x64
emulation on ARM64. Socket/environment presence proves no rendering, keyring
operation or accessibility behavior.

`operator` creates an owned run under ignored `build/gpui-parity/native-runs/`.
Unix directories/files are private; Windows gets a protected owner-only run ACL,
which is verified before the request reaches a child. Regular-file/owner/mode
checks reject special files, symlinks/reparse points and foreign/public requests.
The strict bounded request binds one root, token and reserved account. Windows
children also require the launcher's matching root/token environment. A local
filesystem supporting atomic hard links is required for request/journal/grant
publication; a failure refuses the operation before native store mutation.

The driver sets only the child's profile/data/cache/temp roots, preserving HOME,
its desktop bus and native backend selection. Inherited `DBEER_*` overrides are
removed. There is no attach, app-name lookup or arbitrary argument option. Each
launched child must match the supplied executable/PID before it can proceed.
Use the printed GUI PID and `target.json` in inspectors. Do not select an app by
title alone. Portal dialogs can be separate processes: observe their association
manually; never attach to or terminate a portal/compositor through this driver.

The probe window provides:

- **Open fixture**: choose this run's `fixtures/feasibility.sql`, Cancel, or
  deliberately choose another synthetic path. Only path identity is classified;
  no selected file content is read. The GPUI open API has no initial-directory
  parameter, so navigate to the printed run directory.
- **Save chooser only**: select `fixtures/feasibility-save.sql` or Cancel. No
  destination is created or written, even after selection/overwrite confirmation.
  Chooser receivers have a 30-second bound; `error-or-timeout` proves neither
  dismissal nor success. Close a remaining native chooser manually.
- **Clipboard marker**: preserve the readable prior ClipboardItem only in memory,
  write/read a synthetic marker, and request restoration while that marker is
  still ours. A concurrent change is preserved. With no readable original the
  probe performs no write. No previous clipboard content/value is logged. Check
  the resulting restore booleans; a crash cannot recover the private old item.
  Toolkit caching can satisfy self-roundtrip, so external paste remains required.
- **Capture facts**: record only row/column counts and visible ranges, painted
  quad count, optional scene-readback dimensions and capture duration. Unsupported
  readback is recorded honestly. No editor text/grid values are recorded.
- **Last row**, **Theme**, actual Editor/DataTable input and **Finish** permit
  manual inspection. Last row is an internal scroll request, not OS keyboard
  proof. Finish/titlebar close writes a nonempty completed UI summary; captured
  facts are neither responsiveness measurements nor accessibility acceptance.

The event stream is bounded to 256 metadata records. The driver validates exact
record schemas, PID, fixed outcome labels and bounds, retains hashes and never
converts a probe outcome to a native pass. `observations.json` starts with every
gate not-run. `summary.json` separates completed driver execution, probe failures,
cleanup requirements and native acceptance. Missing completion, invalid reports,
timeouts and cleanup failures return failure. Ctrl+C cancels; the UI limit is
10–3600 seconds, credential workers 15 seconds each, with bounded child-only
termination then kill waits. No process groups, helpers or unrelated instances
are terminated. Retain artifacts until cleanup/recovery and observations are
reviewed.

The optional existing internal scene smoke remains separate:

```sh
python3 prototypes/gpui/native/run.py smoke --desktop wayland \
  --executable /absolute/path/dbeer-gpui --helper /absolute/path/dbeer-core --timeout 120
```

It exercises the existing Demo workspace with internal dispatch and screenshot
checks. Pinned GPUI's platform trait defaults `render_to_image` to unsupported;
target overrides have not been observed. A failure needs investigation and
operator screenshots; neither its pass nor a failure accepts native behavior.

## Native credential ownership and recovery

`operator` first launches a separate exact-executable credential probe. It uses
the same explicit production WinCredential/SsCredential adapter, error masking
and serialization, under **`dev.dbeer.gpui-prototype.feasibility-v1`**, with a new
random `dbeer-feasibility-<32-hex-token>` account. Production profiles and their
credential service are untouched. Mac credential modes always refuse, including
Mac development builds. Values never enter argv, environment, JSON or logs;
credential child stdout/stderr are discarded.

The launcher durably records artifact/account/context and each verified worker
PID **before** atomically publishing its identity-go marker. The worker waits
for that marker, confirms actual account absence (distinct from an existing empty
credential), then atomically publishes `credential-owned.json` **before its first
write**. It creates, reads, replaces, deletes and verifies absence. Failed writes
also attempt cleanup, because native failure can follow mutation. Cleanup requires
that matching native-created ownership grant and preserves any unexpected stored
value. A detected collision, initial read failure or no-go creates no grant and
never deletes an existing credential.

The launcher attempts a separately bounded cleanup only when mutation was
possible. With confirmed worker exit and **no grant**, recovery completes with
`not-needed-no-ownership-grant`: no probe mutation was authorized, and existing
items remain intact. This says nothing about the original native credential gate.
Unconfirmed/live workers always block another store mutator, even without a grant.
A reused live PID conservatively blocks too; recovery never signals it.

If `credential_recovery_required` is true, or the driver itself was killed after
a worker started, retain the complete run directory and original exact binary.
After the recorded worker exits, run:

```sh
python3 prototypes/gpui/native/run.py recover --desktop wayland \
  --executable /absolute/path/dbeer-gpui --helper /absolute/path/dbeer-core \
  --request /absolute/run/directory/probe-request.json
```

Use the matching Windows/X11 desktop and binary paths as appropriate. Recovery
validates the original request/context/artifact/grant and every durable worker
journal; it works without a terminal `summary.json`. Missing or malformed worker
completion evidence authorizes nothing: recovery checks the recorded PID's
current liveness. A completed recovery report is retained separately. Do not
manually delete a service, unlock/reset another user's keyring, or clear the
recorded evidence to bypass a refusal.

## Required actual native observations

Fill each generated `observations.json` gate with observer, UTC time, pass/fail/
blocked/not-run, concrete observation and relative synthetic evidence paths.
Include artifact/PID/session and fixture IDs. Review the actual evidence before
any future versioned registry accepts it; frozen baseline v1 stays immutable.

| Gate | Operator evidence required on Windows, Wayland and X11 |
| --- | --- |
| GPU/rendering | GPU/driver/renderer diagnostics, real resize/minimize/restore/scroll/typing and screenshots. Distinguish hardware/software and VM/remote paths. Actual latency/frame pacing needs the parity responsiveness methodology; capture duration is not input latency. |
| Editor/input/IME | Physical/OS typing/paste of non-BMP/combining text, CRLF, exact quotes/dashes, multiline SQL, caret/selection/Undo, existing IME and AltGr layout. No database execution occurs. |
| Virtualized grid | Scroll the 1,000-row synthetic table horizontally/vertically, resize/sort/select and capture visible ranges before/after. Observe redraw, focus and native keyboard behavior; row count alone proves none of these. |
| Native file dialogs | Real open/save/Cancel, allowed/rejected synthetic paths, overwrite/cancel UI, modal focus and reader behavior. Inspect callback outcomes; verify no selected content/destination operation. |
| Clipboard | External editor paste/copy of synthetic Unicode and TSV/NULL distinctions; check restoration and concurrent-change behavior. Self-write/read booleans alone do not establish OS interoperability. |
| Credentials | Review actual unelevated create/read/replace/delete/absence reports and cleanup. Exercise locked/unavailable service and retry safely with fresh accounts. No mock/in-memory backend or Mac Keychain action substitutes. |
| Keyboard/focus | Actual Tab/Shift+Tab, editing/selection, modal Cancel/default and focus restoration. Workspace Ctrl+T/W/F/Enter/period/Q command parity is later scope; the dedicated probe does not invent those workflows. |
| Accessibility controls | Windows SDK Inspect/Accessibility Insights: select recorded PID, inspect UIA editor/Text selection, table/Grid/row/cell/index, buttons/dialogs and exercise accessible actions. Ubuntu Accerciser/AT-SPI: same PID and equivalent Text/Table/dialog checks in each login type. A flat window, missing interfaces or names without usable ranges/actions blocks acceptance. |
| Screen reader | Installed Narrator/Orca: read/edit multiline non-BMP selection, navigate headers/cells/row changes, open/close dialogs, hear status/errors and recover focus; retain spoken transcript/observations and version. Driver never starts/stops/configures readers. |
| Themes/scaling | Existing light/dark controls, hover/focus/contrast/clipping at real 100%/200% OS scaling; screenshots and exact configuration. |

## Concrete remaining feasibility risks

Locally cached Cargo.lock sources pin `gpui-kit 0.7.3`/`gpui-pre 0.3.9`.
AccessKit docs describe stable IDs, roles and native actions; lock entries include
Windows/Unix bridges. Their target runtime behavior remains unverified here.
Editor/Input provides labels and Focus/SetValue semantics; native text ranges,
caret/selection events and reader behavior still require actual inspection.

Virtualized DataTable has row roles/sort-button labels and visible-range APIs;
its current component lacks a table/cell role surface and DBeer's cell delegate
uses plain divs. The separate gpui-base semantic Table is not the virtualized
component being used. If native inspectors confirm the gap, maintain a narrow
pinned TableDelegate/component adapter for stable ordinal table/row/cell IDs,
virtual counts/selection and accessible scroll/focus actions, or an equivalent
upstream fix. Verify UIA Table/Grid/Text and AT-SPI Table/Text before building all
screens. Do not turn missing functionality green by adding metadata names alone.

Rendering, chooser, credential or accessibility failures remain release blockers.
Next required inputs are owned standard-user Windows 11 x64 and Ubuntu 24.04 x64
desktops with both session types, working GPU drivers, inspectors/readers and
unlocked Secret Service. No target graphical run has been performed yet.

## Focused checks and development evidence

```sh
python3 prototypes/gpui/native/test_run.py
./scripts/gpui-prototype.sh test --locked --features native-smoke feasibility::tests
./scripts/gpui-prototype.sh clippy --locked --features native-smoke --all-targets -- -D warnings
./scripts/gpui-prototype.sh check --locked
./scripts/gpui-prototype.sh fmt -- --check
python3 prototypes/gpui/parity/check.py validate
```

Python safety checks cover owned-child cleanup/sentinel survival, exact identity,
private regular requests, malformed/recursive events, atomic handshake,
collision/no-grant preservation, hard-failure recovery without terminal summary,
malformed terminal fallback, missing requests and prior-live-worker blocking.
Rust fake-store tests cover absence/empty collisions, claim/write/delete failures,
cleanup sanitization, path boundaries and 1,000 synthetic row identities.
Windows ctypes/native stores and all target GUI paths remain unrun.

The Mac-only `--feasibility-dev-smoke <owned request>` performs just two scene/
visible-range captures and a last-row request, then exits; it never invokes
clipboard, chooser or credential actions. A bounded local attempt timed out
before its first capture on 2026-10-19; the exact child was terminated and
metadata is retained under
`build/gpui-parity/native-runs/macos-development-80787caf3c84486ea3a7c8c9cb8e0eda/`.
A comparison using the same rebuilt binary/environment then ran existing Demo
smoke and the new probe separately, with both timing out before any capture.
Both logs report invalid `com.apple.hiservices-xpcservice`/LaunchServices
connections; bounded stack sampling returned 255. Both exact children were
terminated and completed summaries/logs are retained under
`build/gpui-parity/native-runs/macos-comparison-3903d03ff24d4729a37330d42b7596e6/`.
This establishes a shared desktop-service limitation in this execution context;
Mac rendering remains unverified. No trust/input/desktop-service changes were
made. Frozen replay/app/evidence byte hashes still match; a fresh system codesign
trust check reported `CSSMERR_TP_NOT_TRUSTED`, with no signature-trust pass claimed.
The frozen baseline and signing identity remain untouched.
