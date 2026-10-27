# DBeer GPUI client (experimental)

**Contributions welcome:** Windows and Linux clients are outside the v0.2.0
roadmap and release scope, with no release date announced. Current product
development focuses on native macOS and the Go helper. This prototype is a
starting point for contributors to own platform development, protocol
compatibility, builds and native acceptance.

An isolated native Rust client built with GPUI Kit, using the existing DBeer Go
helper and protocol v3 for real PostgreSQL and MySQL connections. It does not
replace the SwiftUI/AppKit application or change its profiles, credentials,
release archives, database adapters, or protocol. Synthetic demo profiles are
available only in explicit disposable Mac development demo/smoke modes. Windows and Linux are the product
targets for this frontend. The macOS DBeer product remains SwiftUI/AppKit,
including its existing `scripts/build-app.sh`, CI job, and release packaging.
GPUI on Mac remains available as a separate development app. Versioned profile
storage, exact-byte migration backups, stable selection and credential rollback
are described in [PERSISTENCE.md](PERSISTENCE.md); runtime/native acceptance
remains deferred. Portable Swift-compatible v2/legacy-v1 profile transfer, native
review/CA remapping and atomic publication are described in [TRANSFER.md](TRANSFER.md).
Execution source splitting, immutable selections and explicit byte/UTF-16/LSP/error
position conversions are described in [PARSING.md](PARSING.md); shared Swift/Rust
cases are compiled, with execution deferred to final integration.
The shared command dispatcher, desktop menus, focus gates and extension points
are described in [COMMANDS.md](COMMANDS.md); command runtime/native checks are deferred.

## Build and run

Source builds require Rust 1.92+ (CI uses 1.99.1) and the Go version in
`helper/go.mod`. Windows x64 requires the MSVC Rust toolchain, Visual Studio C++
Build Tools with the Windows SDK, and CMake. Linux CI targets Ubuntu 24.04 x64;
install GPUI's native dependencies plus `libdbus-1-dev`. Displaying the Linux UI
requires Wayland or X11 with a working Vulkan driver. The
[GPUI Kit installation guide](https://gpui-kit.com/docs/installation/) describes
the native toolchains and libraries. Linux desktop password storage also needs
an installed, running, unlocked Secret Service on the user's session D-Bus.

Build a native Linux development archive from the repository root:

```sh
./scripts/build-gpui-client.sh --test --package
```

On Windows, run in PowerShell with native Go, Rust MSVC, and CMake on PATH:

```powershell
./scripts/build-gpui-client.ps1 -Test -Package
```

Both entry points compile the exact marked GUI/helper pair by default. Test
options run the separate unmarked headless verifier; package options inspect
the pair and write a new unsigned candidate with SHA256 under
`build/gpui/candidates/`. See [BUILD_INTEGRATION.md](BUILD_INTEGRATION.md) for
source identity, native resources and complete notice preparation. Extract the
archive and keep `dbeer-gpui[.exe]` beside `dbeer-core[.exe]`. Rust and Go are not
required at runtime. Linux still needs the platform runtime libraries and GPU
driver; Windows may need the Microsoft Visual C++ x64 Redistributable. These
archives are experimental CI artifacts, not installers or published releases.

For local GPUI development on macOS 15+ Apple Silicon with Command Line Tools:

```sh
./scripts/gpui-prototype.sh
./scripts/gpui-prototype.sh run -- --demo
./scripts/build-gpui-app.sh
open build/DBeerGPUI.app
```

The development wrapper supports unmarked checks/tests; Windows/Linux product
launch requires the paired marked native build. Default Mac run/build uses
`build/gpui/dbeer-core`; selected custom Cargo target directories keep their
helper alongside that target's outputs. Explicit prebuilt helpers are retained.
Cargo
artifacts and caches stay under ignored `build/gpui/`; an existing local toolchain
under `build/gpui/toolchain` is used when Cargo is absent from PATH. No toolchain
is installed automatically.

The separate signed Mac development app bundles `Contents/Helpers/dbeer-core`,
so it needs neither Go nor Rust at runtime. It uses the owner's persistent Apple
Development identity for both executables, shared `VERSION`/`BUILD_NUMBER`, the distinct bundle identifier
`dev.dbeer.gpui-prototype`, and `DBeerBuildKind=prototype`. Packaging defaults to
debug; `CONFIGURATION=release` enables optimized builds. Existing signing
identity/keychain overrides apply. No release archive is published or replaced.

## Real connections

Fresh product startup has no built-in profiles or sample SQL: an empty SQL
document stays disconnected until you select a saved connection and explicitly
connect or run. Missing saved bindings preserve their document IDs and SQL without
inventing a connection. The DBeer display/app identity does not migrate private
files, UUIDs, passwords or the existing credential service. Read the
[standard-user install/update/remove guide](packaging/INSTALL.md).

Use **+** beside Connections to add PostgreSQL or MySQL. Enter host, port,
database, user, password, TLS mode, and an optional absolute CA certificate path.
New profiles default to **verify-full**, an **unspecified environment**, and
**Readonly disabled**. Existing profile policies retain their saved values.
Choose another TLS mode explicitly when connecting to a disposable local server.
**Save** stores settings without connecting; **Save and Connect** also opens the
catalog session. Passwords use macOS Keychain, Windows Credential Manager, or
Linux Secret Service under a separate GPUI service identity, never JSON or logs.
An unavailable credential store produces an error; there is no plaintext or
in-memory fallback. Replacing a password with an empty value stores an empty
credential, distinct from a missing item. Edits without password replacement
never access the saved credential.

| Platform | Nonsecret profile library |
| --- | --- |
| macOS development app | `~/Library/Application Support/DBeerGPUI/connections.json` |
| Windows | `%LOCALAPPDATA%\DBeerGPUI\connections.json` |
| Linux | `$XDG_CONFIG_HOME/dbeer-gpui/connections.json`, falling back to `$HOME/.config/dbeer-gpui/connections.json` |

Profile roots must be absolute; invalid Linux XDG overrides fall back to HOME.
Files use private Unix permissions or inherit the Windows user's local app-data
directory permissions. Profile updates replace the file atomically.
Normal launches acquire a kernel-held exclusive ownership lock before loading
or saving the profile library. A repeated launch using that directory refuses
and exits; close the existing instance first. The lock is released on process
exit/crash, and its file must not be deleted as stale. The store and pending
atomic replacements retain ownership throughout their lifetime. Dedicated
feasibility/smoke modes and `--demo` stay isolated from the personal library.
Startup loads profiles disconnected and never executes restored SQL.
**Import...** previews portable connections with individual/all selection and
explicit missing/foreign CA remapping; imports create disconnected profiles
without changing existing credentials. **Export All...** and a saved profile's
**Export...** action share metadata without passwords, private keys or IDs.
Ordinary writable workspaces persist private SQL drafts and managed history in
the owned GPUI data directory. Drafts retain document IDs, titles, full editor
text, connection bindings, order and selection after a one-second debounce and
an awaited normal-close flush. History can record executed statement text and
outcomes, with a recording preference, Clear History, disconnected reopen and
retention of up to 1,000 entries for 30 days. Treat this local state as private
source-bearing data. Restore and history reopen never connect or execute SQL;
missing connections retain their drafts for explicit recovery. Live sessions,
query results, credentials and pending table changes are excluded. See
[RESTORATION.md](RESTORATION.md) for the exact boundary and recovery workflow.

Select a profile and use **SQL +** (or Ctrl+T; Cmd+T on Mac) to create an
independent SQL tab. **Run / Ctrl+Enter** (Cmd+Enter on Mac) resolves the selection or current
statement from its unchanged editor source while the editor has focus. The
current single-statement path refuses malformed or multiple statements before
helper startup. **Run Script / Ctrl+Shift+Enter** (Cmd+Shift+Enter on Mac) reviews
the entire captured source and helper classification, then runs its statements
in order on the original tab session. First failure or Stop skips the remaining
statements. See [SCRIPTS.md](SCRIPTS.md). Execution opens that tab's physical session
on its first execution. Each tab retains its
transaction and session state until explicitly disconnected or closed. Catalog
operations use a separate service session. **Connect / Refresh** loads schemas;
expand a schema for tables and views. Opening an object asks the Go adapter to
generate a correctly quoted SELECT and opens it without executing it.

**File > Open SQL... / Ctrl+O** opens UTF-8 SQL files into disconnected tabs.
**Save SQL / Ctrl+S** saves the captured SQL tab to its bound file, asking for a
destination when unbound; **Save SQL As... / Ctrl+Shift+S** always asks for a
destination. Native picker callbacks retain the original tab/source rather than
the later focus. Saving an older capture leaves newer edits unsaved. See
[FILES.md](FILES.md) for overwrite, cancellation, publication and recovery rules.

Readonly is enforced by the helper policy and the server's session mode. A
restricted database user is still required for strict access control; server
readonly modes and conservative SQL classification have documented exceptions.
See the main README for the existing helper policy's limitations. To change a
profile's readonly setting, disconnect it and edit the saved profile. Destructive and
unknown commands require review of the exact SQL; Production confirms every
write. Approval is tied to the SQL and session and is invalidated by edits,
errors, Stop, or reconnection. Dedicated table documents now stage typed changes
and provide exact helper-generated Preview SQL and fresh-session atomic Apply.
Apply requires explicit review, retains authoritative completion after Stop and
blocks retry after lost COMMIT confirmation until inspection and Discard/Reload.
Known commit plus failed reload also blocks reapply. See [APPLY.md](APPLY.md) for
ownership, recovery and deferred runtime/native acceptance.

**Stop** (Query menu or toolbar) sends helper cancellation and waits for a
terminal response.
The tab's transaction status remains visible, including failed transactions.
Closing a tab/profile/window, using Ctrl+Q (Cmd+Q on Mac), or choosing Quit in
the Mac Dock prompts for Commit/Roll Back when needed; Cancel keeps the session
and transaction open.
Repeated Dock Quit requests preserve the current dialog and leave the selected
Commit/Roll Back operation running. The app waits for the helper to finish that
operation and disconnect its sessions before exiting. An unknown outcome blocks
further SQL until the database has been checked and the session explicitly
disconnected. Forced process termination
can still leave an in-flight commit with an uncertain outcome.

Streaming uses chunk acknowledgements and validates framing, IDs, row widths,
column order, and metadata. The display is bounded to 1,000 rows and 8 MiB across
result sets, with an explicit truncation notice. The helper drains execution to
completion. Multiple result sets can be selected in the results header. Grid
sort/filter affect loaded rows only. SQL NULL, empty text, literal `NULL`, exact
numeric strings, and Base64 binary data remain distinct. Copy Rows copies quoted
TSV, with unquoted `\N` for NULL and a `base64:` prefix for binary display data;
this is display copying rather than a complete database export.

Task 16 adds actual rectangular/sparse/full-row selection, retained per-result
widths/viewport, native typed JSON plus TSV selection copy and synchronized
read-only row details. Selection reconciles only identifiable rows during the
same table refresh and cannot move onto another result/page/operation. See
[GRID.md](GRID.md) for exact values, native formats and deferred acceptance.

## Shortcuts

| Windows/Linux shortcut | Action |
| --- | --- |
| Ctrl+N | New connection |
| Ctrl+T | New tab using the selected profile |
| Ctrl+W | Close the active tab, resolving its session first |
| Ctrl+Enter | Run the selection/current statement while the SQL editor has focus |
| Ctrl+Shift+Enter | Review the whole captured script, then execute its statements in order |
| Ctrl+O / Ctrl+S / Ctrl+Shift+S | Open SQL / Save SQL / Save SQL As using native file dialogs |
| Ctrl+F | Focus catalog search |
| Ctrl+Q | Close through the workspace transaction workflow |

Run and Run Script require a SQL document with its original available connection
and compatible session settings, no active operation or unknown outcome, and no
dialog, close or pending file/export/transfer workflow. Keyboard execution
requires the focused SQL editor outside composition; text fields and grids keep
their own input behavior. Open and Save share the dialog/close/pending-workflow
gates; Save and Save As also require a SQL document. File commands do not require
a database connection. All callbacks revalidate their captured owners. These are
implemented commands; their runtime and native Windows/Linux acceptance remain
pending. See [COMMANDS.md](COMMANDS.md) for exact availability and capture rules.

The Mac development app uses Cmd instead of Ctrl. Stop and Toggle Light / Dark
remain explicit controls without a default shortcut. The toggle uses the same
persisted native appearance selector as Settings > Appearance. That Settings
workflow offers System/Lager/Porter and all loaded named application schemes,
plus an independent editor scheme or Follow App Appearance, with a retained live
preview. Choices live in appearance.json under the original owned GPUI data
directory; missing/corrupt values use safe fallback and explicit Reload. Native
input Edit shortcuts retain their focused control behavior. Unavailable commands
stay disabled with a visible reason. Runtime/native appearance acceptance remains
pending; see APPEARANCE_SETTINGS.md.

## Verification

CI adds native Windows x64 and Linux x64 jobs alongside the existing SwiftUI
macOS job. Each GPUI job builds a release GUI and helper, runs headless tests
including a real helper handshake/shutdown, checks Clippy, and uploads its
platform archive. Linux also checks Rust formatting. These jobs do not require
a graphical session, desktop credential service, or a live database. A passing
build does not verify rendering, GPU compatibility, native credential-store
roundtrips, keyboard behavior, or database integration on that platform.

```sh
./scripts/gpui-prototype.sh test --locked -- --test-threads=1
./scripts/gpui-prototype.sh clippy --locked --all-targets -- -D warnings
./scripts/gpui-prototype.sh fmt -- --check
./scripts/test-gpui-databases.sh
```

The [workspace foundation](WORKSPACE.md) documents typed identities, operation
and session snapshots, helper-death reconciliation, retained per-tab editors and
single-instance storage ownership. Task 3 proceeded under the user's explicit
implementation-order waiver while Task 2's native Windows/Ubuntu checks remain
open. No target-native acceptance is inferred from these local checks.

The default suite tests framing, shared fixtures, stream bounds, session errors,
process shutdown, profile persistence, exact values, and grid behavior. Database
cases require the isolated runner and otherwise return without accessing a
server. The explicit Docker runner creates and removes disposable PostgreSQL
and MySQL servers and verifies real connections, streaming, catalog, independent
sessions, transactions, readonly, cancellation, and exact one-shot write approval.
It also runs headless GPUI production Workspace tests with profile reordering,
source edits during execution, independent tab results/transactions, Stop,
rollback, and acknowledged profile disconnect. Real helper I/O uses GPUI's
supported external-I/O test-scheduler mode. Without the isolated runner, the
DB-guarded cases return early; they do not establish database coverage.
Its opt-in write checks use temporary tables in those disposable databases.

On Mac, the Keychain roundtrip is opt-in and creates/deletes a disposable Keychain,
without changing the login Keychain or system search list:

```sh
./scripts/gpui-prototype.sh test --locked disposable_keychain_password_roundtrip -- --ignored
```

Native UI exercises use real GPUI windows and save screenshots plus completed
summaries under `build/gpui/qa/` (demo) and `build/gpui/qa/live/` (real databases):

```sh
./scripts/gpui-prototype.sh run --locked --features native-smoke -- --smoke-test
./scripts/test-postgres.sh ./scripts/test-mysql.sh \
  ./scripts/gpui-prototype.sh run --locked --features native-smoke -- --live-smoke-test
./scripts/test-gpui-termination.sh
```

Native live checks use temporary in-memory profiles and runner credentials;
they do not read/save personal profiles or Keychain items. The feature is not
included in normal app builds. The termination runner is Mac-only and exercises
AppKit's native Quit entry point in five separate app processes: Cancel, repeated Quit, Commit
and Roll Back against both databases, plus idle Quit. An independent helper
verifies committed/rolled-back data after each process exits, and completion
requires the guarded window close. Its summary is saved under
`build/gpui/qa/termination/`. Accessibility, SQL file/history/export features,
and the production Swift application are not covered by these prototype checks.
TLS settings are passed unchanged to the existing helper; the prototype-specific
runner uses disposable local servers with TLS disabled and does not add new TLS
coverage.
