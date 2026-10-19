# DBeer

A native SQL client for macOS 14+ on Apple Silicon, built with SwiftUI/AppKit and a bundled Go helper. Supports PostgreSQL 16/17/18 and MySQL 8.0/8.4.

Multiple profiles can run simultaneously. Each SQL tab gets its own connection on first execution and retains its transaction, SET state, and temporary tables until disconnected. The catalog and data tabs use separate sessions. Stop cancels the selected execution; Disconnect closes one profile's sessions.

## Using the application

- **⌘N** creates a PostgreSQL/MySQL profile. Save stores the settings; Save and Connect opens a connection. Passwords live in macOS Keychain, and settings in `~/Library/Application Support/DBeer/connections.json`.
- **⌘T** creates a SQL tab. **⌘Return** executes the selection or the statement at the cursor; **⇧⌘Return** runs the entire script sequentially until the first error or Stop. The editor supports highlighting, line numbers, undo, completion, and navigation to PostgreSQL error positions. After connecting, user table, view, schema, function, and column names load automatically for completion without expanding the tree; columns respect tables and aliases in the current query. Suggestions appear while typing and with **⌃Space**; profile Refresh updates metadata.
- The tree loads on demand and provides search, Refresh, structure, definitions, Copy Name, and Generate SELECT. Double-click a table to open its first 200 rows. Filtering and sorting run on the server; pagination uses the primary key for stable ordering without automatic COUNT queries.
- Double-clicking an editable cell creates a local change. Insert Row, Delete Selected, Preview SQL, Apply, and Discard manage the batch. Apply uses a separate transaction and checks original rows under locks. A conflict or constraint error rolls back the entire batch. An unknown COMMIT outcome blocks another Apply until the outcome is checked and data is reloaded.
- Arbitrary SQL, views, and tables without a primary key are read-only; MySQL editing requires InnoDB. Computed and unsupported types cannot be edited, with the reason shown in the interface.
- Copy cells, rows, and ranges with **⌘C** or the context menu. Export Loaded saves rows already received. The separate **Run to File** action executes one statement once and publishes the complete file only after successful completion.
- **⌘O**, **⌘S**, and **⇧⌘S** open and save UTF-8 `.sql` files. Drafts are saved after one second of inactivity. History is enabled by default: 1,000 entries retained for 30 days. Query → SQL History can disable or clear history, or clear restored documents. Restoration never connects to a database or executes SQL.
- Connections → Import/Export Connections transfers profiles without passwords or private keys. Import shows a preview, creates new UUIDs, and requires selecting any missing CA while preserving the TLS mode.
- Closing a tab, profile, or the application offers to complete transactions and apply/discard changes; Cancel keeps the window open. DBeer → Settings (**⌘,**) selects System/Light/Dark.

SQL NULL, empty strings, the text NULL, and DEFAULT remain distinct. Column order and duplicate names are preserved. JSON uses metadata and value arrays, exact numbers are strings, and binary values use Base64. CSV uses UTF-8 and a selected NULL marker; a collision requires choosing another marker. Display is limited to 1,000 rows and 8 MiB with an explicit truncation notice; complete Run to File exports have no such limit. Statement timeout is 30 seconds.

The script splitter handles strings, comments, PostgreSQL dollar quoting/BEGIN ATOMIC, and MySQL DELIMITER. Version 1 excludes psql/mysql client commands, COPY streams, LOAD DATA LOCAL, SSH tunnels, and external plugins.

## Next release changes

The Query menu, execution buttons, and keyboard share a command registry for the active document. Default shortcuts are preserved: **⌘Return** runs the selection or current statement, and **⇧⌘Return** runs the entire script. The Run fragment is highlighted inside the editor and updates with cursor or selection changes. A cursor immediately after `;` still belongs to the completed statement.

DBeer → Settings → Shortcuts records custom Run, Run Script, Stop, and Run to File shortcuts, clears assignments, and restores defaults. Assignments persist between launches; conflicts and protected editing shortcuts are rejected. Commands respect focus and the active tab; settings windows, dialogs, and typing in other text fields never launch SQL.

The working branch adds unset, development, staging, and production environments and a separate readonly setting. These changes are not yet included in the published 0.1.0 archive. The environment appears as text and color in the profile, SQL tab, and confirmation. The profile editor first routes open sessions through normal transaction completion; Cancel preserves the previous context.

Execute, scripts, Run to File, and Apply share one helper policy: destructive and unrecognized commands require confirmation in every environment, and production confirms every write. Multi-statement runs, including editor selections, show the entire batch before the first statement. Approval is tied to the exact SQL or typed changes and the current session; edits, errors, Stop, and reconnection prevent reusing any remaining approval.

Readonly rejects writes and unknown constructs before reaching the adapter, disables grid editing, and enables server-side read-only mode. The classifier structurally accounts for strings, comments, CTEs, and dialect; unsupported syntax and unknown functions are not classified as reads. Use a separate database user with restricted permissions for a strict write prohibition: server modes have exceptions, including temporary tables, and do not replace access controls. See [PostgreSQL SET TRANSACTION](https://www.postgresql.org/docs/18/sql-set-transaction.html) and [MySQL SET TRANSACTION](https://dev.mysql.com/doc/refman/8.4/en/set-transaction.html).

Assessment follows SQL structure and a limited list of built-in functions for each engine. Production confirmation applies to operations classified as writes or unknown commands. Views, custom overloads of built-in names, casts, and operators can hide side effects; the client does not fully resolve server objects and types. Server-side readonly blocks ordinary writes to permanent tables, but database permissions must restrict server-allowed temporary-table exceptions and function execution.

## SQL editor in the next release

The editor in the working branch has increased internal padding and line spacing, current-line highlighting, and line numbers with an active-line indicator. Syntax, cursor, and selection colors adapt to light and dark themes; execution highlighting is preserved.

A green checkmark beside the first line number marks a successfully executed SQL statement. Scripts mark every completed statement; errors, cancellation, and unknown outcomes are not marked. Editing text, changing the connection profile, or starting another run clears previous marks.

The bundled local language server suggests PostgreSQL/MySQL keywords and functions, tables, columns, and aliases. Completion appears while typing; **⌃Space** invokes it explicitly. **↑/↓** selects an item, **Tab/Return** inserts it, and **Escape** closes the popup. Standard Undo reverses insertion. Switching profiles or dialects updates the context; responses for earlier text are discarded.

**Settings → Appearance** separates the application appearance from the SQL editor scheme. The application supports System, Light, Dark, and every scheme in the shared library: DBeer Light/Dark, VS Code Light+/Dark+, Solarized Light/Dark, JetBrains Light, Darcula, and imported schemes. Application and editor choices are saved independently: for example, the application can use Solarized Light while the editor uses Darcula. Application colors apply to backgrounds, the sidebar, tabs, controls, and result tables; the Dock icon follows the scheme's light or dark appearance. In **Follow App Appearance** mode, the editor inherits the application scheme. The preview and open SQL tabs update immediately while preserving text, cursor position, scrolling, and Undo.

**Import Theme…** accepts standard VS Code `.json`/`.jsonc`, TextMate `.tmTheme`, and JetBrains `.icls` color schemes. Export a JetBrains scheme through **Editor → Color Scheme → Export → IntelliJ IDEA color scheme (.icls)**. Supported settings include editor, selection, cursor, and line-number colors, basic SQL token classes, and available text styles. JetBrains UI `.theme.json` files, JAR plugins, TextMate grammars, and semantic-token rules are not loaded. `.icls` supports Default/Darcula inheritance; an unknown parent produces a clear error.

JSONC can contain comments and trailing commas. Local `include` files and `tokenColors` references to `.tmTheme` resolve within the selected scheme's directory and its subdirectories. Import saves a standalone local copy in `~/Library/Application Support/DBeer/EditorThemes/themes.json`; source files are no longer needed. Available VS Code UI colors style the application, with missing colors derived from the editor palette for readability. **Remove Theme** removes only imported schemes and returns the editor to automatic selection; if the scheme is selected for the application, it returns to the previous System/Light/Dark appearance. Built-in schemes cannot be removed. Importing and switching themes never executes SQL or connects to a database. Format references: [VS Code](https://code.visualstudio.com/api/extension-guides/color-theme), [TextMate](https://www.sublimetext.com/docs/color_schemes_tmtheme.html), [JetBrains](https://www.jetbrains.com/help/idea/configuring-colors-and-fonts.html).

Table, function, and column completion uses only metadata already loaded by the object tree, search, and inspector. Expand Columns or open a table's structure to add its columns to completion. The language server never connects to a database or executes SQL; restored tabs remain disconnected. It ships with the application and needs no third-party tools. Diagnostics identify unclosed strings, comments, and parentheses; they do not replace server-side SQL validation. If the language server is unavailable, normal editing, execution, and basic completion remain available. These changes are not yet included in the published 0.1.0 archive.

## Building

Requires macOS 14+ on Apple Silicon, Swift 6 with Swift Testing, and the Go version specified in `helper/go.mod`. Verified locally with Swift 6.4 and Go 1.27.1. Full Xcode is not required for application builds or component tests. Go downloads dependencies on the first build.

```sh
./scripts/build-app.sh
open build/DBeer.app
```

The output is `build/DBeer.app`, using the release configuration by default. For debug, run `CONFIGURATION=debug ./scripts/build-app.sh`. The packaged application includes the helper; Go, Swift, and source code are not needed to run it.

VERSION and BUILD_NUMBER define the application version and build number. The application and helper use a persistent **Apple Development** certificate from the login Keychain. If multiple certificates are available, set DBEER_SIGNING_IDENTITY to the SHA-1 shown by `security find-identity -v -p codesigning`. Use DBEER_SIGNING_KEYCHAIN for a different Keychain. The script never falls back to ad hoc signing. macOS may request codesign access to the key on first use.

Application icons are in `macos/Resources`; after editing SVG files, run `./scripts/build-icon.sh` to regenerate PNG/ICNS files. CI uses a separate temporary signing certificate and marks builds with DBeerBuildKind=ci; these builds are not used as team updates.

## Verification

```sh
./scripts/test.sh --filter SQLScriptParserTests
./scripts/test.sh --filter 'SQLEditorTests/executionHighlight'
./scripts/test.sh --all
./scripts/test-postgres.sh
./scripts/test-mysql.sh
./scripts/test-tls.sh
```

For small changes, select affected Swift suites or methods with `--filter` (a regular expression; the flag can be repeated). This mode skips Go tests. Theme and UI checks run only when selected by the filter. A complete Go race and Swift Testing run requires explicit `--all`; use it for cross-cutting changes and final verification. Without a mode, the script prints usage and exits without building or testing. CI runs the full suite.

Both `test.sh` modes build the application and run Swift Testing in a temporary test Keychain. An empty test selection is a failure. Database-dependent checks are skipped when no database is available. The test-postgres.sh and test-mysql.sh scripts start isolated Docker databases with random passwords; a missing required database is a failure. To run the complete native scenario with both engines:

```sh
DBEER_QA_OUTPUT_DIR="$PWD/build/qa" ./scripts/test-postgres.sh ./scripts/test-mysql.sh ./scripts/test.sh --all --require-postgres
```

Select versions with DBEER_TEST_POSTGRES_IMAGE=postgres:18 and DBEER_TEST_MYSQL_IMAGE=mysql:8.0. `test-tls.sh` creates a temporary CA and checks trust, hostname mismatch, and an untrusted certificate against a real PostgreSQL server. MySQL TLS is covered by test-mysql.sh. Containers and keys are removed after verification; diagnostic logs never contain SQL, results, or passwords.

Use DBEER_TEST_DSN for an existing isolated PostgreSQL test database; add `--require-postgres` to the selected mode to require it. For helper-only tests, including Linux, run `./scripts/test-go.sh`. Caches and reports live in the ignored build/ directory.

A separate synchronous Swift Testing host runs native tests: it keeps the main run loop alive after AppKit callbacks and works around the [Swift async-main issue](https://github.com/swiftlang/swift/issues/91716). The runner requires a completed Swift Testing summary; an early exit with code 0 is a failure.

GitHub Actions covers Linux Go race tests, required PostgreSQL 16/17/18 and MySQL 8.0/8.4 with TLS, and macOS arm64 with Swift, native windows, fixtures, application builds, and a temporary Keychain.

Reproduce the separate packaged-archive acceptance run from build 5 to build 6 using Apple XCTest UI Testing:

```sh
./scripts/test-install-update.sh > build/install-update-acceptance.log 2>&1
```

Only this UI runner requires full Xcode and control of a separate application; Docker and both archives with SHA256 files are also required. Any other DBeer instance must be quit normally. The run uses isolated profiles and new test UUIDs in the regular Keychain. **October 18, 2026 — PASS**, five phases and cleanup, actual exit code 0: two-profile import, PostgreSQL/MySQL `SELECT 1` before and after updating, Cancel/Stop and Continue during a long query, UUID/draft/Keychain preservation, and normal shutdown. Native/model matrices are checked separately.

## Internal release

After verification on the owner's machine, run `./scripts/package-release.sh`. It builds the application with the persistent signature, verifies signing, and creates `build/releases/DBeer-<version>-<build>-macos-arm64.zip` and .zip.sha256. The archive includes the changelog and [installation instructions](INSTALL.md). Existing releases are not overwritten, CI signatures are rejected, and nothing is published.

The current version is **0.1.0**, an early internal build. Installation and update acceptance from build 5 to build 6 on the current Mac completed with **PASS**. On October 18, 2026, the owner waived the required second-Mac check. Finder/Gatekeeper and installation on a clean second device have not been verified.

The first v0.2.0 release is planned around execution safety, history, and copying. Result snapshots, SQL folders, data and schema comparison, additional engines, and Windows/Linux remain later stages. MCP comes last among engineering tasks. Public overview sources: [dbeer-landing](https://github.com/nullawhale/dbeer-landing); a feature implemented in the working branch does not imply a newly published archive.
