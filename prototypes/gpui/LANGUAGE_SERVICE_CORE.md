# GPUI offline language-service core

Task 23's core and retained Workspace/editor/catalog integration are code-ready.
Runtime verification and native acceptance remain pending. Task 24's retained
completion/diagnostic presentation is code-ready; signature UI remains Task 25.
GPUI targets Windows 11 x64 and Ubuntu 24.04 x64 (Wayland and X11); Mac GPUI is a
development host. The macOS product remains SwiftUI/AppKit. Task 2 and every
frozen native acceptance cell remain open. Builds do not read ignored docs.

## Owned process and bounded transport

`src/language_service.rs` and its subtree implement a separate offline process.
The only production command is the absolute existing `platform::helper_path()`
with the exact single `--language-server` argument. The module has no shell,
database client, credential-store access, session handle or implicit connection.
It uses the existing Go `helper/internal/sqllsp` protocol and delegates every SQL
scope, completion, matcher, quoting, diagnostic and signature decision to Go.

`LanguageService::spawn(path)` performs process work and must run on an executor
worker. `initialize().await` advertises UTF-16 positions, versioned diagnostics,
plain completion edits and signature label offsets. `shutdown().await` requests
shutdown with a 400 ms deadline, queues exit, closes queues, kills/reaps only its
exact owned `Child` if needed, and joins its workers. Run teardown on a worker,
including dropping the final service clone. Explicit restart must await old
shutdown, create a fresh service, initialize, and resynchronize current documents.
Every new process has an independent generation; old captures cannot be reused.

The environment is cleared. A Windows case-insensitive allowlist retains only
SystemRoot/WinDir/TEMP/TMP, with the OS-directory aliases filled from each other.
All platforms get a fixed UTF-8 locale. No inherited PATH, home/profile variables,
database credentials, proxies, loader injection variables or Go runtime options
reach the child. The helper path override is resolved by the existing platform
layer before launch and never inherited by the offline process. stderr goes
directly to the OS null device; no thread, log or buffer retains it.

Limits are explicit: 4 MiB per JSON body, 8 KiB frame headers, 16 KiB read chunks,
32 pending requests, 32 ordinary/64 reserved control frames and 8 MiB queued
input including the active write. stdout is decoded serially and diagnostics
coalesce by URI at 32 entries/8 MiB. There are three fixed workers (stdin,
stdout, lifecycle/deadline), with no per-request/per-keystroke thread or timer.
The lifecycle worker checks timeouts and child exit every 10 ms. All errors are
fixed strings; peer errors, documents, SQL, catalog values and paths are never
formatted into logs/errors. No source-bearing result/capture implements Debug.

Dropping an in-flight completion/signature future cancels its exact request.
Timeout removes the request and queues `$/cancelRequest`; unknown late IDs cannot
regain ownership. Queue/byte limits refuse work; a failed cancellation path makes
the optional service unavailable. Go currently processes requests serially and
ignores cancel notifications; cancellation therefore invalidates client delivery
and bounded teardown remains the recovery for a stalled process.

## Versioned documents and result APIs

`update(document_id, source, dialect, ContextKey, CatalogSnapshot)` retains at
most 32 documents, 2 MiB each and 8 MiB total. A bounded-out change removes the
older document rather than allowing completion on obsolete source. Before
initialization it only retains local state. After initialization it queues
configuration plus didOpen/full didChange as one bounded writer batch. Identical
source/context is a no-op. Every source/settings/catalog change advances the
document version. Profile/dialect rebinding creates a new URI and closes the old
one. `close(document_id)` invalidates captures before notifying the child.

`ContextKey` contains an opaque optional profile ID, settings revision and
catalog revision. It is never serialized to the child. The integrator must
advance settings revisions for every endpoint/TLS/policy/profile change and
catalog revisions on invalidation/replacement/disconnect. Do not reuse a revision
for a different context. The full original connection settings/client/session
must also remain captured by the connected catalog scheduler.

`DocumentCapture` retains exact immutable source, document identity, URI,
version, dialect, context and process generation. `capture_current` checks all
identities plus the version actually sent. `completion(&capture, byte_offset)`
and `signature_help(&capture, byte_offset)` validate before dispatch and after
awaiting. Their typed results retain the capture; recheck again immediately
before publishing or editing. `drain_diagnostics()` consumes coalesced messages
and accepts only the exact current URI/version. Clear editor diagnostics/popups
when updating context, closing or losing assistance availability.

`position_at` and `offset_at` convert GPUI UTF-8 byte offsets to LSP UTF-16 line
positions. CRLF is one break and its middle is invalid; surrogate/UTF-8 interiors,
past-line columns and reversed ranges are rejected. Completion replacement
ranges are byte ranges in the capture's source. Matcher ranges and signature
parameter ranges are converted from Go UTF-16 spans to byte ranges within the
label. Plain insertions are supported; snippets/additional edits are refused.
Completion/diagnostics cap at 256 items; signature help caps at 32 overloads and
256 parameters. Label/message/type and aggregate payload limits also apply.

## Connected metadata building blocks

`CatalogPager` has no backend or session reference and cannot dispatch anything.
Only the connected catalog scheduler should construct it after explicit Connect.
Its `CatalogOwner` records original profile/settings/service/catalog revisions.
For each `next_request()` it returns the existing protocol-v3
`CatalogRequest { kind: "completion", page, ..Default::default() }`.
Dispatch using the original captured service `BackendClient`/session, then call
`accept_page(&original_owner, page, &result_sets)` after revalidating ownership.
The backend's actual `ResultSet::completion_metadata()` decoder supplies ordinal
table/view/function names, columns, foreign keys and function signatures.

Pages are sequential 200-object pages, at most 50/10,000 entries and 8 MiB retained
metadata. Truncated/malformed/stale pages fail atomically. A complete successful
`finish(&owner)` produces an immutable snapshot; failures preserve the caller's
previous snapshot. Refresh must replace the whole successful snapshot. The
snapshot supplied to Go is deterministically bounded to its actual 2,048 entries,
32,768 columns, 8,192 FK columns, 8,192 parameters and 3 MiB serialized catalog.
Oversized relations retain useful names where possible; `truncated` discloses
limits and no total-catalog completeness is implied.

Never create a connection, fetch credentials, borrow a SQL-tab session, send
transaction statements or query from editor typing, caret motion, completion,
diagnostics, restored documents or history reopening. Only explicit Connect and
Refresh schedule metadata work on the existing captured catalog service.

## Retained Workspace integration

`src/assistance.rs` and `src/assistance/runtime.rs` are the actual adapter. One
worker owns the service from spawn/initialize through shutdown and final drop.
The UI retains only a mailbox owner, latest immutable document inputs, typed
captures and diagnostics. No service clone, process join, catalog serialization
or child initialization runs on the UI thread. Dropping the last UI owner signals
bounded worker teardown. A failed worker start cannot trap SQL close.

The existing SQL editor Change subscription synchronizes stable persistent IDs,
source revisions, original opaque profile bindings, dialect and context revisions.
An 80 ms observer also handles new/restored/file/history documents, explicit
rebinding, profile/settings/service changes and active-tab rotation. Missing
profiles retain their binding and use PostgreSQL as the offline default, matching
Swift. No editor entity is reconstructed and no Undo/caret/selection/file binding
is changed. An oversized source loses assistance immediately. The active SQL tab
is admitted first; inactive LSP documents close/reopen to respect 32 documents,
2 MiB per document and 8 MiB total while ordinary editors remain retained.

One latest bounded document snapshot replaces pending edits. Completion/signature
requests coalesce by document and kind with a 16-request total cap. A new edit,
close or retry wakes the worker and drops the in-flight request future, cancelling
its exact LSP request. Each input batch drains before the next document so several
large catalog configurations cannot overflow the writer. Unchanged contexts do
not serialize/send catalog configuration on each keystroke. Retry coalesces and
reaps the old owned child before creating a new generation; it is rate limited to
one start per second. Status and Retry SQL Assistance leave editing/execution
usable after failure. Editor events never connect, read credentials or query.

`catalog/completion.rs` extends the existing bounded `Work` scheduler. Only explicit
Connect/Refresh sets pending metadata work. Every page uses the original catalog
client, settings, physical service session/epoch, work generation and refresh
revision, checked before dispatch and after await, including errors. An independent
transient service epoch distinguishes new physical attachments from ordinary tree
work generations. A complete validated pager atomically replaces the whole
snapshot and advances the catalog revision. A failed refresh preserves previous
metadata with an explicit status; disconnect/settings/helper replacement makes
that old snapshot ineligible. Successful replacement resynchronizes bound SQL
documents. Search, inspection and atomic columns/browse/columns retain their
existing scheduler, original-client and replacement-lock checks.

The single LanguageService close finalizer captures current URI/version/context/
process ownership before its future runs. Ordinary tab/clear/profile finalization
awaits didClose reaching the owned stdin writer; LSP notifications have no peer ACK.
Window close awaits owned shutdown/reap on the worker. A failed close triggers
current-context reopen without changing source revision, and a changed participant
revision reruns before the final SQL flush/removal. Pending Retry cannot spawn a
new process after a shutdown finalizer. An optional LSP failure uses bounded own
teardown and does not kill a database helper or permanently refuse SQL close.

## Narrow Tasks 24/25 handoff

- `Workspace::assistance_request(DocumentId, &App) -> Option<RequestOwner>` captures
  the actual retained SQL document. `RequestOwner` is Clone and exposes `capture`.
- `RequestOwner::completion(byte_offset).await` returns typed `CompletionBatch`;
  `signature_help(byte_offset).await` returns typed optional `SignatureHelp`.
- `Workspace::assistance_capture_current(&capture, &App)` must run immediately
  before every UI delivery and insertion. It checks actual source and frontend
  `editor_revision`, persistent document/profile/dialect/settings/catalog context,
  URI/LSP version and process generation. Tasks 24/25 additionally own current
  caret/selection/focus/IME/modal checks. Never insert via a saved active-tab index.
- `Workspace.assistance.diagnostics` is transient, keyed by persistent document ID.
  Each batch carries the exact capture; recheck before decorating. Diagnostics and
  popup state must clear on lost availability/context. Keep syntax diagnostics in
  a separate decoration namespace from existing execution/source error feedback.
- Typed Go data is already decoded: completion plain `textEdit` replacement bytes,
  `data.dbeerMatchRanges` converted from UTF-16 label spans, optional detail/kind;
  signature labels, UTF-16 parameter label spans converted to bytes, active overload
  and per-signature active parameter. Delegate SQL scope/matching/ranking/quoting,
  literal/comment suppression and built-in/user signature semantics to Go.

## Prepared verification; execution deferred

`language_service/tests.rs` prepares framing/malformed/bounds/UTF-16/CRLF,
environment, unsafe edit, signature/diagnostic, paginated metadata and immutable
context cases. `fixtures/language-service/fake_helper.rs` is a std-only executable
fixture compiled by the final tests on their native host. It asserts the exact
argument and sanitized environment, accepts only LSP methods, and simulates
normal/remote-error/malformed/timeout/child-loss cases. It records only an owned
PID marker, never documents, SQL or environment values.

At final integration, execute with completed-run summaries:

```sh
./scripts/gpui-prototype.sh test --locked -- language_service:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- language_service:: --test-threads=1
```

The adapter also prepares actor coalescing/configuration counts, pending request
interruption, source revision, didClose/reopen, owned restart/window exit, safe DTO,
active-tab bounds and retained entity cases. Catalog cases prepare atomic metadata
replacement/failure, stale physical-service epochs and real PostgreSQL/MySQL
completion pagination while an independent SQL transaction remains open. These
are prepared cases, not runtime passing evidence. Also execute actual helper
LSP/shared matcher/signature cases and the integrated Workspace cases. Compile and run on
Windows 11 and Ubuntu Wayland/X11 with matching packaged helpers. Verify real
typing/IME/focus/caret/Undo and service failure/restart separately. No runtime
Rust/Go/Swift/database/UI/credential test or native acceptance is claimed here.

Completed static evidence for Task 23 integration (2026-10-19): default and
native-smoke all-target check and Clippy with warnings denied, formatting and
whitespace. Logs are ignored `build/gpui/task23-*.log`. The existing block 0.1.6
future-incompatibility notice remains. No Rust/Go/Swift/database/UI/credential/
clipboard test, native desktop probe or Windows/Linux application build ran.
