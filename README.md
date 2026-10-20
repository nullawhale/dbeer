# DBeer

A native SQL client for macOS 14+ on Apple Silicon, built with SwiftUI/AppKit and a bundled Go helper. Supports PostgreSQL 16/17/18, MySQL 8.0/8.4, and Apache Cassandra 4.1/5.0.

Multiple profiles can run simultaneously. Each SQL tab gets its own connection on first execution and retains its transaction, SET state, and temporary tables until disconnected. The catalog and data tabs use separate sessions. Stop cancels the selected execution; Disconnect closes one profile's sessions.

## Using the application

- **⌘N** creates a PostgreSQL, MySQL, or Cassandra profile. Save stores the settings; Save and Connect opens a connection. Passwords live in macOS Keychain, and settings in `~/Library/Application Support/DBeer/connections.json`.
- **⌘T** creates a SQL tab. **⌘Return** executes the selection or the statement at the cursor; **⇧⌘Return** runs the entire script sequentially until the first error or Stop. The editor supports highlighting, line numbers, undo, completion, and navigation to PostgreSQL error positions. After connecting, user table, view, schema, function, and column names load automatically for completion without expanding the tree; columns respect tables and aliases in the current query. Suggestions appear while typing and with **⌃Space**; profile Refresh updates metadata.
- The tree loads on demand and provides search, Refresh, structure, definitions, Copy Name, and Generate SELECT. Double-click a table to open its first 200 rows. Filtering and sorting run on the server; pagination uses the primary key for stable ordering without automatic COUNT queries.
- Double-clicking an editable cell creates a local change. Insert Row, Delete Selected, Preview SQL, Apply, and Discard manage the batch. Apply uses a separate transaction and checks original rows under locks. A conflict or constraint error rolls back the entire batch. An unknown COMMIT outcome blocks another Apply until the outcome is checked and data is reloaded.
- Arbitrary SQL, views, and tables without a primary key are read-only; MySQL editing requires InnoDB. Computed and unsupported types cannot be edited, with the reason shown in the interface.
- Copy cells, rows, and ranges with **⌘C** or the context menu. Export Loaded saves rows already received. The separate **Run to File** action executes one statement once and publishes the complete file only after successful completion.
- **⌘O**, **⌘S**, and **⇧⌘S** open and save UTF-8 `.sql` files. Drafts are saved after one second of inactivity. History is enabled by default: 1,000 entries retained for 30 days. Query → SQL History can disable or clear history, or clear restored documents. Restoration never connects to a database or executes SQL.
- Connections → Import/Export Connections transfers profiles without passwords or private keys. Import shows a preview, creates new UUIDs, and requires selecting any missing or foreign CA while preserving the TLS mode. Portable files accept POSIX, Windows drive and UNC CA hints; foreign hints require explicit local remapping.
- Closing a tab, profile, or the application offers to complete transactions and apply/discard changes; Cancel keeps the window open. DBeer → Settings (**⌘,**) selects System/Lager/Porter.

SQL NULL, empty strings, the text NULL, and DEFAULT remain distinct. Column order and duplicate names are preserved. JSON uses metadata and value arrays, exact numbers are strings, and binary values use Base64. CSV uses UTF-8 and a selected NULL marker; a collision requires choosing another marker. Display is limited to 1,000 rows and 8 MiB with an explicit truncation notice; complete Run to File exports have no such limit. Statement timeout is 30 seconds.

The script splitter handles strings, comments, PostgreSQL dollar quoting/BEGIN ATOMIC, and MySQL DELIMITER. Version 1 excludes psql/mysql client commands, COPY streams, LOAD DATA LOCAL, SSH tunnels, and external plugins.

## Next release changes

The Query menu, execution buttons, and keyboard share a command registry for the active document. Default shortcuts are preserved: **⌘Return** runs the selection or current statement, and **⇧⌘Return** runs the entire script. The Run fragment is highlighted inside the editor and updates with cursor or selection changes. A cursor immediately after `;` still belongs to the completed statement.

DBeer → Settings → Shortcuts records custom Run, Run Script, Stop, and Run to File shortcuts, clears assignments, and restores defaults. Assignments persist between launches; conflicts and protected editing shortcuts are rejected. Commands respect focus and the active tab; settings windows, dialogs, and typing in other text fields never launch SQL.

The working branch adds unset, development, staging, and production environments and a separate readonly setting. These changes are not yet included in the published 0.1.0 archive. The environment appears as text and color in the profile, SQL tab, and confirmation. The profile editor first routes open sessions through normal transaction completion; Cancel preserves the previous context.

Execute, scripts, Run to File, and Apply share one helper policy: destructive and unrecognized commands require confirmation in every environment, and production confirms every write. Multi-statement runs, including editor selections, show the entire batch before the first statement. Approval is tied to the exact SQL or typed changes and the current session; edits, errors, Stop, and reconnection prevent reusing any remaining approval.

Readonly rejects writes and unknown constructs before reaching the adapter and disables grid editing. PostgreSQL/MySQL also enable server-side read-only mode; Cassandra uses local CQL assessment and relies on server role permissions for an enforced write prohibition. The classifier structurally accounts for strings, comments, CTEs, and dialect; unsupported syntax and unknown functions are not classified as reads. Use a separate database user with restricted permissions for a strict write prohibition: server modes have exceptions, including temporary tables, and do not replace access controls. See [PostgreSQL SET TRANSACTION](https://www.postgresql.org/docs/18/sql-set-transaction.html) and [MySQL SET TRANSACTION](https://dev.mysql.com/doc/refman/8.4/en/set-transaction.html).

Assessment follows SQL structure and a limited list of built-in functions for each engine. Production confirmation applies to operations classified as writes or unknown commands. Views, custom overloads of built-in names, casts, and operators can hide side effects; the client does not fully resolve server objects and types. Server-side readonly blocks ordinary writes to permanent tables, but database permissions must restrict server-allowed temporary-table exceptions and function execution.

## SQL editor in the next release

Completion search matches parts of a name: `oi` finds `order_items` and `OrderItems`, while `items` matches the second word. Minor typos are tolerated: `ordres` finds `orders`. Among candidates of comparable match quality, columns in the current query and CTEs rank above general functions and keywords. Exact names take priority, and typo corrections follow ordinary matches. Typo correction is disabled for queries of one or two letters.

Matching parts of each name are highlighted with bold text and theme colors: for `oi`, the `o` and `i` in `order_items` are highlighted. Highlighting follows the actual match, including typo alignment, and updates when the selected row or theme changes.

The editor in the working branch has increased internal padding and line spacing, current-line highlighting, and line numbers with an active-line indicator. Syntax, cursor, and selection colors adapt to light and dark themes; execution highlighting is preserved.

A green checkmark beside the first line number marks a successfully executed SQL statement. Scripts mark every completed statement; errors, cancellation, and unknown outcomes are not marked. Editing text, changing the connection profile, or starting another run clears previous marks.

The bundled local language server suggests PostgreSQL/MySQL keywords and functions, tables, columns, and aliases according to the current SQL clause. It understands CTEs and subqueries, projected column aliases and stars, correlated queries, and LATERAL sources. ORDER BY/GROUP BY include SELECT aliases; MySQL also offers them in HAVING. Ambiguous columns are qualified with their source alias. After JOIN, foreign keys provide a table, a free alias, and the ON condition; after an existing ON, they provide the condition alone. Composite keys use AND, and reverse/self joins are supported. Completion appears while typing, including after clause whitespace; **⌃Space** invokes it explicitly. **↑/↓** selects an item, **Tab/Return** inserts it, and **Escape** closes the popup. Standard Undo reverses insertion. Switching profiles or dialects updates the context; responses for earlier text are discarded.

Function signatures appear above the caret while typing inside a call, with parameter names/types, the return type, and the current argument highlighted. Nested calls, PostgreSQL named arguments, defaults, variadic arguments, and overloads are supported; moving the caret updates the active parameter. The panel preserves editor focus and Undo, follows the editor theme, and closes with **Escape**. Common built-ins are available offline; user-function signatures load with the connected profile metadata and refresh through profile Refresh. Overloads are ranked by arity and argument names, without inferring expression types; polymorphic return types remain descriptive.

**Settings → Appearance** separates the application appearance from the SQL editor scheme. The application supports System, Lager (light), Porter (dark), and every scheme in the shared library: DBeer Light/Dark, VS Code Light+/Dark+, Solarized Light/Dark, JetBrains Light, Darcula, and imported schemes. Application and editor choices are saved independently: for example, the application can use Solarized Light while the editor uses Darcula. Application colors apply to backgrounds, the sidebar, tabs, controls, and result tables; the Dock icon follows the scheme's light or dark appearance. In **Follow App Appearance** mode, the editor inherits the application scheme. The preview and open SQL tabs update immediately while preserving text, cursor position, scrolling, and Undo.

**Import Theme…** accepts standard VS Code `.json`/`.jsonc`, TextMate `.tmTheme`, and JetBrains `.icls` color schemes. Export a JetBrains scheme through **Editor → Color Scheme → Export → IntelliJ IDEA color scheme (.icls)**. Supported settings include editor, selection, cursor, and line-number colors, basic SQL token classes, and available text styles. JetBrains UI `.theme.json` files, JAR plugins, TextMate grammars, and semantic-token rules are not loaded. `.icls` supports Default/Darcula inheritance; an unknown parent produces a clear error.

JSONC can contain comments and trailing commas. Local `include` files and `tokenColors` references to `.tmTheme` resolve within the selected scheme's directory and its subdirectories. Import saves a standalone local copy in `~/Library/Application Support/DBeer/EditorThemes/themes.json`; source files are no longer needed. Available VS Code UI colors style the application, with missing colors derived from the editor palette for readability. **Remove Theme** removes only imported schemes and returns the editor to automatic selection; if the scheme is selected for the application, it returns to the previous System/Lager/Porter appearance. Built-in schemes cannot be removed. Importing and switching themes never executes SQL or connects to a database. Format references: [VS Code](https://code.visualstudio.com/api/extension-guides/color-theme), [TextMate](https://www.sublimetext.com/docs/color_schemes_tmtheme.html), [JetBrains](https://www.jetbrains.com/help/idea/configuring-colors-and-fonts.html).

After an explicit connection, a separate service session loads table, view, function, column, foreign-key, and function-signature metadata in background batches; tree expansion is optional. Profile Refresh replaces stale metadata. The completion engine never connects to a database or executes SQL; restored tabs remain disconnected. All SQL completion rules live in [`helper/internal/sqlcomplete`](helper/internal/sqlcomplete/README.md), while LSP transport and native presentation remain separate. Complex expression outputs need explicit aliases; completion does not infer types or foreign keys through arbitrary derived expressions. The helper ships with the application and needs no third-party tools. Diagnostics identify unclosed strings, comments, and parentheses; they do not replace server-side SQL validation. If the language server is unavailable, normal editing, execution, and basic completion remain available. These changes are not yet included in the published 0.1.0 archive.

## Apache Cassandra

Cassandra support currently targets the native macOS client and shared Go helper.
Enter one or more contact points, port `9042`, an optional default keyspace and
local datacenter. Authentication may be omitted for an unsecured development
cluster; passwords for authenticated profiles stay in Keychain. TLS verifies the
certificate and hostname by default. Each SQL tab owns a separate driver session
and its own `USE` keyspace. `LOCAL_QUORUM` is the default consistency level; the
selected consistency is shown in the workspace and affects availability and the
values observed during replica failures.

For a connected profile, **Cluster Nodes** in the sidebar or profile context menu
shows discovered node addresses, driver UP/DOWN status, datacenters, racks and
host IDs. Refresh reads the service session's latest driver observations without
probing nodes or running CQL. The snapshot time is shown; this is the client's
view of connectivity, not a cluster-wide health assessment.

The editor runs CQL statements and scripts, retaining `BEGIN ... BATCH ... APPLY
BATCH` as one statement. Scripts stop at the first error and keep completed
results. The catalog includes keyspaces, tables, materialized views, indexes and
user-defined types, with partition keys, clustering columns and static columns.
Table browsing uses sequential opaque cursors; changing query conditions or
reconnecting resets navigation. Generated queries never silently add `ALLOW
FILTERING`, global sorting or automatic row counts. Cassandra requires queries
that fit the table's partition/clustering keys and available indexes.
Generated filters support scalar values within those key/index rules. Collection,
tuple, UDT and vector predicates require explicit CQL. Generated CREATE statements
are partial definitions: inspect TTL/options, indexes and grants separately;
they are not schema backups. A successful DDL acknowledgement does not guarantee
that an unavailable peer has received the schema change.

Cassandra grid editing supports conditional updates to multiple existing rows per
Apply. Pinned colored labels (`P1`, `P2`, etc.) identify partitions in the loaded
page; hover over a label to inspect its partition-key values, or click it to select
all loaded rows in that partition, including rows outside the visible area. These labels are
presentation only and are not copied or exported. The status beside Apply counts
partitions in pending edits, independently of row selection. Edits spanning
partitions or missing a complete partition key disable Apply.
Changes use the usual preview and confirmation workflow. Every edited row must
belong to the same complete partition key. Multi-row Apply sends one conditional
CQL batch: all original-value checks must match for any row to be updated. A
known rejection saves no rows and retains every pending edit. Requests spanning
different partitions are rejected before writing, since Cassandra does not offer
cross-partition conditional transactions. A timeout or lost acknowledgement can
leave the outcome of the whole batch unknown; DBeer blocks further editing until
the data is reviewed and reloaded and never automatically retries the batch. Scalar tables are
supported; primary keys and static columns are read only. Tables containing
counters, durations, collections, tuples, UDTs or vectors require explicit CQL,
as do inserts, deletes and rows with only NULL regular values. Apply checks the
original non-key values and rejects a changed or deleted row. Updated cells use
the table's default TTL; an existing cell TTL is not preserved. SQL transaction
controls remain unavailable. CQL `UPDATE`
is an upsert, batches do not offer interactive SQL transactions, and Stop cannot
undo an already sent write. A write timeout or lost response may leave an unknown
outcome; DBeer reports this explicitly and does not repeat the command. A known
server acknowledgement remains known if result decoding, display delivery or
export publication subsequently fails; the remaining script is stopped. Readonly
is a local client restriction for Cassandra, so use a restricted server role
when write prevention must be enforced by the database.
Unqualified function calls can resolve to keyspace UDF overloads, so ambiguous
calls require confirmation and are blocked by local readonly. Completion uses
`system.` for ordinary native functions; `COUNT(*)`, `TTL`, `WRITETIME` and
`CAST(... AS ...)` retain their dedicated CQL selector syntax.

Large interactive results stop requesting additional pages at display limits.
Run to File intentionally reads all pages with bounded streaming. Exact
`decimal`/`varint` values remain strings, blobs use Base64, and collections,
tuples, UDTs and vectors use CQL value notation. NULL, empty text and the text
`NULL` remain distinct. ScyllaDB, cloud services and other compatible products
have not been certified. TTL, counters, static columns and collections need
separate preview/apply rules before future grid editing can be enabled.

## Building

Requires macOS 14+ on Apple Silicon, Swift 6 with Swift Testing, and the Go version specified in `helper/go.mod`. Verified locally with Swift 6.4 and Go 1.27.1. Full Xcode is not required for application builds or component tests. Go downloads dependencies on the first build.

```sh
./scripts/build-app.sh
open build/DBeer.app
```

The output is `build/DBeer.app`, using the release configuration by default. For debug, run `CONFIGURATION=debug ./scripts/build-app.sh`. The packaged application includes the helper; Go, Swift, and source code are not needed to run it.

VERSION and BUILD_NUMBER define the application version and build number. The application and helper use a persistent **Apple Development** certificate from the login Keychain. If multiple certificates are available, set DBEER_SIGNING_IDENTITY to the SHA-1 shown by `security find-identity -v -p codesigning`. Use DBEER_SIGNING_KEYCHAIN for a different Keychain. The script never falls back to ad hoc signing. macOS may request codesign access to the key on first use.

Application icons are in `macos/Resources`; after editing SVG files, run `./scripts/build-icon.sh` to regenerate PNG/ICNS files. CI uses a separate temporary signing certificate and marks builds with DBeerBuildKind=ci; these builds are not used as team updates.

## Windows/Linux GPUI client (experimental)

Current feature development and verification target macOS only. Windows/Linux
work and GPUI protocol compatibility are deferred; the following instructions
remain reference material for that future work.

The [GPUI Kit client](prototypes/gpui/README.md) is the experimental Windows/Linux
frontend, using the existing Go helper for PostgreSQL and MySQL. CI builds native
Windows x64 and Ubuntu 24.04 x64 candidates with an exact matching helper and
isolated unmarked headless tests. The supported acceptance targets are Windows 11
x64 and Ubuntu 24.04 x64 Wayland/X11; their native desktop gates remain pending.
Native wrappers compile the pair by default; `--test --package` / `-Test -Package`
also verifies and prepares immutable unsigned candidates under `build/gpui/candidates/`.
Fresh startup opens empty SQL without demo connections. Product display identity
is DBeer / `app.dbeer.DBeer`, while original private GPUI data and credential
namespaces stay unchanged. See [native build details](prototypes/gpui/BUILD_INTEGRATION.md)
and [installation/update instructions](prototypes/gpui/packaging/INSTALL.md).

The macOS product remains the SwiftUI/AppKit application, built with
`./scripts/build-app.sh`; its CI, packaging, profiles, and Keychain service stay
independent. For local GPUI development on Mac, use `./scripts/gpui-prototype.sh`
or `./scripts/build-gpui-app.sh` (macOS 15+, Rust, and Go). GPUI uses separate
profiles and the operating system's credential store on each platform. See the
client guide for platform builds, dependencies, checks, and limitations.

## Verification

```sh
./scripts/test.sh --filter SQLScriptParserTests
./scripts/test.sh --filter 'SQLEditorTests/executionHighlight'
./scripts/test.sh --all
./scripts/test-postgres.sh
./scripts/test-mysql.sh
./scripts/test-tls.sh
./scripts/test-cassandra.sh  # Cassandra 4.1/5.0, plain and authentication/TLS
./scripts/test-cassandra.sh --version 5.0 --mode tls --multi-node  # replica failure profile
```

For small changes, select affected Swift suites or methods with `--filter` (a regular expression; the flag can be repeated). This mode skips Go tests. Theme and UI checks run only when selected by the filter. A complete Go race and Swift Testing run requires explicit `--all`; use it for cross-cutting changes and final verification. Without a mode, the script prints usage and exits without building or testing. CI runs the full suite.

Both `test.sh` modes build the application and run Swift Testing in a temporary test Keychain. An empty test selection is a failure. Database-dependent checks are skipped when no database is available. The test-postgres.sh and test-mysql.sh scripts start isolated Docker databases with random passwords; a missing required database is a failure. To run the complete native scenario with both engines:

```sh
DBEER_QA_OUTPUT_DIR="$PWD/build/qa" ./scripts/test-postgres.sh ./scripts/test-mysql.sh ./scripts/test.sh --all --require-postgres
```

Select versions with DBEER_TEST_POSTGRES_IMAGE=postgres:18 and DBEER_TEST_MYSQL_IMAGE=mysql:8.0. `test-tls.sh` creates a temporary CA and checks trust, hostname mismatch, and an untrusted certificate against a real PostgreSQL server. MySQL TLS is covered by test-mysql.sh. Containers and keys are removed after verification; diagnostic logs never contain SQL, results, or passwords. Cassandra checks run both target versions in plain and authenticated TLS modes; `--udf` enables a harmless overloaded-function safety regression in the isolated fixture. Structured per-test evidence is retained under `build/cassandra/`; missing or skipped required live scenarios fail the runner. The optional three-node profile runs schema checks while all replicas are healthy, then stops one node and verifies quorum availability and `ALL` failure against an existing schema.

Use DBEER_TEST_DSN for an existing isolated PostgreSQL test database; add `--require-postgres` to the selected mode to require it. For helper-only tests, including Linux, run `./scripts/test-go.sh`. Caches and reports live in the ignored build/ directory.

A separate synchronous Swift Testing host runs native tests: it keeps the main run loop alive after AppKit callbacks and works around the [Swift async-main issue](https://github.com/swiftlang/swift/issues/91716). The runner requires a completed Swift Testing summary; an early exit with code 0 is a failure.

GitHub Actions covers Linux Go race tests, required PostgreSQL 16/17/18 and MySQL 8.0/8.4 with TLS, and macOS arm64 with Swift, native windows, fixtures, application builds, and a temporary Keychain.

Reproduce the separate packaged-archive acceptance run from build 5 to build 6 using Apple XCTest UI Testing:

```sh
./scripts/test-install-update.sh > build/install-update-acceptance.log 2>&1
```

Only this UI runner requires full Xcode and control of a separate application; Docker and both archives with SHA256 files are also required. Any other DBeer instance must be quit normally. The run uses isolated profiles and new test UUIDs in the regular Keychain. **October 18, 2026 — PASS**, five phases and cleanup, actual exit code 0: two-profile import, PostgreSQL/MySQL `SELECT 1` before and after updating, Cancel/Stop and Continue during a long query, UUID/draft/Keychain preservation, and normal shutdown. Native/model matrices are checked separately.

## Internal release

After verification on the owner's machine, run `./scripts/package-release.sh`. It builds the application with the persistent signature, verifies signing, and creates `build/releases/DBeer-<version>-<build>-macos-arm64.zip` and .zip.sha256. The archive includes the [license](LICENSE), changelog and [installation instructions](INSTALL.md). Existing releases are not overwritten, CI signatures are rejected, and nothing is published.

The current local macOS prerelease is **0.2.0, build 8**. It uses the native SwiftUI/AppKit client and bundled Go helper; Windows/Linux GPUI candidates are outside this release. Packaging creates local files and does not publish a GitHub release.

The previous **0.1.0** internal release passed installation and update acceptance from build 5 to build 6 on the current Mac. On October 18, 2026, the owner waived that release's required second-Mac check. This evidence does not cover the 0.2.0 prerelease. Finder/Gatekeeper and installation on a clean second device have not been verified.

The 0.2.0 prerelease includes execution safety, grid copying and editing, contextual SQL completion, themes, and native Cassandra support. Result snapshots, SQL folders, data and schema comparison, and Windows/Linux remain later stages. MCP comes last among engineering tasks. Public overview sources: [dbeer-landing](https://github.com/nullawhale/dbeer-landing); a feature implemented in the working branch does not imply a newly published archive.

## License

DBeer is licensed under the [GNU General Public License, version 3 only](LICENSE)
(`SPDX-License-Identifier: GPL-3.0-only`).

DBeer is distributed without any warranty, including the implied warranties of
merchantability or fitness for a particular purpose. See [LICENSE](LICENSE) for
the full terms.

Third-party code and resources retain their respective licenses and notices.
