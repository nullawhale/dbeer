# DBeer

A native database client for macOS 14+ on Apple Silicon, built with SwiftUI/AppKit and a bundled Go helper. Supports PostgreSQL 16/17/18, MySQL 8.0/8.4, Apache Cassandra 4.1/5.0, and MongoDB 8.0.

The current macOS release is **0.3.0, build 12**. Download the signed application
ZIP and SHA256 from [GitHub Releases](https://github.com/nullawhale/dbeer/releases/tag/v0.3.0)
and follow [the installation instructions](INSTALL.md). This release includes
MongoDB, SQL result editing, synchronization SQL plans, snapshots, investigations,
the expanded workspace, local MCP agent access, expanded Cassandra CQL language
assistance, grouped table filters, multi-column sorting and saved table views.
Earlier release and prerelease archives remain unchanged.
Homebrew installation is not available.

Multiple profiles can run simultaneously. Each SQL tab gets its own connection on first execution and retains its transaction, SET state, and temporary tables until disconnected. The catalog and data tabs use separate sessions. Stop cancels the selected execution; Disconnect closes one profile's sessions.

## Using the application

- The narrow strip on the left opens **Connections** (**⌘1**), **Files** (**⌘2**),
  **SQL Library** (**⌘3**) and **Investigations** (**⌘4**) as separate resizable
  panels. Click the active section or press its shortcut again to hide it.
  Change or clear each binding in **Settings → Shortcuts → Sidebar Panels**;
  the strip shows icons and names, with current bindings in tooltips. The commands are
  also in the **View** menu. **⌘F** reveals Connections and focuses its search.
- **⌘N** creates a PostgreSQL, MySQL, Cassandra, or MongoDB profile. The wider editor separates General, SSH, TLS and Options. Test Connection checks unsaved settings and closes its temporary session; Stop Test cancels the check. Save stores the settings; Save and Connect opens a connection. Passwords use macOS Keychain by default; a local CLI can supply dynamic passwords. Settings live in `~/Library/Application Support/DBeer/connections.json`.
- In **General**, paste a `postgresql://`, `postgres://`, `mysql://` or JDBC-prefixed address into **URL** and choose **Use URL**. Single-host URLs support an explicit database, optional user/password, port, IPv6 and encoded values. PostgreSQL accepts `sslmode` and `sslrootcert`; MySQL accepts `ssl-mode` (or JDBC `sslMode`) and `ssl-ca`. Unsupported options and TLS modes are rejected. Omitted credentials and TLS options keep their current field values. The URL preview excludes passwords; imported passwords move into the Password field and use Keychain on Save. Apply or reset a pending URL before saving or testing.
- **⌘T** creates a SQL tab. **⌘Return** executes the selection or the statement at the cursor; **⇧⌘Return** runs the entire script sequentially until the first error or Stop. The editor supports highlighting, line numbers, undo, completion, and navigation to PostgreSQL error positions. After connecting, user table, view, schema, function, and column names load automatically for completion without expanding the tree; columns respect tables and aliases in the current query. Suggestions appear while typing and with **⌃Space**; profile Refresh updates metadata.
- The tree loads on demand and provides search, Refresh, structure, definitions, Copy Name, and Generate SELECT. Double-click a table to select an existing data view or load its first 200 rows; Open in New Tab creates an independent view. Filtering and sorting run on the server; pagination uses the primary key for stable ordering without automatic COUNT queries.
- Double-clicking an editable cell creates a local change. Insert Row, Delete Selected, Preview SQL, Apply, and Discard manage the batch. Apply uses a separate transaction and checks original rows under locks. A conflict or constraint error rolls back the entire batch. An unknown COMMIT outcome blocks another Apply until the outcome is checked and data is reloaded.
- Supported single-table SELECT results can open their source row by the complete primary key. Results containing every source column exactly once can stage cell updates through Preview/Apply; aliases and column order are preserved. JOIN, CTE, aggregate, UNION, computed or ambiguous results, views, and tables without a primary key stay read-only with a reason. MySQL editing requires InnoDB.
- Copy cells, rows, and ranges with **⌘C** or the context menu. Export Loaded saves rows already received. The separate **Run to File** action executes one statement once and publishes the complete file only after successful completion.
- **⌘O**, **⌘S**, and **⇧⌘S** open and save UTF-8 `.sql` files. Workspace changes are saved after one second of inactivity. History is enabled by default: 1,000 entries retained for 30 days. Query → SQL History can disable or clear history, or clear restored documents. Restoration never connects to a database or executes SQL.
- Connections → Import/Export Connections transfers profiles without passwords or private keys. Import shows a preview, creates new UUIDs, and requires selecting any missing or foreign CA while preserving the TLS mode. Portable files accept POSIX, Windows drive and UNC CA hints; foreign hints require explicit local remapping.
- Closing a tab, profile, or the application offers to complete transactions and apply/discard changes; Cancel keeps the window open. DBeer → Settings (**⌘,**) selects System/Lager/Porter.

SQL NULL, empty strings, the text NULL, and DEFAULT remain distinct. Column order and duplicate names are preserved. JSON uses metadata and value arrays, exact numbers are strings, and binary values use Base64. CSV uses UTF-8 and a selected NULL marker; a collision requires choosing another marker. Display is limited to 1,000 rows and 8 MiB with an explicit truncation notice; complete Run to File exports have no such limit. Statement timeout is 30 seconds.

The script splitter handles strings, comments, PostgreSQL dollar quoting/BEGIN ATOMIC, MySQL DELIMITER, and CQL batches and `$$` function bodies. SSH tunneling and local MCP agent access are supported. psql/mysql/cqlsh client commands, COPY streams, LOAD DATA LOCAL, and arbitrary application plugins are unsupported.

## Table filters, sorting and saved views

Open **Filter** above a loaded table to prepare conditions and sorting
without reading the database. **Apply** starts one read from the first page;
**Reset** restores the last applied settings. Header clicks edit the sort draft,
and multiple sort columns show their priority and direction. Apply or reset a
draft before changing pages or following a relationship.

PostgreSQL, MySQL and MongoDB support nested **All (AND)** and **Any (OR)** groups,
up to 32 conditions and four expression levels. Sort columns can be reordered and
given independent directions. MongoDB values use JSON/Extended JSON; BSON null
and missing fields retain their existing distinct behavior. Cassandra accepts
AND only, with the existing scalar key/index filters and one eligible clustering
sort column; it never adds `ALLOW FILTERING`.

**Saved Views** stores named filter/sort configurations for one connection profile
and exact table, view or collection. Select a view to fill the draft, then Apply
explicitly. Save New, Update Selected, Rename and Delete manage local entries;
missing fields remain visible for correction. Views are private local data under
`~/Library/Application Support/DBeer/TableViews/`, with no profile transfer or
cross-connection copying. Applied settings survive workspace restoration in
format v11; unapplied drafts last until the tab closes and are not restored.
Restoration never connects or reads data. Rows retained after a failed changed
view are identified as belonging to the previous read.

## SQL result source rows and editing

For supported PostgreSQL/MySQL SELECT results, select one row and choose **Open
Source Row** to load its complete row in a new, independent table tab. The helper
verifies the table and column origins using server metadata and requires every
primary-key column, including composite and binary keys. Display aliases never
identify a source table or column. A projection containing the complete key can
open its source row even when it omits other columns.

A direct SELECT containing every table column exactly once can edit supported
cells through the existing **Preview SQL**, **Apply**, and **Discard** controls.
The original column order is reconstructed for conflict detection; NULL, empty
text, exact numbers and binary retain their existing representations. SQL result
editing supports cell updates; insert and delete remain table-tab operations.
Apply uses a separate transaction with the existing locks, original-row checks
and execution policy. It never reruns the captured SELECT. After success the
result is marked stale; use Run explicitly to refresh. A conflict or unknown
commit keeps local changes and blocks another Apply until they are discarded and
a fresh result is loaded. Discard alone never executes SQL. Pin and export are
unavailable while edits are pending or the result is stale.

This first slice requires an idle source session and exact, roundtrippable
original values. Temporary tables, PostgreSQL inherited/partitioned tables,
missing or ambiguous keys, and unsupported query forms remain read-only. Types
whose SQL output requires extra storage evidence (including contextual or lossy
representations) use **Open Source Row** when their key is exact, then the table's
existing safe editing workflow. An active SQL transaction is never reused or
implicitly committed for these actions. Restored documents and offline snapshots
do not retain source-row permissions or editing state.

## MongoDB

MongoDB uses the [official Go driver](https://www.mongodb.com/docs/drivers/go/current/).
Choose MongoDB when creating a profile. General accepts comma-separated seed
hosts with one shared port; the database and user are optional. Options includes
the authentication database (default `admin`), automatic/SCRAM-SHA-256/SCRAM-SHA-1
authentication, replica set and direct connection. Passwords stay in Keychain or
the local password command. TLS supports `disable` and `verify-full`, including
a custom CA. SSH requires a direct connection to a single logical host.

The editor accepts one JSON request, with an optional `database` override:

```json
{
  "database": "demo",
  "collection": "orders",
  "find": {"price": {"$gte": {"$numberDecimal": "10.00"}}},
  "sort": {"createdAt": -1},
  "limit": 200
}
```

Use `"aggregate": [{"$match": {}}, {"$group": {"_id": "$region", "count": {"$sum": 1}}}]`
instead of `find` for aggregation. `find` also accepts `projection`; sort order
follows JSON key order. JavaScript, mongosh syntax and arbitrary database commands
are rejected. `$out` and `$merge` are output stages and pass the same execution
policy as other writes. Production requires confirmation; local readonly blocks
them. Driver retries are disabled, and interrupted output operations disclose
uncertain outcomes when applicable. MongoDB roles provide server-side protection.
SQL transaction commands and document grid editing are unsupported.

Collections open as complete BSON documents in a `document` column. The inspector,
loaded exports, snapshots and Run to File retain Canonical Extended JSON, including
ObjectId, int32/int64, Decimal128, dates, binary subtypes, timestamps, nested values
and legacy BSON types. BSON null, missing fields, empty strings and `"NULL"` remain
distinct. Field metadata and suggestions are sampled from at most 32 documents;
they are not a schema. Completion supports collection names, sampled field paths,
query/aggregation operators and Extended JSON type wrappers, while typing or with
**⌃Space**. Editing or completion never executes the script.

Collection browsing uses 200-document sequential cursors, bound to the tab,
collection, filter and sort, with a five-minute client expiry. Filter values use
JSON/Extended JSON, including quoted strings. **Sort Documents** in the filter
panel chooses a sampled field and direction; JSON scripts support compound sorts.
Pages do not provide snapshot isolation. Interactive scripts retain at most 1,000
documents or 3 MiB of encoded rows; larger documents require Run to File. Run to
File streams the full result, subject to an explicit query limit and timeout.
Restored tabs remain disconnected and restart from their first page on explicit
Load Data. MongoDB schema and live table-data comparison are not supported;
saved BSON results can use exact snapshot comparison.

## Workspace restoration

DBeer restores SQL, table/view, snapshot and investigation tabs in their saved
panes and order, with each pane's selection, titles, SQL text and original
connection bindings. Table tabs keep their schema/table reference, page, server
filters and sort order. They initially show this context with an explicit
**Load Data** action. SQL tabs remain
disconnected until Run; table tabs remain disconnected until Load Data or Refresh.
A missing connection stays unavailable until you explicitly choose a replacement.
PostgreSQL/MySQL reopen the saved page on loading; Cassandra and MongoDB start
from the first page because their server cursors cannot survive a session restart.

Sessions, transactions, running operations, live results, cursor tokens and pending
grid changes are excluded. Snapshot and investigation tabs retain local artifact
references.
A recovered tab cannot resume an old Apply or repeat
SQL automatically. Text and browsing changes autosave without fetching table data.

SQL file bindings retain the last accepted file-content fingerprint and the draft
text independently. Local file observation resumes after restoration; clean
buffers adopt external changes, while changed drafts retain both versions for
review. Missing or unreadable files keep their editable drafts. Bindings without
a known fingerprint require **Save As**. No file operation connects to a database.

Workspace storage is v11, with exact private backups before migrating
v0/v1/v2/v3/v4/v5/v6/v7/v8/v9/v10. Formats before v8 start with their tabs in the left
pane; v8/v9 retain their saved pane layout. Nested horizontal and vertical splits
and each divider's position are preserved. V11 stores grouped applied filters and
migrates legacy filters as AND groups; unapplied browsing drafts are not restored.
Folder attachments and shared file identities are saved alongside
the views; each view retains its own connection binding. Existing history,
favorites and retention preferences are preserved.
Unknown document kinds, malformed state and future workspace versions are left
unchanged.

**File → Reopen Closed Tab** (**⇧⌘T**) returns the most recently closed SQL,
table/view, snapshot or investigation tab, including when no tabs remain open.
Up to 20 successfully closed tabs are kept in memory for the current application run.
Repeated reopening returns them in reverse closing order, in their former pane
and position where possible, and selects each reopened tab. Cancelled or rejected
closes are excluded.

Reopened tabs have fresh document identities and no session, transaction, live
result, cursor or pending edits. Snapshot and investigation tabs read their local
artifacts. SQL, connection reference, file binding and table browsing settings are restored
without reconnecting or executing SQL. Reopening
a view of an already open file uses its current shared buffer. Run or Load Data
opens a new session explicitly. Missing connections
require choosing a replacement. Rebind or clear the shortcut in **Settings →
Shortcuts**. The closed-tab list is cleared on application exit and by a successful
**Clear Drafts** action; it is never written to workspace storage.

## Split working panes

The workspace starts with one pane. A tab's context menu offers **Split Left**,
**Split Right**, **Split Up** and **Split Down**. A fresh SQL tab opens in a new
pane on that side, using the source tab's connection profile and focusing its
editor. The source tab stays in place; splitting never connects automatically.
Any pane can be split again. Each divider
can be resized independently. **Unsplit Current** moves the current pane's tabs
into its nearest sibling pane and removes only that split. **Unsplit All** brings
every tab back into one pane, keeping the active tab selected. Neither action
closes documents or database sessions.
Closing the last tab in a split pane removes that pane automatically. Closing
the final tab in the workspace leaves one empty pane.

The six commands are also in the Window menu and **Settings → Shortcuts**:

| Command | Default shortcut |
| --- | --- |
| Split Right | Command-Backslash |
| Split Left | Option-Command-Backslash |
| Split Up | Control-Command-Backslash |
| Split Down | Control-Shift-Command-Backslash |
| Unsplit Current | Option-Shift-Command-Backslash |
| Unsplit All | Shift-Command-Backslash |

Shortcuts are grouped by connections, sidebar panels, tabs/navigation, split panes, SQL files,
query execution, results/copying and history. Search by command or group name,
the assigned shortcut's symbols, or modifier names such as `Cmd+Shift+Backslash`.
Search follows current assignments, including cleared shortcuts (`unassigned`).

Each pane keeps its own selected tab. Drag tabs between pane tab bars or use
**Move to Pane** in a tab's context menu;
**Move Tab Left/Right** changes the order within a pane.
Moving a tab keeps the same document, session, transaction, running query, grid
draft and editor state. Opening a new independent table view retains its existing
separate-session behavior.

Editor and grid focus activate their pane. Run, Stop, Copy and Save resolve that
document, and toolbar actions address the pane containing the clicked control.
Previous/Next Tab cycles within the active pane. Pane placement, selections,
active pane and divider width survive restart without reconnecting to a server.

## Investigation documents

Open **Investigations** from the left strip (**⌘4** by default) to create or
reopen a local document in its own sidebar panel.
Give it a title, add Markdown, SQL or snapshot blocks, and use the table of
contents to select and reorder them. Markdown has editable source and a rendered
preview. The editor displays one selected block at a time.

Every SQL block has an explicit connection profile and its own working session,
including when several blocks use the same profile. **Run Block** executes only
the selected block through the normal SQL preview and execution policy.
**Run Statement** addresses its current statement. Choosing another block or
moving the parent tab retains existing sessions and transactions. An unbound or
missing profile requires an explicit choice before execution.

**Save** from a block writes the complete investigation, including all current
Markdown, SQL, profile references and block order. Closing a tab keeps its
document in the local library. Reopening creates fresh disconnected blocks;
restoration never retrieves credentials, connects or executes SQL. Live results,
sessions and transactions are excluded from saved content.

Snapshot blocks retain an artifact reference and editable explanation, and read
local pages only. Missing or damaged artifacts show an unavailable state while
keeping that explanation. Snapshot deletion checks saved investigations even
when closed, plus unsaved open changes; an unreadable library blocks deletion
until its references can be checked.

Storage accepts up to 4,096 documents and 4,096 blocks per document, with at most
16 MiB of text per block, 64 MiB per document and a 256 MiB encoded library.
SQL execution retains the normal query-size checks. Failed writes preserve the
previous library and leave current edits available for retry.

## PostgreSQL types

Expand a connected PostgreSQL profile's schema to find separate **Enums** and
**User-defined Types** groups. Open a type there or from search, or choose
**Inspect Type…** from its context menu, without finding a table or row that uses it.
The inspector shows **Definition**, server-ordered **Enum Values** and incoming
and outgoing **Dependencies**, together with the limitations of available
operations. Empty enum labels remain distinct from missing values. Partial or
unavailable metadata is shown explicitly; dependency lists describe direct
catalog references and cannot account for dynamic SQL. Shared cluster references,
such as role ownership, are outside the dependency list. Enum CREATE definitions
are reconstructed from ordered labels. Domain and composite definitions identify
their reconstruction limits; range, multirange and base types show their
properties when a complete CREATE definition is unavailable.

Under **Generate DDL**, choose a supported type rename, an enum value appended
at the end, or an enum value rename, then choose **Preview DDL** (**⌘Return**).
The preview shows the exact operation, source connection and destination pane
without changing the database.
**Open SQL Tab** creates a draft bound to the captured connection; ordinary Run
then applies the existing readonly, environment and confirmation policy.
**Back to Type** or **Cancel Preview** discards the preview; **Stop** cancels
its request. Viewing
and previewing remain available for readonly connections. PostgreSQL permissions
and type restrictions still determine whether execution can succeed.

The inspector uses the connected catalog session. Refresh, closing the inspector
or changing its connection invalidates pending responses. Review the generated
SQL before execution and refresh metadata afterward. A newly added enum value
cannot be used until its transaction commits. Enum value deletion and reordering
are not generated; extension-owned or derived types can have further limits.

## SQL folders and files

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

## Shared SQL library

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
view. Workspace restoration keeps the index, groups and view bindings disconnected,
with an exact private backup before migrating v5. Restoring or editing library
metadata does not connect or execute SQL.

## Independent table views

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

## Table data comparison

Use **Connections → Compare Table Data…** to select one source and target table
on saved PostgreSQL, MySQL or Cassandra profiles with the same engine. Enter exact schema
and table names, then explicitly **Read Table Metadata**. Opening or configuring
the sheet never connects. Map columns one-to-one and select at least one key;
primary keys are labelled as suggestions and are never selected automatically.
Configure each side's filters and read limit independently: 10,000 rows by
default, up to 100,000. NULL predicates are separate from the text `NULL`.

**Compare** opens two new physical read-only sessions, including when both sides
use the same profile. Each side rechecks its typed table descriptor and reads in
a repeatable-read transaction on PostgreSQL/MySQL. Cassandra reads have no
transactional snapshot and always remain partial, even when the configured scope
is exhausted. SQL tabs and their transactions remain independent.
Capture intervals are recorded separately: there is no common atomic snapshot
across servers. Database sessions close before the local comparison begins.

Matching uses exact typed keys and values, preserving numeric strings, NULL,
empty strings, literal `NULL` and Base64 binary. Duplicate keys are ambiguous;
row order never establishes correspondence. Source-only and target-only labels
express ownership, not database actions. Inspect paged differences, wide-row
column pages and bounded exact value chunks. Limited captures report observed
differences only: a missing row in a partial sample does not establish absence
from the table. Samples may differ because server ordering and collations differ.

Each capture reads at most one row beyond its configured limit. That sentinel
marks the scope partial without being retained or establishing a total count;
exactly the configured limit is complete only after a successful end of result.
Temporary captures and comparison files share a 256 MiB budget. Storage limits
can produce a partial-prefix report or an explicit failure, never full equality.
All original columns are retained privately by default, including columns excluded
from comparison. **Mapped columns only** omits excluded originals. This setting,
filters, capture intervals and exclusions remain visible in the captured context.

The initial scope supports PostgreSQL 14+ ordinary tables without row-level
security, inheritance or partitions, and MySQL 8.0.30+ ordinary InnoDB tables.
MySQL requires conservative direct SELECT-grant visibility, no active roles and
partial revokes disabled;
unsupported or hidden metadata fails explicitly. Descriptors include exact type
identity, modifiers and relevant definitions; schema changes invalidate capture.
Cassandra supports tables and materialized views with its configured consistency
level; filters must satisfy Cassandra's supported key/index rules. Cross-engine
comparison and unsupported table kinds are unavailable.

**Stop**, closing or resetting the comparison removes its private temporary data;
the application also cleans its owned directory after forced helper termination.
Captures are transient and are not saved result snapshots. Comparison performs
no database writes. PostgreSQL/MySQL captures can produce an explicitly requested
synchronization SQL plan as described below.

## Schema comparison

Use **Connections → Compare Schema Structure…**, choose explicit source and
target profiles with the same engine, and map their schema names. Opening or
configuring the comparison never connects. **Compare** creates two independent
read-only sessions, including when the same profile is selected twice; SQL tabs
and their transactions remain independent. **Stop** cancels both captures.

Table, column, constraint, index and type name overrides declare correspondence.
Explicit pairs consume their endpoints before remaining exact-name matching;
names are case-sensitive, and renames are never inferred from similar content.
PostgreSQL local OIDs are resolved to qualified semantic references. Defaults,
generated/identity columns, exact type modifiers, keys, index properties and
referenced enum/domain/composite/range/multirange/base-type/sequence definitions come from adapter metadata,
without parsing displayed DDL or converting numeric values through floating point.

The report shows property differences, incomplete observations, capture intervals
and source → target. Values are available in bounded UTF-8 chunks. **Export JSON
Report…** streams a versioned report containing both typed captures, mappings,
dependencies, differences, issues and a semantic digest to an atomic local file
replacement. Reports exclude connection settings and credentials. They can contain
schema definitions, comments and defaults; choose an appropriate local destination.

This scope covers mapped table structure and referenced types/sequences, excluding
views, routines, triggers, privileges, statistics, stored data and sequence or
AUTO_INCREMENT counters. PostgreSQL 14+ captures use a dedicated repeatable-read
read-only transaction. MySQL 8.0.30+ captures use structured Information Schema
metadata, conservative direct-grant visibility proof and a best-effort recheck for
concurrent DDL; they do not promise an atomic snapshot shared by two servers.
Cassandra captures keyspace options, ordered UDT fields, nested type arguments,
partition/clustering/static columns, indexes and materialized-view structure.
Schema agreement and version checks detect concurrent DDL; metadata remains
best effort and never promises a shared snapshot.

Unsupported table kinds/index options and unresolved expression dependencies
require manual review and
prevent full equality. Unknown metadata on both sides is never equality. Large
captures fail explicitly at bounded node/member/scalar/storage limits. Only a
complete comparison can say **Selected table structure matches**. SQL planning is
a separate explicit action; comparison never applies migration SQL.

## Synchronization SQL plans

After a PostgreSQL or MySQL schema or table-data comparison finishes, choose
**Generate SQL Plan**. Review the captured source → target direction, operation
dependencies and SQL preview. Select operations individually; destructive changes
start unselected. Object paths and primary-key summaries identify each operation.
Every prerequisite must be selected before dependent SQL can be
saved or opened. Unsupported transformations appear as manual steps with reasons.
Planning uses the retained comparison captures and never reads or changes either
server. Closing or resetting the comparison invalidates its plan.

Structural plans support ordinary table and column additions, primary/unique/
foreign-key constraints and standalone indexes. PostgreSQL also supports
independent enum and schema creation. Supported nullability, literal-default and
column-comment changes require explicit selection. Type conversions, expressions,
identity/sequence changes, existing-object replacement and removals that need
dependency information outside the captured scope remain manual. A manual
prerequisite also makes its dependent operations manual.

Data plans require complete captures, all original columns, compatible exact
types, an unambiguous comparison key and the complete target primary key.
Explicit column mappings, renames and exclusions define the synchronization
scope. Excluded target originals still participate in stale-row guards; inserts
require all supported target values.
Source-only rows produce INSERTs; target-only rows produce DELETEs; changed rows
produce UPDATEs for mapped values. UPDATE and DELETE start unselected and compare
every captured target original before changing a row. A concurrently changed row
is skipped, so inspect affected row counts. A concurrent insert can cause a
primary-key conflict. NULL, empty text, literal `NULL`, exact numeric strings and
binary values retain their distinctions. Unavailable originals, generated inserts
and representations the dialect cannot preserve remain manual. Filters restrict
the plan to the captured scope. Foreign keys, triggers and other target constraints
may require manual ordering. Plans are limited to 2,000 operations and 4 MiB;
an oversized data plan produces a manual explanation instead of a SQL prefix.

**Save .sql…** saves the selected SQL with private file permissions.
Command-S opens the native save dialog. Changing the selection while that dialog
is open requires reviewing and saving the SQL again. Escape returns to the
comparison; Return opens the selected SQL in the target editor.
**Open in Target Editor** creates a new disconnected SQL tab bound to the captured
target profile. Changed target connection settings require a fresh comparison.
Run the reviewed SQL explicitly through the ordinary editor and execution policy.
Captures are historical; concurrent changes can invalidate a plan. Execution can
finish partially, and DDL has no portable global rollback.

## Type coverage

Type support is checked separately for metadata, value capture and writes:

| Engine | Schema and table-data comparison |
| --- | --- |
| PostgreSQL | Built-in scalar types, exact modifiers, true arrays, enums, domains, nested composites, ranges, multiranges and custom base/extension type catalog definitions. Type references and function signatures use qualified names rather than server-local OIDs. |
| MySQL | Numeric widths/precision/scale, unsigned/zerofill, temporal precision, text/binary lengths, JSON, BIT, ordered ENUM/SET labels including binary labels, spatial types with SRID, and VECTOR metadata where the server provides it. |
| Cassandra | Scalars, counters, duration, blobs, frozen/nested collections, maps, tuples, UDTs and vectors where available. Custom Java types preserve binary values and class identity; unavailable implementation identity blocks schema equality. |

Live type checks cover PostgreSQL 16/17/18, MySQL 8.0/8.4 and Cassandra 4.1/5.0.
MySQL VECTOR metadata has unit coverage; no MySQL 9 live run is claimed.

SQL definition previews use frozen typed facts, including literal escaping and
type dependencies. They do not run migration SQL. Missing permissions, malformed
server metadata, unsupported properties and exhausted limits stay explicit;
matching unknown facts never prove equality.

An arbitrary extension's text output is not assumed to distinguish every stored
value. Such values remain readable, but their comparisons are marked uncertain
unless a lossless representation is established. PostgreSQL row-version evidence
still permits safe Preview/Apply without trusting an extension's text output.

MySQL table-data capture retains ENUM's stored index and exact label bytes so
the historical error value at index zero differs from a declared empty label.
Both still display as empty text in ordinary SQL results. Table browsing retains
private row storage evidence through Preview/Apply, including ENUM/SET masks and
PostgreSQL row versions. It distinguishes hidden stored-value changes even when
displayed text is identical. An old or arbitrary original row without required
evidence cannot pass Apply's conflict check. These tokens are not exported or
saved in offline result artifacts. Arbitrary MySQL
query results do not expose every ENUM/SET label or spatial/vector definition;
their unresolved type identities cannot establish full snapshot equality.
Ordinary MySQL FLOAT, fixed-decimal DOUBLE, TIMESTAMP and text without utf8mb4 or
binary result metadata also retain uncertain value identity. Table
captures use UTC, UTF-8 and roundtrip floating-point projections; table browsing
keeps exact floating-point and timestamp evidence for conflict detection.

PostgreSQL query results retain structural type fingerprints for custom types
and exact result modifiers. Type discovery uses Parse/Describe on the owning
session before executing SQL once; it sees that session's temporary and
uncommitted types. Saved results preserve these identities across offline reopen.
Old snapshots remain readable; only context-independent, parameterless built-in
scalar identities can be recovered from their names. Missing modifiers or custom definitions remain
uncertain, and matching local OIDs never establish equality. MySQL and Cassandra results also retain stable type metadata
available in their result protocols.
Ordinary PostgreSQL SQL can change its own rendering settings while executing.
Date/time, floating-point, geometric, monetary and symbolic object-reference
output therefore remains uncertain in saved-result comparisons, including nested
values. Table-data capture uses its separate, controlled rendering context.
When PostgreSQL reports a domain expression as its base result type, the result
keeps that reported type; table-data/schema comparison retains the full domain
definition from catalog metadata.

PostgreSQL arrays, composites, enum/domain/range values and custom server text
types use the existing Preview/Apply path with full original-row comparison.
Additional MySQL JSON, ENUM/SET, BIT, floating-point and spatial/vector values use
typed bindings and retain exact binary data. Conversion warnings roll back Apply.
Generated columns, missing keys and permissions retain their existing limits.
Cassandra conditional grid editing retains its scalar, single-partition limits;
complex values, counters and durations remain available through explicit CQL.

## Value inspector

SQL results and table grids include a resizable **Value Inspector** beside the
grid. Select a cell and use the arrow keys to inspect adjacent values without
opening a dialog. The panel shows the column, row, native type and exact source
text; SQL NULL, DEFAULT, empty strings and Base64 binary values have distinct
labels. Text remains selectable and read only. **Wrap** changes line wrapping,
and **Find in value** searches the displayed text with previous/next navigation.
**Row Details** uses the same sidebar; closing it returns to the value inspector.

JSON and XML have syntax highlighting. **Format JSON** changes only the preview:
numbers retain their exact spelling, and key order, duplicate keys and escapes
are preserved. Turning formatting off restores the original text. XML never
loads external entities; DTD/entity declarations are displayed as plain text.
Parsing and search run in cancellable background tasks. Structured previews have
size, depth and token limits; invalid or oversized values retain their complete
source text. Search highlights up to 10,000 matches. Inspection never executes
SQL, connects to a server or changes pending grid edits; use the existing cell
editor and Preview/Apply workflow to make changes.

## Result copying

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
change.

## SQL history

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

History uses versioned workspace storage, currently v11. Existing v0/v1/v2/v3/v4/v5/v6/v7/v8/v9/v10 files
receive exact backups before migration; older entries retain their original
outcome text and show unavailable execution details rather than inferred values.

## Result snapshot storage

Use **Pin Result** on a completed result to retain the selected result set and
its original SQL, capture time, profile, environment and outcome. Partial or
truncated data remains marked. Local grid edits are excluded. Pinned results
open as read-only, paged offline tabs, including after closing a tab or restarting
the app. Workspace files retain artifact references rather than copying rows.

Opening a snapshot reads local data and never runs SQL against a database.
**Open SQL in New Tab** creates a separate draft; choose a connection before
running it. Missing or damaged artifacts remain visibly unavailable.

Table snapshots retain the filtered, sorted read query and loaded page. Cassandra
cursor pages remain partial; their captured CQL starts a fresh read because a
cursor is not part of the SQL text. Source SQL has an 8 MiB metadata limit and
must also fit the helper's response frame. An oversized browse source is reported
without discarding the loaded rows.

**Query → Result Snapshots…** opens the local snapshot manager. It lists capture
times, row counts and stored sizes, shows total usage, and lets you change the
storage limit in MiB. The default quota is **1 GiB**. Lowering a quota does not
delete existing snapshots; no automatic capture or eviction is enabled.

Artifacts use private versioned metadata and positional JSONL rows to preserve
column order, duplicate names, SQL NULL, empty text, exact numbers, binary values
and truncation. A snapshot is published only after its actual written size fits
the quota. Failed or interrupted writes leave earlier snapshots intact; Refresh
cleans incomplete temporary writes. Deletion requires confirmation, including
notice of any investigation documents using the artifact. Credentials and
connection secrets are excluded from snapshot metadata.

## Result comparison

In **Query → Result Snapshots…**, choose **Compare Snapshots** and select two
saved artifacts. Explicitly choose a key or saved row order, then map the columns
to compare. Column positions distinguish duplicate names; omitted columns are
excluded and recorded in the report. Saved row order compares the captured
positions and does not establish a database ordering guarantee.

Comparison preserves the engine, native type, encoding, SQL NULL and exact saved
value. Decimal and integer strings are never rounded through floating point.
Duplicate keys are reported as ambiguous without arbitrary pairing. Unresolved
PostgreSQL type OIDs remain uncertain. Partial or truncated inputs, uncertainty
and excluded columns prevent a conclusion of full-artifact equality.

Added, deleted, changed, ambiguous and uncertain rows are paged. Wide rows also
page their mapped columns. Cell previews are bounded; the value inspector reads
exact saved text in byte chunks, including the original Base64 text for binary
values. The helper reads private artifact references rather than receiving both
result sets in a protocol message. No database session or SQL execution is used.

Comparisons stream inputs and spill sorting and reports to private temporary
files. Each job has an **8 GiB** temporary limit; at most two jobs can be retained
by a helper. Stop, closing the comparison and helper shutdown release temporary
files. Disk or quota failures leave saved snapshots intact.

## Dynamic database passwords

In **General → Authentication**, choose **CLI command** as the password source.
Enter an absolute executable path and its arguments as a JSON array of strings,
for example `/usr/local/bin/database-token` with
`["issue", "--host", "db.example.test", "--user", "reader"]`.
Arguments are passed exactly as entered. There is no implicit shell, quoting
parser, variable expansion, pipeline or `~` expansion. Keep secrets in the CLI's
own credential store rather than in these locally saved arguments.

The command receives no stdin and must exit successfully within **15 seconds**.
Stdout is limited to **64 KiB**, including any trailing newline. Return one
nonempty UTF-8 password, optionally followed by one LF or CRLF. Other whitespace
is preserved; embedded line breaks and NUL bytes are rejected. Stderr is
discarded. Output is never logged, returned to the app, or saved in Keychain or
profile files. Cancellation terminates the command's process group.

Each new authenticated database connection obtains a fresh value: independent
SQL tabs, catalog/service sessions, Preview/Apply sessions and MySQL's Stop
connection. Existing database sessions keep their current authentication.
PostgreSQL cancellation uses its server-issued cancellation key. SSH
authentication remains separate. A command or authentication failure stops that
connection attempt without falling back to an old token or replaying user SQL.
Reconnect explicitly after fixing the provider.

Save, duplicate, profile import and workspace restoration never run commands.
Commands run when connecting, running a query, testing a connection or opening
a Preview/Apply session. An already-connected Cassandra profile also obtains
fresh values for driver control/node connections and reconnects.
Portable profile export omits the executable and arguments;
imported profiles use Keychain until a local CLI is configured again. Existing
profiles continue using Keychain. Connection-library v5 preserves private
migration backups and prevents older clients from silently dropping CLI settings.

## SSH tunnels

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

Choose **OpenSSH Configuration** for aliases and multi-hop routes. Enter the
`Host` alias in **SSH server**; OpenSSH reads the hostname, port, user, identities,
`Include`, `ProxyJump` and `ProxyCommand` from this Mac's configuration. Leave
**Configuration file** empty for the default user/system configuration, or select
a local file. Multiple comma-separated jump hosts and nested includes use native
[OpenSSH configuration semantics](https://man.openbsd.org/ssh_config).
Authentication must work without interactive password or MFA prompts, using an
available agent, unencrypted key or the local OpenSSH key configuration.

DBeer reviews each native ProxyJump host and the final server before
authenticating it. A probe can authenticate already trusted jump hosts to reach
the next server, but stops before final-server authentication. Keys remain
profile scoped, including resolved hostnames and ports. The default user/system
known-hosts files are consulted read-only. DBeer's own verification replaces
configured known-hosts commands/files and DNS trust; configured forwarding,
remote/local commands, persistent masters, agent and X11 forwarding are disabled.
Only DBeer's loopback forwarding listener is installed. Routes support up to 16
distinct SSH endpoints and retain bounded startup/cancellation.

`ProxyCommand` and `Match exec` can execute local programs during an explicit
connection or Test Connection. A custom proxy program controls any SSH clients
it starts internally; DBeer verifies the final server and directly managed
ProxyJump hosts. The helper supervises the SSH process group, including proxy
children, and reaps it on cancellation, disconnect or helper loss. Changing a
configuration file takes effect after disconnecting the profile and reconnecting.
Profile export omits the local configuration path and all configuration contents;
an imported alias uses the receiving Mac's local configuration only after an
explicit connection. Saving, importing and restoring do not evaluate that config.

The native app uses its matching protocol v5 helper (`sshConfigV1` is required
for configuration mode); Windows/Linux GPUI SSH support is deferred.

## Execution commands and safety

The Query menu, execution buttons, and keyboard share a command registry for the active document. Default shortcuts are preserved: **⌘Return** runs the selection or current statement, and **⇧⌘Return** runs the entire script. The Run fragment is highlighted inside the editor and updates with cursor or selection changes. A cursor immediately after `;` still belongs to the completed statement.

DBeer → Settings → Shortcuts configures connection creation, import/export and search; SQL tabs, files and folders; SQL history; execution; and Copy as commands. **⇧⌘[** and **⇧⌘]** select the previous and next tab, wrapping at either end. Existing New/Open/Save defaults are preserved. Close Tab, history, folder actions and connection import/export are initially unassigned; Close Tab uses the usual transaction and pending-edit review. Assignments can be cleared or restored and persist between launches; conflicts and protected editing shortcuts are rejected. Commands respect focus and the active tab; settings windows, dialogs, and typing in other text fields never launch SQL.

Profiles support unset, development, staging, and production environments and a separate readonly setting. The environment appears as text and color in the profile, SQL tab, and confirmation. The profile editor first routes open sessions through normal transaction completion; Cancel preserves the previous context.

Execute, scripts, Run to File, and Apply share one helper policy: destructive and unrecognized commands require confirmation in every environment, and production confirms every write. Multi-statement runs, including editor selections, show the entire batch before the first statement. Approval is tied to the exact SQL or typed changes and the current session; edits, errors, Stop, and reconnection prevent reusing any remaining approval.

Readonly rejects writes and unknown constructs before reaching the adapter and disables grid editing. PostgreSQL/MySQL also enable server-side read-only mode; Cassandra uses local CQL assessment and relies on server role permissions for an enforced write prohibition. The classifier structurally accounts for strings, comments, CTEs, and dialect; unsupported syntax and unknown functions are not classified as reads. Use a separate database user with restricted permissions for a strict write prohibition: server modes have exceptions, including temporary tables, and do not replace access controls. See [PostgreSQL SET TRANSACTION](https://www.postgresql.org/docs/18/sql-set-transaction.html) and [MySQL SET TRANSACTION](https://dev.mysql.com/doc/refman/8.4/en/set-transaction.html).

Assessment follows SQL structure and a limited list of built-in functions for each engine. Production confirmation applies to operations classified as writes or unknown commands. Views, custom overloads of built-in names, casts, and operators can hide side effects; the client does not fully resolve server objects and types. Server-side readonly blocks ordinary writes to permanent tables, but database permissions must restrict server-allowed temporary-table exceptions and function execution.

## SQL editor and completion

Completion search matches parts of a name: `oi` finds `order_items` and `OrderItems`, while `items` matches the second word. Minor typos are tolerated: `ordres` finds `orders`. Among candidates of comparable match quality, columns in the current query and CTEs rank above general functions and keywords. Exact names take priority, and typo corrections follow ordinary matches. Typo correction is disabled for queries of one or two letters.

Matching parts of each name are highlighted with bold text and theme colors: for `oi`, the `o` and `i` in `order_items` are highlighted. Highlighting follows the actual match, including typo alignment, and updates when the selected row or theme changes.

The editor has increased internal padding and line spacing, current-line highlighting, and line numbers with an active-line indicator. Syntax, cursor, and selection colors adapt to light and dark themes; execution highlighting is preserved.

A green checkmark beside the first line number marks a successfully executed SQL statement. Scripts mark every completed statement; errors, cancellation, and unknown outcomes are not marked. Editing text, changing the connection profile, or starting another run clears previous marks.

The bundled local language server suggests PostgreSQL/MySQL keywords and functions, tables, columns, and aliases according to the current SQL clause. It understands CTEs and subqueries, projected column aliases and stars, correlated queries, and LATERAL sources. ORDER BY/GROUP BY include SELECT aliases; MySQL also offers them in HAVING. Ambiguous columns are qualified with their source alias. After JOIN, foreign keys provide a table, a free alias, and the ON condition; after an existing ON, they provide the condition alone. Composite keys use AND, and reverse/self joins are supported. Completion appears while typing, including after clause whitespace; **⌃Space** invokes it explicitly. **↑/↓** selects an item, **Tab/Return** inserts it, and **Escape** closes the popup. Standard Undo reverses insertion. Switching profiles or dialects updates the context; responses for earlier text are discarded.

Function signatures appear above the caret while typing inside a call, with parameter names/types, the return type, and the current argument highlighted. Nested calls, PostgreSQL named arguments, defaults, variadic arguments, and overloads are supported; moving the caret updates the active parameter. The panel preserves editor focus and Undo, follows the editor theme, and closes with **Escape**. Common built-ins are available offline; user-function signatures load with the connected profile metadata and refresh through profile Refresh. Overloads are ranked by arity and argument names, without inferring expression types; polymorphic return types remain descriptive.

**Settings → Appearance** separates the application appearance from the SQL editor scheme. The application supports System, Lager (light), Porter (dark), and every scheme in the shared library: DBeer Light/Dark, VS Code Light+/Dark+, Solarized Light/Dark, JetBrains Light, Darcula, and imported schemes. Application and editor choices are saved independently: for example, the application can use Solarized Light while the editor uses Darcula. Application colors apply to backgrounds, the sidebar, tabs, controls, and result tables; the Dock icon follows the scheme's light or dark appearance. In **Follow App Appearance** mode, the editor inherits the application scheme. The preview and open SQL tabs update immediately while preserving text, cursor position, scrolling, and Undo.

**Import Theme…** accepts standard VS Code `.json`/`.jsonc`, TextMate `.tmTheme`, and JetBrains `.icls` color schemes. Export a JetBrains scheme through **Editor → Color Scheme → Export → IntelliJ IDEA color scheme (.icls)**. Supported settings include editor, selection, cursor, and line-number colors, basic SQL token classes, and available text styles. JetBrains UI `.theme.json` files, JAR plugins, TextMate grammars, and semantic-token rules are not loaded. `.icls` supports Default/Darcula inheritance; an unknown parent produces a clear error.

JSONC can contain comments and trailing commas. Local `include` files and `tokenColors` references to `.tmTheme` resolve within the selected scheme's directory and its subdirectories. Import saves a standalone local copy in `~/Library/Application Support/DBeer/EditorThemes/themes.json`; source files are no longer needed. Available VS Code UI colors style the application, with missing colors derived from the editor palette for readability. **Remove Theme** removes only imported schemes and returns the editor to automatic selection; if the scheme is selected for the application, it returns to the previous System/Lager/Porter appearance. Built-in schemes cannot be removed. Importing and switching themes never executes SQL or connects to a database. Format references: [VS Code](https://code.visualstudio.com/api/extension-guides/color-theme), [TextMate](https://www.sublimetext.com/docs/color_schemes_tmtheme.html), [JetBrains](https://www.jetbrains.com/help/idea/configuring-colors-and-fonts.html).

After an explicit connection, a separate service session loads table, view, function, column, foreign-key, and function-signature metadata in background batches; tree expansion is optional. Profile Refresh replaces stale metadata. The completion engine never connects to a database or executes SQL; restored tabs remain disconnected. All SQL completion rules live in [`helper/internal/sqlcomplete`](helper/internal/sqlcomplete/README.md), while LSP transport and native presentation remain separate. Complex expression outputs need explicit aliases; completion does not infer types or foreign keys through arbitrary derived expressions. The helper ships with the application and needs no third-party tools. Diagnostics identify unclosed strings, comments, and parentheses; they do not replace server-side SQL validation. If the language server is unavailable, normal editing, execution, and basic completion remain available.

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
Language assistance includes CQL schema and authorization keywords, native and
user-defined types in declarations, existing objects in ALTER/DROP/TRUNCATE,
INSERT column lists, DELETE selectors and ANN ordering. Column suggestions retain
partition/clustering/static roles. Connected completion snapshots also load UDF
and aggregate declarations, including overloads, parameter types and return types,
without fetching their source bodies or executing them. Unqualified calls use
the target table's keyspace when available, falling back to the tab's current
keyspace while the statement is incomplete; qualified calls can address another
keyspace. UDT declaration suggestions stay within the declaration's keyspace.

Offline function completion and signature help cover conversions, JSON, time,
aggregates and Cassandra 5.0 math, collection, masking and vector functions.
Nested map, set, list, tuple and UDT literals retain the correct active argument.
Functions introduced in 5.0 remain visible offline; the connected server determines
availability. Diagnostics cover incomplete strings, delimiters and unsupported
cqlsh directives; server-side validation determines semantic correctness. The
bundled language server also accepts the `cql` document language identifier.
See Apache's [CQL functions](https://cassandra.apache.org/doc/stable/cassandra/developing/cql/functions.html)
and [JSON support](https://cassandra.apache.org/doc/stable/cassandra/developing/cql/json.html).

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
`system.` for ordinary native functions; `COUNT(*)`, `TTL`, `WRITETIME`, `MAXWRITETIME` and
`CAST(... AS ...)` retain their dedicated CQL selector syntax.
Local readonly assessment recognizes metadata reads (`LIST`, `DESCRIBE`/`DESC`),
tuple and TOKEN relations, collection/UDT selectors and system-qualified native
functions. User-defined calls, including calls nested in literals, still require
the existing execution policy.

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
./scripts/test-mongodb.sh  # MongoDB 8.0, authenticated plain/TLS and replica set
./scripts/test-cassandra.sh  # Cassandra 4.1/5.0, plain and authentication/TLS
./scripts/test-cassandra.sh --version 5.0 --mode tls --multi-node  # replica failure profile
```

The opt-in `./scripts/test-mongodb-ui.sh plain` and
`./scripts/test-mongodb-ui.sh tls` runners open native macOS windows against a
disposable MongoDB 8.0 server. They check the connection editor, document browsing,
paging, filters, sort, aggregation and BSON inspection in light and dark
appearances, plus automatic completion and keyboard acceptance in a native editor.
They use isolated credentials and synthetic documents;
screenshots are written to `build/mongodb-ui/`. These checks require an interactive
macOS session and Screen Recording access; run them only when UI verification is
requested. They are not part of the default helper integration run.

The opt-in `./scripts/test-table-browse-ui.sh` runner checks draft filters,
AND/OR groups, ordered sorting and saved-view actions against disposable
PostgreSQL 17, MySQL 8.4, Cassandra 5.0 and MongoDB 8.0 servers in both appearances.
It verifies explicit Apply, Cassandra restrictions, long nested configurations,
and SQL-result headers, using private profiles and saved-view storage. Docker and
an interactive macOS session are required; run it only when UI verification is
requested. Logs and owned-window captures go to `build/table-browse-ui/`.

The opt-in `./scripts/test-r22-ui.sh` runner checks SQL result source rows and
editing in native windows against disposable PostgreSQL and MySQL servers. It
exercises Run, inline cell editing, SQL preview, Apply, conflict handling and
source-row navigation in both appearances, with exact typed fixture values.
It requires explicitly requested UI verification, Docker and an interactive
macOS session; screenshots are written to `build/r22-ui/`. Profiles, credentials,
workspace state and database tables are isolated from normal application data.

The opt-in `./scripts/test-r27-ui.sh` runner checks synchronization plans in native
windows with disposable PostgreSQL/MySQL profiles. It covers light/dark appearances,
operation selection and dependencies, manual/empty plans, native Save dialogs,
keyboard actions and new disconnected target editor drafts. It requires explicit
UI verification, Docker and an interactive macOS session; screenshots go to
`build/r27-ui/`. The source session and target data remain unchanged by planning.
Completing the system Save dialog also requires existing Accessibility access;
that scenario is skipped without it. The runner does not request or change
privacy permissions.
Optional `--filter` arguments select focused scenarios through the same fixture
runner.

For small changes, select affected Swift suites or methods with `--filter` (a regular expression; the flag can be repeated). This mode skips Go tests. Theme and UI checks run only when selected by the filter. A complete Go race and Swift Testing run requires explicit `--all`; use it for cross-cutting changes and final verification. Without a mode, the script prints usage and exits without building or testing. CI runs the full suite.

Both `test.sh` modes build the application and run Swift Testing in a temporary test Keychain. An empty test selection is a failure. Database-dependent checks are skipped when no database is available. The test-postgres.sh and test-mysql.sh scripts start isolated Docker databases with random passwords; a missing required database is a failure.

The native host also receives a private Foundation data home under ignored
`build/`, so default workspace, investigation and snapshot stores do not read or
rewrite normal application data. The caller's `HOME`, signing identity and
Keychain setup remain unchanged. The private Foundation data is removed after
successful and failed native runs.

To run the complete native scenario with both engines:

```sh
DBEER_QA_OUTPUT_DIR="$PWD/build/qa" ./scripts/test-postgres.sh ./scripts/test-mysql.sh ./scripts/test.sh --all --require-postgres
```

Select versions with DBEER_TEST_POSTGRES_IMAGE=postgres:18 and DBEER_TEST_MYSQL_IMAGE=mysql:8.0. `test-tls.sh` creates a temporary CA and checks trust, hostname mismatch, and an untrusted certificate against a real PostgreSQL server. MySQL TLS is covered by test-mysql.sh. Containers and keys are removed after verification; diagnostic logs never contain SQL, results, or passwords. Cassandra checks run both target versions in plain and authenticated TLS modes; `--udf` enables a harmless overloaded-function safety regression in the isolated fixture. Structured per-test evidence is retained under `build/cassandra/`; missing or skipped required live scenarios fail the runner. The optional three-node profile runs schema checks while all replicas are healthy, then stops one node and verifies quorum availability and `ALL` failure against an existing schema.

Use DBEER_TEST_DSN for an existing isolated PostgreSQL test database; add `--require-postgres` to the selected mode to require it. For helper-only tests, including Linux, run `./scripts/test-go.sh`. Caches and reports live in the ignored build/ directory.

`./scripts/test-ssh-config.sh` runs transport-only OpenSSH configuration checks
against temporary loopback sshd servers, including aliases, Include, two jumps,
ProxyCommand, key review and process cleanup on cancellation or helper loss.
It creates only fixture keys and does not change the system SSH service.
For database/TLS/cancellation coverage, run
`./scripts/test-ssh.sh --engine postgresql` or
`./scripts/test-ssh.sh --engine mysql`; these use isolated Docker fixtures. None
of these SSH runners launches the application or performs UI checks.

A separate synchronous Swift Testing host runs native tests: it keeps the main run loop alive after AppKit callbacks and works around the [Swift async-main issue](https://github.com/swiftlang/swift/issues/91716). The runner requires a completed Swift Testing summary; an early exit with code 0 is a failure.

GitHub Actions covers Linux Go race tests, required PostgreSQL 16/17/18 and MySQL 8.0/8.4 with TLS, MongoDB 8.0 with TLS and a replica set, and macOS arm64 with Swift, native windows, fixtures, application builds, and a temporary Keychain.

Reproduce the separate packaged-archive acceptance run from build 5 to build 6 using Apple XCTest UI Testing:

```sh
./scripts/test-install-update.sh > build/install-update-acceptance.log 2>&1
```

Only this UI runner requires full Xcode and control of a separate application; Docker and both archives with SHA256 files are also required. Any other DBeer instance must be quit normally. The run uses isolated profiles and new test UUIDs in the regular Keychain. **October 18, 2026 — PASS**, five phases and cleanup, actual exit code 0: two-profile import, PostgreSQL/MySQL `SELECT 1` before and after updating, Cancel/Stop and Continue during a long query, UUID/draft/Keychain preservation, and normal shutdown. Native/model matrices are checked separately.

The same runner can verify an existing archive against a current signed app
without creating a release ZIP:

```sh
./scripts/test-install-update.sh \
  --baseline-archive "$PWD/build/releases/DBeer-0.1.0-6-macos-arm64.zip" \
  --candidate-app "$PWD/build/DBeer.app"
```

Repeat with the existing `DBeer-0.2.0-8-macos-arm64.zip` baseline. This mode checks
the immutable archive checksum, persistent app/helper signatures, exact migration
backups, disconnected restoration and PostgreSQL/MySQL reconnection using the
baseline's Keychain credentials. Candidate identity includes full bundle hashes
even when version/build metadata match. It uses isolated data and new fixture
credentials; it does not update the owner's installed app or certify a future
release ZIP. See [acceptance details](macos/AcceptanceTests/README.md).

## Local MCP agent access

To connect Codex, keep DBeer running and register its local MCP server:

```sh
codex mcp add dbeer -- /Applications/DBeer.app/Contents/Helpers/dbeer-core --mcp
```

Restart Codex, then ask: “Through DBeer, show the available connections.” Approve
the profiles in DBeer; access defaults to read-only, with write permission selected
separately. Revoke access in **Settings → Agents**. Adjust the application path if
DBeer is installed elsewhere. Codex desktop and CLI share this configuration.

DBeer uses the official [MCP Go SDK](https://github.com/modelcontextprotocol/go-sdk)
over stdio. For other MCP clients, configure this executable and argument:

```json
{
  "mcpServers": {
    "dbeer": {
      "command": "/Applications/DBeer.app/Contents/Helpers/dbeer-core",
      "args": ["--mcp"]
    }
  }
}
```

The first tool call asks for permission inside DBeer. Select individual
PostgreSQL, MySQL, Cassandra or MongoDB profiles; all start unselected. Reading is the default. Each
profile has a separate write checkbox, and a profile's existing readonly policy
cannot be relaxed by an agent grant. Client names are self-reported labels.
The dialog identifies each profile's server, database, account, environment and
stable identifier. Return/Escape deny access, and another prompt cannot be nested
inside an existing permission or operation review.
Grants last for the current client connection and application session. Review
active clients or revoke access in **Settings → Agents**. Restarting a client
requires fresh approval; restored documents never establish an agent grant.

The tools are `dbeer_connections` (approved profile identifiers, engine, query
language and readonly enforcement), `dbeer_catalog`, `dbeer_query` and
`dbeer_cancel`. PostgreSQL/MySQL accept SQL, Cassandra accepts CQL, and MongoDB
accepts the same single JSON find/aggregation request as the editor, all through
the query tool's `sql` string argument. MongoDB writes are limited to supported
`$out`/`$merge` aggregation stages; JavaScript, arbitrary CRUD and administrative
commands are not exposed.

Catalog kinds `schemas`, `tables` and `columns` remain available for every engine.
Cassandra also accepts `keyspaces`; MongoDB accepts `databases`, `collections` and
`fields`. Supply the SQL schema, Cassandra keyspace or MongoDB database in `schema`,
and the table/collection in `object`. MongoDB fields are sampled from at most 32
documents, rather than an exhaustive schema; `displayNotice` retains that warning.
An explicit `affectedRowCountKnown: false` means that an affected count is unknown,
including Cassandra writes. MongoDB documents retain Canonical Extended JSON.
Queries use a fresh client-chosen `queryId` UUID so a concurrent cancel call can
target them. Cancellation retires that identifier in the current client's
namespace even if the query is still queued, preventing late execution. Repeated
cancellation succeeds and reveals nothing about other clients' operations.
Each operation opens an independent database session and closes it
after completion; GUI tabs and their transactions are independent. Queries
accept one assessed SQL/CQL statement or MongoDB JSON request, return at most
1,000 rows (default 100), use a 1–60 second deadline (default 30), and cap the encoded native broker payload at
1 MiB. The MCP envelope also includes the SDK's text fallback and structured
content, so its total encoded size is larger. Query text is limited to 96 KiB,
subject to the 128 KiB encoded request limit. SQL NULL,
empty strings, text `NULL`, exact numeric strings and base64 binary cells remain
distinct. Omitted rows are marked truncated; individual cell values are never
shortened. Catalog listings are bounded and do not offer arbitrary helper calls.

Write grants retain the existing execution policy: dangerous/unknown operations
and production writes require an exact operation preview and confirmation inside
DBeer. Revocation rejects new work, cancels active operations and closes owned
sessions. Cancellation or a lost connection can leave a submitted write with an
unknown outcome; check it before retrying. Database permissions remain the strict
boundary for hidden side effects and temporary objects, as with ordinary readonly
profiles. Cassandra and MongoDB enforce readonly locally, as reported by
`readOnlyEnforcement`; restricted database roles remain the server boundary.
Cassandra keeps the profile's consistency level, does not add `ALLOW FILTERING`,
and never retries uncertain writes. Each operation has its own session, so `USE`
does not persist between calls and SQL transactions are unavailable on these
engines. A grant selects a profile/credential context; server roles determine
which databases or keyspaces that account can access. Cancellation stops waiting
and reading; it does not guarantee that the server stopped an already sent write.

The private owner-only Unix socket accepts only the same local user. MCP exposes
no credentials, arbitrary filesystem access, exports, CLI providers or password
commands. Configure SSH passwords/passphrases in DBeer first; agent operations do
not prompt for missing secrets. **Settings → Agents** keeps the latest 200 session
activity entries with client/profile identifiers, time, permission, outcome and
response size. This in-memory journal resets on quit and contains no SQL, results
or credentials. An app that is closed or unavailable produces a clear tool error.

Explicit native UI acceptance with disposable PostgreSQL, MySQL, Cassandra and
MongoDB fixtures runs via
`./scripts/test-r04-ui.sh`. It exercises production permission/confirmation dialogs
and Settings controls in both appearances, real stdio MCP cancellation/revocation
under blocked output, and focused agent regressions. The runner opens and captures
only its own test windows and requires the usual persistent signing identity.

## Releases

The current release is **0.3.0, build 12**, available with its checksum from
[GitHub Releases](https://github.com/nullawhale/dbeer/releases/tag/v0.3.0).
It contains the native macOS SwiftUI/AppKit client and bundled Go helper.
Windows/Linux GPUI candidates are outside this release. Earlier prereleases,
including [0.2.0/build 8](https://github.com/nullawhale/dbeer/releases/tag/v0.2.0-build.8),
retain their original tags, archives and checksums.

After verification on the owner's machine, `./scripts/package-release.sh` builds
with the persistent signing identity, verifies signatures, and creates
`build/releases/DBeer-<version>-<build>-macos-arm64.zip` and `.zip.sha256`. The ZIP
includes the [license](LICENSE), changelog and [installation instructions](INSTALL.md).
The script creates local files; publishing a GitHub release is a separate step.
Existing archives are never overwritten and temporary CI signatures are rejected.

The previous **0.1.0** internal release passed installation and update acceptance
from build 5 to build 6 on the current Mac. On October 18, 2026, the owner waived
that release's required second-Mac check. These historical results do not certify
the new build 12 archive. Finder/Gatekeeper and installation on a clean second
device have not been verified. An Apple Development signature is not notarization.

Windows/Linux contributions are welcome outside the release roadmap. Public overview sources:
[dbeer-landing](https://github.com/nullawhale/dbeer-landing).

## License

DBeer is licensed under the [GNU General Public License, version 3 only](LICENSE)
(`SPDX-License-Identifier: GPL-3.0-only`).

DBeer is distributed without any warranty, including the implied warranties of
merchantability or fitness for a particular purpose. See [LICENSE](LICENSE) for
the full terms.

Third-party code and resources retain their respective licenses and notices.
