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
  "inputSourceOriginalID": "com.apple.keylayout.RussianWin",
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
