# DBeer

A native SQL client for macOS 14+ on Apple Silicon, built with SwiftUI/AppKit and a bundled Go helper. Supports PostgreSQL 16/17/18, MySQL 8.0/8.4, and Apache Cassandra 4.1/5.0.

Multiple profiles can run simultaneously. Each SQL tab gets its own connection on first execution and retains its transaction, SET state, and temporary tables until disconnected. The catalog and data tabs use separate sessions. Stop cancels the selected execution; Disconnect closes one profile's sessions.

## Using the application

- **⌘N** creates a PostgreSQL, MySQL, or Cassandra profile. Save stores the settings; Save and Connect opens a connection. Passwords live in macOS Keychain, and settings in `~/Library/Application Support/DBeer/connections.json`.
- **⌘T** creates a SQL tab. **⌘Return** executes the selection or the statement at the cursor; **⇧⌘Return** runs the entire script sequentially until the first error or Stop. The editor supports highlighting, line numbers, undo, completion, and navigation to PostgreSQL error positions. After connecting, user table, view, schema, function, and column names load automatically for completion without expanding the tree; columns respect tables and aliases in the current query. Suggestions appear while typing and with **⌃Space**; profile Refresh updates metadata.
- The tree loads on demand and provides search, Refresh, structure, definitions, Copy Name, and Generate SELECT. Double-click a table to select an existing data view or load its first 200 rows; Open in New Tab creates an independent view. Filtering and sorting run on the server; pagination uses the primary key for stable ordering without automatic COUNT queries.
- Double-clicking an editable cell creates a local change. Insert Row, Delete Selected, Preview SQL, Apply, and Discard manage the batch. Apply uses a separate transaction and checks original rows under locks. A conflict or constraint error rolls back the entire batch. An unknown COMMIT outcome blocks another Apply until the outcome is checked and data is reloaded.
- Arbitrary SQL, views, and tables without a primary key are read-only; MySQL editing requires InnoDB. Computed and unsupported types cannot be edited, with the reason shown in the interface.
- Copy cells, rows, and ranges with **⌘C** or the context menu. Export Loaded saves rows already received. The separate **Run to File** action executes one statement once and publishes the complete file only after successful completion.
- **⌘O**, **⌘S**, and **⇧⌘S** open and save UTF-8 `.sql` files. Workspace changes are saved after one second of inactivity. History is enabled by default: 1,000 entries retained for 30 days. Query → SQL History can disable or clear history, or clear restored documents. Restoration never connects to a database or executes SQL.
- Connections → Import/Export Connections transfers profiles without passwords or private keys. Import shows a preview, creates new UUIDs, and requires selecting any missing or foreign CA while preserving the TLS mode. Portable files accept POSIX, Windows drive and UNC CA hints; foreign hints require explicit local remapping.
- Closing a tab, profile, or the application offers to complete transactions and apply/discard changes; Cancel keeps the window open. DBeer → Settings (**⌘,**) selects System/Lager/Porter.

SQL NULL, empty strings, the text NULL, and DEFAULT remain distinct. Column order and duplicate names are preserved. JSON uses metadata and value arrays, exact numbers are strings, and binary values use Base64. CSV uses UTF-8 and a selected NULL marker; a collision requires choosing another marker. Display is limited to 1,000 rows and 8 MiB with an explicit truncation notice; complete Run to File exports have no such limit. Statement timeout is 30 seconds.

The script splitter handles strings, comments, PostgreSQL dollar quoting/BEGIN ATOMIC, and MySQL DELIMITER. Version 1 excludes psql/mysql client commands, COPY streams, LOAD DATA LOCAL, SSH tunnels, and external plugins.

## Workspace restoration in the working branch

DBeer restores mixed SQL and table/view tabs in their saved order, with the
selected tab, titles, SQL text and original connection bindings. Table tabs keep
their schema/table reference, page, server filters and sort order. They initially
show this context with an explicit **Load Data** action. SQL tabs remain
disconnected until Run; table tabs remain disconnected until Load Data or Refresh.
A missing connection stays unavailable until you explicitly choose a replacement.
PostgreSQL/MySQL reopen the saved page on loading; Cassandra starts from the first
page because its server cursors cannot survive a session restart.

Sessions, transactions, running operations, results, cursor tokens and pending
grid changes are excluded. A recovered tab cannot resume an old Apply or repeat
SQL automatically. Text and browsing changes autosave without fetching table data.

SQL file bindings retain the last accepted file-content fingerprint and the draft
text independently. Local file observation resumes after restoration; clean
buffers adopt external changes, while changed drafts retain both versions for
review. Missing or unreadable files keep their editable drafts. Bindings without
a known fingerprint require **Save As**. No file operation connects to a database.

Workspace storage advances to v6, with exact private backups before migrating
v0/v1/v2/v3/v4/v5. Folder attachments and shared file identities are saved alongside
the views; each view retains its own connection binding. Existing history,
favorites and retention preferences are preserved.
Unknown document kinds, malformed state and future workspace versions are left
unchanged. These changes require rebuilding the native app and are not part of
the existing build 8 archive.

**File → Reopen Closed Tab** (**⇧⌘T**) returns the most recently closed SQL or
table/view tab, including when no tabs remain open. Up to 20 successfully closed
tabs are kept in memory for the current application run. Repeated reopening
returns them in reverse closing order, at their former position where possible,
and selects each reopened tab. Cancelled or rejected closes are excluded.

Reopened tabs have fresh document identities and no session, transaction, result,
cursor or pending edits. Their SQL, connection reference, file binding and table
browsing settings are restored without reconnecting or executing SQL. Reopening
a view of an already open file uses its current shared buffer. Run or Load Data
opens a new session explicitly. Missing connections
require choosing a replacement. Rebind or clear the shortcut in **Settings →
Shortcuts**. The closed-tab list is cleared on application exit and by a successful
**Clear Drafts** action; it is never written to workspace storage.

## SQL folders and files in the working branch

**Attach Folder…** in the SQL Folders sidebar adds an existing local folder.
Directories load as expanded and show `.sql` files; search matches names,
contents or both without opening database sessions. Search skips symlinks,
`.git`, build products and dependency directories, with explicit notices when
scan limits or unreadable files make results incomplete. Up to 32 folders can
be attached, and detaching a folder keeps its open files.

Opening the same path selects its existing view. **Open in New Tab** creates a
view of the same editable text with its own selection, connection and SQL
session. Edits synchronize across these views. Files preserve exact UTF-8 bytes,
including an existing BOM and line endings. Separate hard-link paths remain
separate file bindings because an atomic save can make their contents diverge.

DBeer observes edits, renames, deletion and atomic replacements such as Git
checkout. A clean buffer follows the disk version. A dirty buffer keeps the
local text and external version for **Compare Versions…**. Choose **Use External
Version**, explicitly **Replace External Version**, or **Keep Local Copy…** to
save the current view to another path. Other views keep their original binding
when one view uses Save As. A deleted file leaves an editable draft for Save As.

Every save checks the current disk version immediately before publication.
Replacement requires the exact version reviewed; a changed or newly appeared
destination stops the save. A failed race recovery reports any preserved
external file and offers to open its bytes as a separate draft. These references
survive workspace restoration. Cancelling or failing a save keeps the draft.

## Shared SQL library in the working branch

Choose **Library** beside **Files** in the SQL sidebar to index an existing
`.sql` file. **Add to SQL Library…** is also available on file rows and in an
open file's details. Add tags and an optional logical folder, then choose its
scope: all connections, one connection, or a named connection group. Search and
connection/folder/tag filters find indexed files. Library folders organize
references without moving files. Removing an entry leaves its file on disk.

**Manage connection groups** creates simple named groups of saved connections.
The index stores file references and metadata, including opaque connection IDs;
the actual SQL stays in its original file. There is no cloud synchronization.
Missing or deleted groups and connections remain unavailable until explicitly
replaced; they never turn a scoped query into a global one.

Opening a library entry creates a fresh view of its shared file buffer with no
connection selected. Choose a specific connection in that view and review its
environment and readonly policy before Run, Run Script or Run to File. Other
views retain independent connections, sessions and transactions, so the same
file can be used in development and production without copying the query.
Scope is checked again after asynchronous connection and confirmation work and
before each script statement. A changed scope stops pending execution.

Edits and safe saves use the same file model as SQL folders. Observed file
renames update the index reference; Save As to another path detaches only that
view. Workspace v6 restores the index, groups and view bindings disconnected,
with an exact private backup before migrating v5. Restoring or editing library
metadata does not connect or execute SQL.

## Independent table views in the working branch

**Open Data** selects an already open view of that table without resetting its
filters, page or pending changes. **Open in New Tab**, available in the catalog
and a table tab's context menu, opens a separate view with its own session and
clean browsing settings. Opening one view does not copy another view's edits.

Select one loaded row and use **Related Rows** to follow a PostgreSQL or MySQL
foreign key in the current view or a new tab. Composite keys use every mapped
column in constraint order. Exact numeric text, empty strings and binary values
retain their transport representation. A NULL or unresolved DEFAULT cannot
identify a related row. Incomplete metadata and unavailable or denied targets
show an explicit message.

**Back** and **Forward** restore a view's table, page, filters and sorting.
Navigation in the current view with pending edits offers the existing
Apply/Discard/Cancel review; Apply still previews and confirms the generated
changes. Opening related rows in a new tab uses confirmed source values and
preserves unrelated pending edits; changed key values require Apply or Discard
first. A failed relationship load preserves the source view. Other table views
keep their own context and drafts. Autosave keeps the last confirmed location
while a transition loads and excludes temporary related tabs until they load
successfully. Navigation history stays in memory; workspace restoration saves the
current location and remains disconnected until explicit Load Data. Cassandra
supports independent views but has no foreign keys.

## Result copying in the working branch

Copy cells, rows or ranges as TSV, CSV, JSON, Markdown or SQL INSERT. Ordinary
**⌘C** defaults to TSV without headers; **Settings → Copying** changes the default
format and whether TSV, CSV and Markdown include column headers. Inspection
grids without an INSERT target chooser keep TSV when SQL INSERT is the default.
The context menu provides every format. The Edit menu also has direct **Copy as
JSON**, **Copy as Markdown** and **Copy as SQL INSERT** commands, initially bound
to **⌥⌘J**, **⌥⌘M** and **⌥⌘I**. Rebind or clear them in **Settings → Shortcuts**.
These commands act only on a focused result grid with a selection; SQL and cell
editors retain their native text shortcuts.

Every format preserves the same internal typed clipboard payload. TSV and CSV
use unquoted `\N` for NULL, `<DEFAULT>` for DEFAULT, and `<BINARY:base64>` for
binary. Empty strings and text matching these markers are quoted; quotes and
embedded line breaks are escaped. JSON keeps column metadata and typed value
arrays, including duplicate names and exact numeric strings. Markdown text cells
use JSON string notation with escaped line breaks and Markdown entities; without
headers, its required header row is blank.

SQL INSERT asks for the PostgreSQL or MySQL target dialect, optional schema or
database, table and target column names. Rename duplicate source column names in
this mapping. The helper formats loaded values offline without connecting or
executing SQL. Text and exact numbers become string literals for the destination
table to interpret; NULL, DEFAULT and binary remain distinct. MySQL text literals
are hexadecimal UTF-8 expressions independent of SQL mode. PostgreSQL rejects
text containing a zero byte. INSERT copy is limited to 1,000 rows, 4,096 columns,
100,000 cells and 8 MiB of input or generated SQL. Copying never fetches additional
rows or reruns a query. Delayed work preserves a newer copy or external clipboard
change. These changes require rebuilding the matching app and helper and are not
included in the existing build 8 archive.

## SQL history in the working branch

Query → SQL History records each executed statement once after it finishes,
including individual script statements. Skipped statements and commands rejected
before execution do not create entries. Entries distinguish completed, failed,
cancelled, timed-out and unknown outcomes, with start and finish times, duration,
SQLSTATE when reported, and a safe error description.

Loaded, affected and exported row counts are shown separately. Missing counts
remain unavailable rather than becoming zero; truncation and partial counts are
explicit, and loaded rows do not imply the complete result size. Each entry keeps
the profile name, engine, endpoint, database or keyspace, user and execution policy
from the time the statement started, even after the profile is renamed or deleted.
Credentials, SSH settings, certificate paths and result values are excluded.

Search matches fragments anywhere in the complete SQL text, including long
statements and Unicode. By default it searches all connections. Combine the
search with connection, period and outcome filters; custom dates include both
selected calendar days, using the execution's finish date. Older entries with
unavailable outcome details are included under **Unknown / unavailable**.

**Open in SQL Tab** creates a new disconnected draft with the original SQL and
never executes it. If its connection has been deleted or is unavailable, choose
a connection in the new tab before running the SQL.

Mark an execution as a favorite to keep it outside automatic history limits.
**Favorites only** combines with the SQL search and the other filters.
**Storage Settings** controls the maximum ordinary entries (1–100,000) and their
retention period (1–3,650 days); defaults remain 1,000 entries and 30 days.
Applying settings trims ordinary entries immediately. Removing a favorite star
also makes that entry subject to the current limits.

Delete individual entries, or clear the current matches or the complete history.
Clear confirmations show how many ordinary and favorite entries are selected;
favorites are preserved unless explicitly included. The selection is captured
when the confirmation opens, so new executions are kept. Disabling recording
stops new history entries and keeps existing history and favorites.

History uses versioned workspace storage, currently v6. Existing v0/v1/v2/v3/v4/v5 files
receive exact backups before migration; older entries retain their original
outcome text and show unavailable execution details rather than inferred values. These working-branch changes are
not included in the existing build 8 archive.

## SSH tunnels in the working branch

Enable **SSH Tunnel** in a connection profile and enter the bastion host, SSH
port and SSH user. Choose **SSH Agent**, **Private Key**, or **Password**. Select
the local private key file for key authentication, including encrypted keys.
The database host and port describe the destination as seen from the bastion;
for a database running on that server, the database host can be `127.0.0.1`.

SSH passwords and private-key passphrases can be remembered separately in macOS
Keychain. Private keys remain in their selected files. A first connection asks
you to verify the SSH server's SHA256 fingerprint before trusting it. A changed
or revoked key blocks ordinary connection; review a replacement independently.
Trust records stay local and are excluded from profile transfer.
Accepted DBeer keys are scoped to the profile. Existing user/system
`known_hosts` records are consulted read-only; conflicting or revoked records
must be reviewed there. DBeer-owned keys can be replaced only through the
separate replacement confirmation. SSH host certificate authorities are not
supported in this first connection mode.

The helper manages system OpenSSH and shares a tunnel among a profile's active
sessions. Each tab keeps its own database session and transaction state. Closing
one tab leaves other sessions connected; profile disconnect releases its
tunnel. PostgreSQL and MySQL cancellation connections also use SSH. A broken
tunnel invalidates its sessions, and DBeer never automatically repeats SQL or
an Apply operation after a transport failure.

Database TLS remains independent of SSH. `verify-full` checks the original
database identity, and its trusted CA settings continue to apply. PostgreSQL
and MySQL destination names resolve from the bastion. For Cassandra, enter
numeric IP contact points: the driver resolves names before its transport hook.
Discovered node connections also go through SSH, and every advertised node
address must be reachable from the bastion.
Use a stable database endpoint for cancellation: a hostname resolving to
different servers on successive connections can route a cancellation connection
to another server. Failed recovery closes the affected session and preserves
uncertain outcomes without repeating the query.

Portable profiles retain SSH settings while excluding passwords, passphrases,
private keys and trust decisions. Imported key profiles require selecting a local
private key. Saving, importing or restoring profiles does not start SSH.

The first delivery supports one explicitly configured bastion. SSH configuration
aliases, `Include`, `ProxyJump`, `ProxyCommand`, multiple hops and interactive MFA
are outside this delivery. This working-branch feature is not part of the
existing build 8 archive. Rebuild the native app with its matching protocol v5
helper to use it; Windows/Linux GPUI SSH support is deferred.

## Next release changes

The Query menu, execution buttons, and keyboard share a command registry for the active document. Default shortcuts are preserved: **⌘Return** runs the selection or current statement, and **⇧⌘Return** runs the entire script. The Run fragment is highlighted inside the editor and updates with cursor or selection changes. A cursor immediately after `;` still belongs to the completed statement.

DBeer → Settings → Shortcuts records custom Run, Run Script, Stop, Run to File and Copy as shortcuts, clears assignments, and restores defaults. Assignments persist between launches; conflicts and protected editing shortcuts are rejected. Commands respect focus and the active tab; settings windows, dialogs, and typing in other text fields never launch SQL.

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

## Windows/Linux GPUI client — contributions welcome

Contributions to the experimental Windows and Linux clients are welcome.
Current feature development and verification target macOS only. Windows/Linux
clients are outside the v0.2.0 roadmap and release scope, with no release date
announced. The existing Rust/GPUI prototype and the following instructions
provide a starting point for contributors; platform development, paired builds,
protocol compatibility and native acceptance need contributor ownership.

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

To reclaim local GPUI build space, stop GPUI builds and test runs, then preview
and apply cleanup (Python 3.9+):

```sh
./scripts/clean-gpui.sh           # preview only; --verbose lists every path
./scripts/clean-gpui.sh --apply   # remove the selected outputs
```

Cleanup is limited to `build/gpui/`, including nested review build directories.
It removes compiled binaries and recognized Rust/Swift/Go/Python caches while
retaining reports, logs, screenshots, document and archive formats even inside
output directories. Candidates, release/archive directories, source snapshots
outside caches, fixture directories, installed toolchains, and the PowerShell
runtime are kept intact.
Some compiler JSON metadata and dependency documentation may remain to preserve
possible evidence. Symlinks are retained and never followed. Native Swift
outputs, shared `build/.cache/` caches, and `build/releases/` are outside its
scope. Applied runs record their selected paths in
`build/maintenance/gpui-cleanup-*.json`; subsequent runs can reclaim new outputs.

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

The 0.2.0 prerelease includes execution safety, grid copying and editing, contextual SQL completion, themes, and native Cassandra support. Result snapshots, SQL folders, and data and schema comparison remain later stages. Windows/Linux contributions are welcome outside the release roadmap. MCP comes last among planned engineering tasks and does not depend on Windows/Linux clients. Public overview sources: [dbeer-landing](https://github.com/nullawhale/dbeer-landing); a feature implemented in the working branch does not imply a newly published archive.

## License

DBeer is licensed under the [GNU General Public License, version 3 only](LICENSE)
(`SPDX-License-Identifier: GPL-3.0-only`).

DBeer is distributed without any warranty, including the implied warranties of
merchantability or fitness for a particular purpose. See [LICENSE](LICENSE) for
the full terms.

Third-party code and resources retain their respective licenses and notices.
