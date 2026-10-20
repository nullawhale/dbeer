# GPUI catalog and captured object actions

Task 14 is code-ready; runtime verification is deferred to final integration.
GPUI targets Windows 11 x64 and Ubuntu 24.04 x64 (Wayland and X11); Mac GPUI is
for development. The macOS SwiftUI/AppKit product and helper protocol are unchanged.
Task 2 and all 171 native acceptance cells remain open. Builds never read ignored docs.

## Service ownership and lazy metadata

The workspace's profile service session is separate from every SQL document's
physical session. Only an explicit Connect initializes the service, including
credential lookup. Search, branch loads, inspection, Copy Name, Generate SELECT
and table browse reuse an already connected, matching service; none connects a
restored/disconnected profile, fetches credentials while typing, runs editor SQL,
or sends SET/transaction statements to a SQL tab. Helper adapters own all SQL,
quoting, privilege checks, relation capabilities and routine identities.

`catalog.rs` defines a recursive `CatalogSchema` tree with typed `NodeId` values.
Schemas expand locally into Tables, Views, Functions, Procedures and Triggers.
Each group lazily requests `objects`. Tables/views expand locally into Columns,
Keys, Indexes, Constraints and Triggers; expanding a detail group requests its
metadata. Branches retain loaded counts, progress, errors, explicit Retry and
Refresh, previous metadata on failure, empty states and display-limit notices.
Refresh of a schema/relation invalidates its children; the next group expansion
loads fresh metadata. Profile Refresh replaces roots only after success.

Object keys include schema, exact name, kind and the opaque helper identity.
Overloads with the same name have independent keys, visible identity context and
widget identities. Definition and Copy Name pass the exact helper identity;
tables/views omit identity for browse/select and detail requests as required by
the existing contract. Metadata keeps original `ResultSet` column/row arrays;
column ordinal, exact native type, generated/default/PK/editability fields and
SQL NULL remain intact. Catalog metadata never becomes a name-keyed SQL result.

Every operation captures profile ID, full settings, generation, service session,
original helper client, object/node identity and work kind. Submission and each
follow-up request recheck context. Both successful and failed terminals recheck
the original client and captured context. Reordering profiles cannot retarget a
callback. Reconnection, endpoint/TLS/policy edits and helper replacement reject
old payloads/errors. Service failure clears only its matching catalog session;
original SQL tasks still drain their authoritative terminals through live.rs.

## Search and command dispatch

Typing replaces one 250 ms timer and retains one latest query/revision. Search
uses the helper's real `search` request across connected service profiles,
independently of expansion. At most one search RPC runs globally; an in-flight
request drains, then the newest pending query replaces earlier typing. It does
not enqueue requests for each keystroke. Other service work drains first. Search
is capped by the protocol's 1,024-byte input and normal result display bounds.
Responses and errors require the same query revision; root/search branches have
separate ownership so a late expansion cannot populate a new query's tree.
Results show profile/schema context, progress, no matches, truncation and Retry.

The common `CommandId` registry includes Expand/Collapse, Refresh, Structure and
Definition, Definition, Open Data, Generate SELECT, Copy Name and Retry Search.
`capture_catalog_command` adds a typed `CatalogTarget` to `CommandCapture`;
`catalog_command` and the common dispatcher serve buttons, context menus and
Catalog desktop menus. Menu construction captures the original target. No
callback reads the newly selected node to choose its object. Double-click opens
data for tables/views and inspection for routines/triggers, matching Swift.
Modal, file-operation and global close gates remain in the common boundary.

Copy Name writes only the helper adapter's returned string. It never copies the
row label or quotes an identifier locally. Generate SELECT opens the helper's
source in a new disconnected SQL document; it neither assesses nor executes it.
Missing objects retain a visible retry/refresh message instead of apparent success.

## Documents and Tasks 15/23 integration

Inspection is a real non-SQL document with profile/schema/kind/opaque identity,
loading/error/Retry, every ordinal structure field and a retained read-only SQL
editor for selectable/copyable definitions. Routines retain exact identities.

Open Data creates `DocumentKind::Table { schema, object, object_kind }` and uses
`columns` then real helper `browse`. Task 15 brackets browse with columns reads, and columns
and rows publish together after every request and consistency check succeeds; failed Refresh keeps the previous snapshot and reports error.
The adapter returns real read-only browse pages and ordering notices.
Task 15 adds previous/next pages, server sorting/typed filters and retained
navigation state with columns/browse/columns atomic validation; see TABLES.md. No Rust SELECT/LIMIT approximation or enabled placeholder is
used. Catalog service sessions remain outside the table/SQL document DTOs.

Extension APIs and invariants:

- `Workspace::add_document_for_profile(title, source, profile, kind, window, cx)`
  constructs the final kind before the first restoration schedule. Its SQL wrapper
  remains `add_sql_tab_for_profile`. Editors are retained, never recreated in render.
- `CatalogDocument` stores captured `target`, typed `columns`, original `structure`,
  `definition` and `loading`. `QueryTab.catalog_document` owns it. `result_sets`
  holds the read-only table snapshot; `render_live_result(id, ...)` presents it.
- `CatalogObject`, `NodeId::object()` and `object_request(schema, object, kind)`
  preserve object identity and create typed helper requests without SQL/quoting.
- `refresh_catalog_document(id, ...)` captures current valid service context for
  that explicit document; `CatalogRefreshDocument` routes its button through the
  common registry. Task 15 adds `Work::Table` and its typed captured page/sort/filter
  request with atomic columns/browse/columns validation; see TABLES.md.
- `CatalogSchema.data` retains ordinal metadata for Task 23. Add completion pages
  to the same bounded service scheduler/context checks; never borrow SQL sessions
  or connect from editor typing. Full completion/FK/signature lifecycle is Task 23.
- `document_snapshot(cx)` serializes SQL-kind documents only. Table/inspection
  constructors never enter it transiently as SQL. No catalog/results/sessions or
  metadata enter draft/history DTOs. Intentional source/title/binding/order/
  selection changes still call `schedule_documents(cx)`.
- `Profile.demo` is explicit only for built-in disposable fixtures. A missing
  restored profile with `config=None`, including a demo-like saved ID, cannot
  expose demo catalog data or execute sample SQL; explicit binding is required.
- Keep file_request/modal guards, the common CloseToken, Finishing read-only
  state/latest-state flush and original helper/ACK/Stop/unknown invariants.

## Prepared verification; no runtime acceptance yet

Prepared tests in `src/catalog/tests.rs` cover lazy kinds/detail groups, quoted
names/overload identity, metadata NULL/empty/literal/ordinal values, stale search
success/error after profile reorder, stale endpoint/TLS/policy/helper context,
retry preserving metadata, atomic table refresh failure, exact adapter clipboard
content, disconnected Generate SELECT, retained editor entities, SQL transaction
isolation, missing/demo-like profiles, close before inspection completion and
250 rapid query changes with no implicit connect. A real-helper PostgreSQL/MySQL
case searches unexpanded catalogs on two service sessions, reads typed columns,
name/select/browse and independently checks the original SQL transaction stays
open. Existing Go catalog integration cases cover quoted routines/overloads,
all kinds/detail groups, access failures and adapter-generated names/definitions.

Run these at final integration with completed summaries and explicit skips:

```sh
./scripts/gpui-prototype.sh test --locked -- catalog::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- catalog::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- workspace_tests --test-threads=1
./scripts/test-gpui-databases.sh
./scripts/test-go.sh
```

Use matching native helpers/build runners on Windows/Linux. Exercise actual
context/double-click/keyboard menus, clipboard interoperability, rapid search
with delayed/stale errors/helper loss, explicit reconnect/retry and simultaneous
SQL transactions on Windows 11, Ubuntu Wayland and Ubuntu X11. PostgreSQL
16/17/18, MySQL 8.0/8.4, native UI/credential behavior and all frozen acceptance
cells remain unrun. Task 29 retains the Ubuntu GNOME session-manager adapter gap.

Static checks only: default/native-smoke all-target check and Clippy with warnings
denied, formatting and whitespace; logs are ignored `build/gpui/task14-*.log`.
Test targets are typechecked, not executed. No Rust/Swift/Go/database/UI/credential
test ran. Cargo retains the existing dependency block 0.1.6 future-incompatibility
notice. No target-native build/runtime or acceptance is inferred from Mac checks.

Task 23 now implements completion metadata paging in the same Work scheduler;
see LANGUAGE_SERVICE_CORE.md. Only explicit Connect/Refresh schedules it. Each
page checks the original physical catalog service epoch, settings/client/session,
work generation and refresh revision before dispatch and after await/error.
Successful whole-snapshot replacement resynchronizes retained SQL documents;
failed Refresh marks previous metadata explicitly. No typing/caret/diagnostic
path performs catalog work. Existing search and atomic table browse are retained.
