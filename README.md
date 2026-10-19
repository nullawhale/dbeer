# DBeer

A native SQL client for macOS 14+ on Apple Silicon, built with SwiftUI/AppKit and a bundled Go helper. Supports PostgreSQL 16/17/18 and MySQL 8.0/8.4.

Multiple profiles can run simultaneously. Each SQL tab gets its own connection on first execution and retains its transaction, SET state, and temporary tables until disconnected. The catalog and data tabs use separate sessions. Stop cancels the selected execution; Disconnect closes one profile's sessions.

## Using the application

- **⌘N** creates a PostgreSQL/MySQL profile. Save stores the settings; Save and Connect opens a connection. Passwords live in macOS Keychain, and settings in `~/Library/Application Support/DBeer/connections.json`.
- **⌘T** creates a SQL tab. **⌘Return** executes the selection or the statement at the cursor; **⇧⌘Return** runs the entire script sequentially until the first error or Stop. The editor supports highlighting, line numbers, undo, completion, and navigation to PostgreSQL error positions.
- The tree loads on demand and provides search, Refresh, structure, definitions, Copy Name, and Generate SELECT. Double-click a table to open its first 200 rows. Filtering and sorting run on the server; pagination uses the primary key for stable ordering without automatic COUNT queries.
- Double-clicking an editable cell creates a local change. Insert Row, Delete Selected, Preview SQL, Apply, and Discard manage the batch. Apply uses a separate transaction and checks original rows under locks. A conflict or constraint error rolls back the entire batch. An unknown COMMIT outcome blocks another Apply until the outcome is checked and data is reloaded.
- Arbitrary SQL, views, and tables without a primary key are read-only; MySQL editing requires InnoDB. Computed and unsupported types cannot be edited, with the reason shown in the interface.
- Copy cells, rows, and ranges with **⌘C** or the context menu. Export Loaded saves rows already received. The separate **Run to File** action executes one statement once and publishes the complete file only after successful completion.
- **⌘O**, **⌘S**, and **⇧⌘S** open and save UTF-8 `.sql` files. Drafts are saved after one second of inactivity. History is enabled by default: 1,000 entries retained for 30 days. Query → SQL History can disable or clear history, or clear restored documents. Restoration never connects to a database or executes SQL.
- Connections → Import/Export Connections transfers profiles without passwords or private keys. Import shows a preview, creates new UUIDs, and requires selecting any missing CA while preserving the TLS mode.
- Closing a tab, profile, or the application offers to complete transactions and apply/discard changes; Cancel keeps the window open. DBeer → Settings (**⌘,**) selects System/Light/Dark.

SQL NULL, empty strings, the text NULL, and DEFAULT remain distinct. Column order and duplicate names are preserved. JSON uses metadata and value arrays, exact numbers are strings, and binary values use Base64. CSV uses UTF-8 and a selected NULL marker; a collision requires choosing another marker. Display is limited to 1,000 rows and 8 MiB with an explicit truncation notice; complete Run to File exports have no such limit. Statement timeout is 30 seconds.

The script splitter handles strings, comments, PostgreSQL dollar quoting/BEGIN ATOMIC, and MySQL DELIMITER. Version 1 excludes psql/mysql client commands, COPY streams, LOAD DATA LOCAL, SSH tunnels, and external plugins.

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
./scripts/test.sh
./scripts/test-postgres.sh
./scripts/test-mysql.sh
./scripts/test-tls.sh
```

`test.sh` builds the application and runs Go race tests and Swift Testing in a temporary test Keychain. Database-dependent checks are skipped when no database is available. The test-postgres.sh and test-mysql.sh scripts start isolated Docker databases with random passwords; a missing required database is a failure. To run the complete native scenario with both engines:

```sh
DBEER_QA_OUTPUT_DIR="$PWD/build/qa" ./scripts/test-postgres.sh ./scripts/test-mysql.sh ./scripts/test.sh --require-postgres
```

Select versions with DBEER_TEST_POSTGRES_IMAGE=postgres:18 and DBEER_TEST_MYSQL_IMAGE=mysql:8.0. `test-tls.sh` creates a temporary CA and checks trust, hostname mismatch, and an untrusted certificate against a real PostgreSQL server. MySQL TLS is covered by test-mysql.sh. Containers and keys are removed after verification; diagnostic logs never contain SQL, results, or passwords.

Use DBEER_TEST_DSN for an existing isolated PostgreSQL test database; required mode is `./scripts/test.sh --require-postgres`. For helper-only tests, including Linux, run `./scripts/test-go.sh`. Caches and reports live in the ignored build/ directory.

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
