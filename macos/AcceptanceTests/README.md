# Installed archive acceptance

Standalone Apple XCTest UI Testing runner for the existing signed DBeer archives.
It does not link DBeer sources, rebuild the application, inject code, change TCC,
or change the globally selected developer directory.

Build only (does not launch DBeer):

```sh
./macos/AcceptanceTests/run.sh --build-only
```

The fixture installer owns archive verification, installation, data directory,
temporary database lifetime, initial credential provisioning and cleanup. It
launches the exact installed executable before running the UI test. Only build 5
may receive the supported `--connect-stdin` input; build 6 must start normally.

Pass a private mode-0600 JSON configuration containing:

```json
{
  "installAppPath": "/absolute/path/DBeer.app",
  "bundleIdentifier": "dev.dbeer.app",
  "expectedBuild": "5",
  "phase": "build5-postgresql",
  "launchPolicy": "attach",
  "ownedPID": 12345,
  "smokeProfileID": "00000000-0000-0000-0000-000000000001",
  "smokeProfileEngine": "postgresql",
  "inputSourceOriginalID": "com.apple.keylayout.British",
  "inputSourceASCIIID": "com.apple.keylayout.US",
  "resultFile": "/absolute/private/state/build5-postgresql-result.json"
}
```

```sh
./macos/AcceptanceTests/run.sh /absolute/private/config.json
```

For the first `build5-import` phase, omit `smokeProfileID` and
`smokeProfileEngine`, and provide `portableProfilesPath` plus
`importProfileNames` (the two exact fixture profile names). The runner opens the
real Connections → Import Connections menu and Open panel, verifies both names
and engine labels in the preview, confirms Import, and quits normally. The
fixture owner then validates the app-written library and owns only its new UUIDs.

The runner refuses any different or additional DBeer process, validates the exact
bundle path/build and PID before UI actions, and checks the foreground PID before
keyboard input. It deliberately never calls `XCUIApplication.launch()` (which
terminates an existing instance) or `terminate()` (which sends SIGKILL). It
activates the already provisioned app, connects the fixture profile through its
context menu, opens a SQL tab and executes a fixture `SELECT 1`. The
`build5-postgresql` phase then starts `pg_sleep(30)`, clicks the actual window
close control, chooses Cancel, checks the same PID/window and running controls,
then closes again with Stop and Continue. Other phases use Command-Q. A failed
test leaves process cleanup to the fixture owner.

The fixture captures the actual input source with the built
`build/AcceptanceTests/input-source-guard snapshot` helper. During a phase,
keyboard actions temporarily select that recorded, already enabled ASCII source.
The runner restores the original source after normal exit; the fixture also runs
the conditional restore after runner failure. A different source selected by the
user is preserved and fails the phase. No source is enabled or registered and no
input-source preferences are written.

Supported phases are build5-import, build5-postgresql, build5-mysql,
build6-postgresql, build6-mysql. Configuration can contain additional installer-owned keys; the UI
test does not read passwords or password files. Run artifacts and screenshots are
private under ignored `build/AcceptanceTests/`; the configuration path alone is
placed in the generated `.xctestrun` environment. The sandboxed runner publishes
a nonsecret JSON attachment and single evidence line; after successful XCTest,
the wrapper writes `resultFile` with mode 0600. Automatic system attachments are
discarded; explicit screenshots target only the application's window. A separate
fixture observer must verify actual backend state and cleanup; the UI runner's
`longQueryObserved` flag refers to enabled Stop/disabled Run controls.

macOS may require ordinary UI
Testing authorization; this runner does not grant, reset or bypass it.

## Archive to current application update acceptance

The same isolated installer can update an existing release archive to a current
owner-signed application without creating a release ZIP or changing version/build
metadata:

```sh
./scripts/test-install-update.sh \
  --baseline-archive "$PWD/build/releases/DBeer-0.1.0-6-macos-arm64.zip" \
  --candidate-app "$PWD/build/DBeer.app"
./scripts/test-install-update.sh \
  --baseline-archive "$PWD/build/releases/DBeer-0.2.0-8-macos-arm64.zip" \
  --candidate-app "$PWD/build/DBeer.app"
```

Both options must be supplied together. The no-argument command retains the
original build 5 → 6 archive scenario. Candidate mode accepts the 0.1.0/build 6
and 0.2.0/build 8 baselines, verifies the baseline checksum/CRC and both bundles'
strict signatures, arm64 executables and matching persistent signing identities.
It snapshots the supplied candidate and compares complete file/symlink hashes;
identical version/build metadata is permitted when the contents differ.

The baseline UI imports two synthetic profiles into an empty private library.
An acceptance-only utility, signed with the baseline's exact certificate,
provisions only those new UUIDs' database passwords through stdin. Baseline
items must first be verified empty without requesting authentication UI. The
system `security` utility deletes only that verified service/UUID, and the signed
utility creates its replacement only if the item is still absent. This avoids
editing the archived app's Keychain owner ACL and rejects nonempty or duplicate
items. Baseline PostgreSQL/MySQL queries prove the initial credentials. The
installer then removes the password files, replaces its private installed copy with the candidate and
launches it normally. The candidate never receives credentials through startup
arguments, environment, stdin or UI-test configuration.

The candidate-disconnected phase selects both preserved drafts and checks exact
text, absence of results and idle controls. An independent observer requires no
database sessions during this phase. Subsequent PostgreSQL/MySQL phases prove
access to the same Keychain items. The installer verifies preserved profile UUIDs,
draft IDs/order/text/bindings, current storage versions and exact private migration
backups, then confirms normal app/helper/database cleanup and unchanged owner
files, input source, source archive and candidate bundle.

Candidate configurations add `expectedVersion`, `artifactRole` (`baseline` or
`candidate`), and the synthetic `restoredDraftIDs`/`restoredDraftTexts`. Supported
phases are baseline-import, baseline-postgresql, baseline-mysql,
candidate-disconnected, candidate-postgresql and candidate-mysql. Credentials are
not part of this external UI interface. Reports remain private under ignored
`build/install-update/run.*/`; the result covers the supplied `.app`, not a future
packaged archive, Finder/Gatekeeper or installation on a second Mac.

## SSH lifecycle acceptance

The current signed native app has a separate external UI scenario:

```sh
./macos/AcceptanceTests/run.sh --build-only
./scripts/test-ssh-ui.sh
```

The fixture copies the signed `build/DBeer.app` into a private directory and
opens that exact copy through LaunchServices, with an isolated application data
directory. It refuses to run alongside another DBeer app/helper. No app code is
injected, and the original profile/document files and release archives are
preserved. Xcode is addressed explicitly; the selected developer directory is
unchanged.

A disposable SSH bastion reaches a PostgreSQL container whose database port is
not published. A fresh profile uses a generated encrypted private key. Only this
profile's synthetic database password is provisioned in Keychain. Its unsaved key
passphrase comes from a private fixture file into the exact owned secure prompt,
using native Paste through authorized XCTest keyboard actions. The runner preserves
all clipboard items/formats and restores them only while it still owns that change;
the secret is never supplied to XCTest text-action logging or attached diagnostics.
The scenario covers Cancel, incorrect input and successful input, including prompts
for independent working sessions. The provisioning utility uses the app's exact
persistent signing certificate for its scoped database credential; no Keychain
defaults, event-posting permissions or system trust settings are changed.

`SSHApplicationTests/testSSHConnectionLifecycle` attaches to the owned PID and
checks Cancel on the first host-key review, a second review of the exact generated
SHA256 fingerprint, trust acceptance and connection. It opens two SQL tabs, checks
different PostgreSQL backend PIDs and independent temporary tables, runs another
tab while `pg_sleep` is active, clicks Stop, verifies recovery, disconnects the
profile and quits normally. The external fixture independently observes backend
state, accepted SSH key, private-key authentication and resource cleanup. It also
requires the SSH/watchdog processes and SOCKS listener to disappear after profile
disconnect while the application is still running. XCTest waits for that
observer acknowledgement before sending Quit, so application termination cannot
mask a tunnel left open by Disconnect.

A second `ssh-crash` phase reconnects the same private signed app and publishes
readiness without terminating it. The independent fixture requires an observed
database session, SSH process, watchdog and SOCKS listener, then sends SIGKILL to
only the exact owned app PID. It requires every owned process/session/listener to
disappear before cleanup can mask the result. This phase is distinct from the
normal Quit scenario; the XCTest code never calls `XCUIApplication.terminate()`.
Process observation uses exact kernel executable paths and owned ancestry across
fork/exec transitions; presentation names from `ps` do not establish identity.

Artifacts are private under ignored `build/SSHAcceptance/run.*/` and
`build/AcceptanceTests/run.*/`. The report records actual UI evidence, screenshots,
backend observations, input-source restoration and cleanup. Only the fixture's
new UUID/account entries and profile-scoped SSH trust record are removed.

macOS can request authentication for **Enable UI Automation** before the test
body starts. The owner must confirm that system request; a timeout is an
infrastructure failure and does not count as a completed UI scenario. The fixture
does not alter TCC, system trust or authorization settings.
