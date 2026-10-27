# GPUI workspace foundation

Task 3 implements the workspace boundary for Windows 11 x64 and Ubuntu 24.04
x64 (Wayland and X11). The macOS product remains SwiftUI/AppKit; Mac GPUI is a
development host. On 2026-10-19 the user explicitly authorized Task 3 and all remaining
implementation while Task 2's native desktop checks remain open. Test execution
for Tasks 4 onward is deferred to final integration; compile/typecheck and static
checks may run during implementation. The tracked IMPLEMENTATION.md separates
code-ready work from deferred verification and native acceptance. This changes implementation order
only. It does not accept rendering, native input, accessibility, credentials or
any Windows/Wayland/X11 parity scenario.

## Ownership boundaries

| Module | Responsibility |
| --- | --- |
| `commands.rs` | Common command descriptors, availability, immutable captures, desktop menus and scoped default actions (COMMANDS.md) |
| `main.rs`, `startup.rs` | Probe dispatch, storage ownership, bounded explicit stdin, one workspace window, launch/key bindings |
| `model.rs` | Typed profile/document identities, document kinds, source revisions, immutable operation snapshots, session generations, execution/result ordering and state locks |
| `workspace.rs` | Workspace/entity ownership, editor subscriptions, demo execution |
| `presentation.rs`, `controls.rs` | Presentation/theme and the shared plain-text SQL editor policy |
| `live.rs`, `scripts.rs` | Immutable ordered script assessment/review/execution, cumulative display budget, Stop and authoritative terminals (SCRIPTS.md) |
| `backend.rs`, `backend_contract.rs` | Validated protocol-v3 requests, metadata, bounded streaming and terminal reconciliation (see CONTRACT.md) |
| `catalog.rs`, `tables.rs` | Separate service sessions, immutable catalog context and atomic table navigation/snapshots (TABLES.md) |
| `profiles.rs`, `connections.rs` | Profile editing, credential adapters, atomic profile storage |
| `transfer.rs`, `transfer_view.rs` | Swift-compatible portable metadata, native preview/CA remap, captured atomic export and batch append |
| `files.rs`, `file_view.rs` | Captured UTF-8 native Open/Save/Save As, atomic publication and transient saved-source/file revision state (FILES.md) |
| `close.rs`, `termination.rs` | Captured token/phase close flow, acknowledged teardown and owned-window OS hooks (CLOSE.md); Ubuntu session-manager adapter remains Task 29 |
| `instance.rs`, `platform.rs` | Kernel-released data-directory ownership and desktop services |

Document profile references and close scopes contain stable IDs, never a
profile's vector position. Saved profile identity is its existing persisted
string ID; demo IDs use a separate namespace. Document IDs are monotonic and
never reused during the workspace lifetime. UI selection indices describe only
presentation. Task 13 separately persists durable UUIDs in DocumentState::persistent_id while
keeping runtime DocumentId monotonic. See RESTORATION.md for source-only drafts,
managed history and disconnected restoration; no runtime context is serialized.
The reserved demo namespace uses `demo:`; saved IDs permit no colon, so even a
valid existing saved ID such as `demo-brewery` remains distinct.
SQL/table/inspection kinds are explicit. Table documents use captured server
navigation and atomic typed snapshots (TABLES.md); inspection uses retained read-only
definition editors. Only SQL documents enter draft/history DTOs.

A SQL document keeps the same `EditorState` entity from creation to close.
Rendering, profile selection, focus and theme changes borrow that entity; they
do not rebuild it or reassign its value. Its caret, selection, scroll and Undo
history therefore stay with the document. Source Change events advance only
that document's revision. The shared editor enables line numbers; the toolkit
paints the current line and highlights its number. Both built-in appearances
supply a visible current-line fill. GPUI uses its plain UTF-8 editor/input
handler rather than a native rich-text widget: it registers no spelling,
smart-quote/dash or rich-text conversion service. Automatic quote/bracket
completion and smart indentation are disabled. Paste consumes only clipboard
text, preserving Unicode and CRLF; file/image-only payloads are ignored. IME
remains enabled and system input settings are untouched.

## Asynchronous operations

Before asynchronous work, SQL captures document ID, profile ID, nonsecret full
connection/TLS/policy settings, source revision, operation number and session
generation. Attaching a new physical session produces another immutable context
for that same operation. The document retains the settings that created the
session; changed settings cannot reuse it. A pending operation or unknown
outcome blocks another execution. Profile edits capture original settings and cross the shared close decisions
before any persistence mutation (see LIFECYCLE.md). Existing Run/New Tab entry points respect modal
state; a late policy assessment cannot replace an unrelated dialog.

Payload validity and lifecycle ownership are separate checks. Source/settings
changes discard obsolete progress and results. The matching original terminal
still clears busy, preserves its authoritative transaction/error/unknown state,
and retires disconnected sessions. A late terminal cannot clear a newer
operation or touch another document/session generation. Each submission records
its source range/revision, outcome and ordered result-set range; the helper's
result order and exact typed values are retained. Task 8 now resolves immutable selection/current-statement fragments and records
their original source spans (PARSING.md). Current/selection Run accepts one
diagnostic-free statement; Task 10 adds explicit whole-script review and ordered
execution with per-statement results/feedback and one cumulative display budget
(SCRIPTS.md).

The originating helper client stays with each operation. Stop and approved
execution use that client. Helper invalidation leaves active tasks alive to
drain their guaranteed terminal; it must not drop an autocommit operation's
unknown result. Queued successful and connected-error terminals check the
original helper's liveness even if another tab already spawned a replacement.
They cannot retain an old session in the new helper. Losing a non-idle
transaction conservatively requires unknown-outcome acknowledgement.

Catalog operations use a separate physical session and capture stable profile
identity/settings/session/operation generation. Responses resolve the current
profile by ID, not its former index; schema lookup uses its name. Every service
entry point checks the session's creating settings **before dispatch**, and
completion checks the captured context again. SQL-tab transactions remain
independent. Close intents likewise retain IDs and wait for running work and
acknowledged disconnects. Existing transaction choices and repeated-close
protection remain; complete draft/grid/export close choices belong to later
work.

No Go adapter, helper wire contract or Swift product behavior is changed by
this foundation. Task 5 now supplies GPUI profile migration, stable saved
selection, credential rollback and the D01 new-profile policy (see PERSISTENCE.md). Display
bounds, chunk acknowledgements and guaranteed terminal draining remain in the
existing transport.

## Repeated launches and storage

The initial repeated-launch policy is safe refusal. A normal process acquires
an OS exclusive file lock in the canonical profile directory before loading
profiles or allowing profile/credential/draft/settings mutations. Creating the
private directory and nontruncating `.workspace.lock` is ownership bootstrap;
no profile or lock metadata is overwritten first. A competing process exits
with a fixed ownership error. It creates no second workspace, routes no SQL,
and neither terminates nor steals ownership from the existing process.

The open file, not a PID or the lock file's existence, owns the directory. The
kernel releases ownership on exit/crash. Keep the lock filename in place; do
not delete it as stale, since replacing its inode can defeat exclusion. A
`ProfileStore` and every prepared atomic replacement retain the same `Arc`
guard until their work is finished. Locks are advisory cooperation between
DBeer processes; they do not coordinate unrelated external editors or profile
files on unsupported network filesystems. Ownership errors fail closed.

Dedicated feasibility dispatch happens before normal storage/workspace startup.
Feature-gated smoke modes and `--demo` do not acquire/load the personal library,
and cannot save personal profiles. Native credential probes retain Task 2's
separate reserved service/account ownership workflow. They do not bypass normal
profile ownership to mutate the user's library.

## Verification and remaining acceptance

```sh
./scripts/gpui-prototype.sh test --locked -- --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- --test-threads=1
./scripts/gpui-prototype.sh clippy --locked --all-targets -- -D warnings
./scripts/gpui-prototype.sh clippy --locked --features native-smoke --all-targets -- -D warnings
./scripts/gpui-prototype.sh fmt -- --check
./scripts/test-gpui-databases.sh
```

The default tests include cross-process exclusion, exact owned-child crash and
reacquisition, profile-byte preservation, and prepared-write guard lifetime.
`workspace_tests` uses real headless GPUI views/components and production
callbacks: retained editor entity/selection/scroll/Undo, exact Unicode/CRLF
paste, stale nonempty payload discard, original-operation busy/unknown handling,
queued success/error with a live replacement helper, no catalog dispatch
under changed endpoint/TLS/policy, saved IDs resembling demo IDs, and last-tab
replacement when an unrelated dialog is present at the close callback. These tests do not inspect pixels or emulate
native accessibility/input services.

The isolated database runner now selects the native-smoke test feature and
requires both disposable server fixtures. It additionally drives production
Workspace query/Stop/transaction/catalog/close callbacks, including profile
reordering and source edits during a slow query, against PostgreSQL 17 and MySQL
8.4. Stop waits for an observer on the separate service session to see the exact
captured physical session sleeping on the server. Known terminal outcomes retain
the engine-specific transaction status; an authoritative unknown outcome must
block retry and complete the actual acknowledgement/disconnect path. The ordinary test command's DB-guarded cases return early without fixtures;
only the explicit isolated runner establishes that integration evidence. The
runner preserves existing exact-value, bounded stream, independent physical
session/temp-table, readonly, cancellation and one-shot write-policy tests.
A prior harness run rejected external reader-thread wakes; the final harness
uses GPUI's documented external-I/O/parking mode and real-time bounded waits.

Completed 2026-10-19 local results: default Rust 49 passed/0 failed/1 ignored;
isolated PG17/MySQL8.4 feature suite 65 passed/0 failed/1 ignored; default and
feature all-target Clippy with warnings denied and formatting passed. The
ignored case is the opt-in disposable macOS Keychain roundtrip. Final command
logs and structured summaries are under ignored
`build/gpui/task3-verification/`. Native harness safety: 15 Python tests passed;
parity inventory remains 57 features/57 scenarios/281 reference IDs/171 native
cells, unchanged. These are development-host results, not target-native results.

The frozen baseline's `PARITY-F09`–`PARITY-F14`, `PARITY-F45` and `PARITY-F53`
scenarios still require native execution. This task covers only their workspace
foundation: full Apply/completion sessions, script/export behavior, close graph,
command registry and installed/platform recovery remain with their later tasks.
All Task 2 checkboxes and all 171 Windows/Wayland/X11 result cells stay open.
Actual IME, clipboard interoperability, current-line rendering, dialogs, secure
stores, UIA/Narrator and AT-SPI/Orca remain unverified without owned target
desktops. No Swift suite, full engine-version matrix or additional TLS check was
run for this Rust-only change. Frozen baseline manifests/artifacts are immutable;
expected live-source drift does not update them.

Task 6 now supplies guarded profile save/delete, context actions, native CA
selection and explicit one-shot startup (LIFECYCLE.md). Its cases and TLS matrix
are prepared and compiled only; runtime/native verification remains deferred.

Task 9 routes top-level menus, shortcut actions and existing workspace controls
through one captured command boundary (COMMANDS.md). Run accepts an immutable
prepared fragment directly; later workflows remain explicitly unavailable.
Its cases are prepared and typechecked only; native/runtime acceptance is open.

Task 11 now keeps one captured CloseFlow and CloseToken across review, Stop,
transaction resolution, disconnect ACKs and finalization. See CLOSE.md for exact
continuation and Tasks 12/13/22 extension boundaries. The Windows session-end
owned-HWND bridge is prepared; native Windows compilation/delivery is unrun.
The Ubuntu GNOME session-manager adapter is an open Task 29 implementation
obligation, separate from supported Wayland/X11 compositor-close guarding.
All Task 11 runtime tests remain deferred and all native gates stay open.

Task 12 adds captured native SQL file commands (FILES.md). File open constructs
explicit-profile disconnected documents. DocumentState.file keeps transient
binding/revision and exact saved-source state independently of source generation;
an older save leaves newer text dirty. file_request owns chooser/read/write and
blocks basic close before CloseFlow creation. Task 13 supplies draft/history
persistence and fallible final flush; Task 22 extends file-owned close decisions.
Task 12 test targets are compiled only; all runtime/native acceptance is deferred.

Task 13 now supplies source-only draft/history storage and a managed History panel
(RESTORATION.md). schedule_documents(cx) follows intentional editor/title/profile/
order/selection/file changes; only SQL-kind documents enter document_snapshot.
Finishing awaits old writes and its desired snapshot, rechecks edits and retains
retryable failure before removal/exit permission. Missing/deleted profile bindings
retain SQL and require explicit rebinding. Runtime/native verification is deferred.

Task 14 now provides lazy catalog trees, bounded connected-service search and captured object actions (CATALOG.md). add_document_for_profile constructs the final Table/Inspection kind before scheduling; editors remain retained and only SQL documents persist. Task 15 extends the actual helper browse snapshot with navigation; Task 23 extends service metadata without borrowing SQL sessions.

Task 16 adds retained grid_views by operation/result, source-row IDs, visible/source
mapping, snapshot-safe actual selection copy and read-only field editors (GRID.md).
These transient entities and native clipboard payloads never enter SQL DTOs.

Task 17 adds grid_changes.rs (pure typed local drafts/immutable originals) and
changes_view.rs (captured retained editors, capability checks and local controls).
CHANGES.md records APIs for Preview/Apply and token/revision-bound deferred
Discard. Only SQL documents persist; local edits send no helper request.
