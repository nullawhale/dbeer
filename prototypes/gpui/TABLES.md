# GPUI table documents

Task 15 is code-ready; runtime verification is deferred to final integration.
GPUI targets Windows 11 x64 and Ubuntu 24.04 x64 (Wayland and X11). Mac GPUI is
for development only. The macOS SwiftUI/AppKit UI and protocol v3 are unchanged.
Task 2 and all 171 native acceptance cells remain open. Builds never read ignored docs.

## Navigation and ownership

Open Data constructs a Table document before restoration scheduling. A table/view
has its own retained editor, local result filter, table filter input and transient
`CatalogDocument.table: Option<tables::TableDocument>`. It uses only the already
connected matching profile service. Browsing never connects from restoration,
typing or missing configuration and never executes, assesses or classifies SQL.
The helper adapters own quoting, capabilities, casts, ordering and pagination.
SQL documents keep their independent sessions, transactions, SET and temporary state.

`Navigation` holds zero-based page, typed server sorts and typed server filters.
The adapter returns at most 200 rows and appends missing PK columns as tie-breaks.
Previous is available after page zero. Exactly 200 loaded rows means only that a
following page is possible; an empty following page is legitimate and retains
Previous. A shorter page disables Next. Page 1,000,000 is the protocol limit;
checked arithmetic prevents overflow. No COUNT, hidden lookahead, total estimate
or extra query execution is introduced. No-PK objects, including views, warn that
no stable page order is guaranteed even without data changes, with possible
repeats/skips. Their rows are never described as reliably ordered by sample size.

Server Sort cycles ascending, descending and adapter default for the selected
column, resetting to page zero. Filter column/operator/value are drafts until
Add Filter or Enter in that value input. Adding/removing a filter resets to page
zero and loads immediately, matching the native explicit apply behavior; typing
has no debounce RPC or automatic connection. All nine typed operators are
supported: eq/ne/lt/lte/gt/gte/contains/isNull/isNotNull. NULL operators carry no
value; ordinary operators retain exact strings including empty text, literal
`NULL`, zero, large numeric strings and Base64 binary. The frontend does not
interpret numeric syntax or turn a missing value into a NULL string.

Column header sorting and the “Loaded page: local sort / filter” controls operate
only on loaded rows and never change server navigation. Local filter text stays
per document. Local sort ordinals survive successful same-metadata page/refresh
replacement and clear when metadata changes. Copy Rows retains its existing
loaded-view order and NULL/empty/literal/numeric/binary representation. Task 16
owns selection, widths, horizontal viewport, result switching and clipboard formats.

## Captures, atomic replacement and failures

Common CommandId entries cover every server action. `capture_table_action` uses
the common modal/file/closing/busy/unknown gates; dropdown items capture their
original target when the menu is built. `tables::Capture` retains document ID,
current profile settings/generation/service session/original helper, object/node,
committed navigation, snapshot/revision, action and exact filter input. Desktop
menu/shortcut navigation is unavailable in text fields. Explicit filter controls
and Enter use their own document. Neither selection after capture nor active tab
after an await can retarget the action.

`TableDocument.begin` allocates one pending revision without changing committed
navigation. `Work::Table` sends exactly columns, parameterized browse, columns,
with the same captured original service/client and bounded scheduler. Each
follow-up and both success/error terminals recheck service context and pending
revision. There is no unbounded navigation queue; busy work is disabled and the
existing latest-search coalescer drains after service work.

`validate_snapshot` requires complete metadata on both sides, exact typed
metadata equality, valid unique/contiguous PK ordinals, matching column order,
names/engines and row widths, and a complete <=200-row browse page. Catalog type
spellings are compared to themselves; row-description type aliases are not
reclassified in Rust. This catches changed/dropped columns, permissions or
metadata failures during refresh. It is an application snapshot boundary, not a
claim of a database transaction spanning the three reads.

Completion publishes typed columns (native type, nullable/default/generated,
PK/editability/reason), original structure, rows, committed page/sort/filters and
snapshot revision in one UI turn. Any failed/incomplete/stale/locked request
keeps the old columns, rows, grid and navigation together with a visible error.
Original-helper loss cannot clear a replacement connection. Refresh captures the
current explicit service and retries the retained navigation. Table/catalog
results and sessions never enter SQL draft/history DTOs; intentional document
selection/title/order still schedules the existing SQL-only snapshot.

## Adapter changes shared with Swift

MySQL missing browse objects now return a known error instead of an empty success;
the existing missing-object Go regression is updated. Both adapters emit the
accurate no-PK notice. MySQL exact integer/DECIMAL comparisons cast only the
parameter to a generated DECIMAL(65, literal scale). Go validates and normalizes
signed decimal/exponent syntax with bounded strings/integer arithmetic; no float
conversion, interpolation, native-column rounding or clamp occurs. A literal may
exceed the column's own range/scale (e.g. 1.23 < 1.234). Unsupported exact numeric
specials or values outside MySQL's 65-digit/30-fractional-place representation
fail explicitly. Other type capabilities stay with their adapters. No wire fields,
fixtures, version or Swift source change is required. Run shared Go and focused
native browse regressions during final integration.

## Task 16/17 integration APIs

- `CatalogDocument` retains object target, original structure and typed columns;
  `QueryTab.result_sets[0]` is the matching browse snapshot. Metadata ordinals
  remain authoritative; never rebuild through a name-keyed row map.
- `TableDocument.navigation`, `snapshot`, `revision`, `pending` and `possible_next`
  describe committed/pending navigation. Only `commit` advances a snapshot.
- `Request { revision, snapshot, navigation }` and `TableDocument::owns` reject
  stale page/sort/filter terminals. `fail` releases only its own pending request.
- `ReplacementLocks { inline_draft, staged_changes, previewing, applying,
  outcome_unknown, closing }` is the typed extension point for Tasks 17-19.
  Set locks before a draft/preview/apply/uncertain workflow begins. Capture,
  submission/follow-up and completion all gate replacement. A late lock rejects
  a pending snapshot without discarding original rows/drafts. Do not bypass this
  boundary with a direct `render_live_result` or metadata assignment.
- Task 16 implements retained per-result entities and exact same-schema ordinal
  widths/viewport. Same-navigation Refresh reconciles unique PK or exact unique
  no-key original rows; page/server navigation/schema/new operations invalidate
  incompatible selection. Never retarget by row index. Source ordinals and row
  IDs remain distinct from local visible indices; actual selection copy uses
  native typed/TSV formats. See GRID.md; this supersedes blanket reset guidance.
- Task 17 should use typed metadata + result columns + snapshot revision as its
  original-row capability fingerprint; views remain read-only. Apply SQL,
  capabilities and exact value interpretation belong to Go. This task adds no edits.

## Prepared verification, not executed

Pure Rust cases cover nine operators, quoted identities/injection as data,
NULL versus missing/empty/literal/zero/exact/special/binary strings, request/page
limits, invalid metadata/row widths/engine/ordinals/DDL/partial pages and all future
replacement locks. Native-smoke headless cases exercise the real Workspace
completion boundary for 200 rows, empty next page, failed Next/third-metadata
request retaining controls, stale success/error versus a later filter, per-table
retention and a late inline lock. Existing cases cover service/helper replacement,
retained editor entities, SQL transactions, disconnected restore and safe DTOs.

Prepared Go PostgreSQL/MySQL DB cases cover 200/201 rows, empty following pages,
PK tie-breaks under tied server sort, all nine operators, adjacent exact decimals
above 2^53, higher-scale literals, injection/%/_ as data, NULL/empty/literal NULL,
Base64/invalid/empty binary, no-PK views, missing tables and SQL-session isolation.
Pure MySQL cases cover int64/uint64 boundaries, 65 digits, 30 fractional places,
exponents, unsupported specials, overflow, malformed and malicious input.

Final integration commands (execute then record completed summaries and skips):

```sh
./scripts/gpui-prototype.sh test --locked -- tables::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- catalog::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- commands::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- workspace_tests --test-threads=1
./scripts/test-gpui-databases.sh
./scripts/test-go.sh
./scripts/test.sh --filter TableBrowseNavigationTests --filter CatalogCopyNameIntegrationTests --filter GridDraftTests
```

The focused Swift filters above use existing suite names. Run PostgreSQL 16/17/18 and MySQL 8.0/8.4
and actual Windows 11, Ubuntu Wayland/X11 page/filter/keyboard/native input cases.
Privileges, concurrent DDL, helper loss, delayed stale success/error, filter Enter,
no-PK order and independent SQL sessions need runtime evidence. Task 29 retains
the Ubuntu GNOME session-manager adapter gap.

Static evidence only: default/native-smoke all-target check and Clippy with
warnings denied, formatting, whitespace, and Go MySQL/session test binary compile
without execution. Logs: ignored `build/gpui/task15-*.log`. No Rust/Go/Swift/DB/UI/
credential tests ran. Cargo's existing block 0.1.6 future notice remains.

Task 17 now supplies typed local drafts and sets inline/staged/closing locks at
workflow entry. Late browse and direct render replacement refuse to overwrite a
draft. Metadata/row atomicity and same-schema selection reconciliation remain.
CHANGES.md defines immutable ChangesBatch/capability/snapshot/revision handoff;
Tasks 18-19 now consume it through PREVIEW.md and APPLY.md. Fresh-session Apply
retains authoritative completion, Unknown/ReloadRequired recovery and readonly
reload through the captured service; no local editor/staging action calls Go.
