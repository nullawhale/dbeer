# GPUI SQL drafts and managed history

Task 13 is code-ready with runtime verification deferred to final integration.
Targets are Windows 11 x64 and Ubuntu 24.04 x64 (Wayland and X11). Mac GPUI is
for development; the macOS SwiftUI/AppKit product is unchanged. Task 2 and all
171 native acceptance cells remain open. Builds do not read ignored docs.

## Format and reference behavior

`restoration.rs` defines explicit `Snapshot`, `StoredDocument` and `HistoryEntry`
DTOs, independently of live `DocumentState`. The GPUI-owned `workspace.json`
uses the Swift SQLDocumentStore v1 field names and millisecond dates:

- `version`, ordered `documents`, nullable `selectedDocumentID`, `history`, and
  `historyEnabled` (default true).
- Documents contain `id` (UUID), `title`, exact `text`, and nullable `profileID`.
  GPUI profile IDs remain opaque existing saved strings, including non-UUID
  legacy identities. They are never converted to vector indices or new IDs.
- History entries contain fresh UUID `id`, `date`, nullable `documentID` and
  `profileID`, exact executed `sql`, and the reference `outcome` label.

`DocumentState::persistent_id` is the durable UUID; the monotonic `DocumentId`
continues to identify runtime operations. Every newly opened/restored tab owns
one retained EditorState. A restored tab keeps its original UUID, source, title,
profile binding and order. Selection resolves by durable UUID with first-tab
fallback. Reopening history creates a fresh document UUID and no physical session.
A missing/deleted connection retains the original opaque binding and SQL in a
visible missing-connection state. Explicit Use Selected Connection is required
before it can run; no fallback demo/session/profile is selected for it. Swift's
profile-delete UI disconnects and deletes library metadata while retaining its
SQL documents; GPUI now retains those documents too.

Only SQL-kind documents enter the snapshot. Sessions, results/rows, transaction
or uncertainty state, helpers/clients/tasks, operation/query/grant IDs, credentials,
pending database changes, file URLs/stamps/saved-source metadata, Undo, selection
and scroll do not enter it. Nothing in restore or history reopen connects,
starts a helper, assesses or executes SQL. The Mac library is never opened.

`record_statement_history` consumes the immutable execution source and exact
statement SQL at terminal recovery. Each submitted statement has a transient
`history_recorded` guard. Pending/preparation/review/denied/skipped statements do
not record. Stale terminals cannot add a second entry or record into a later
operation. Successful authoritative terminals record Completed even after a
source edit; failure labels match Swift (Query failed/cancelled/timed out,
Connection lost, Export failed, Unknown outcome). Internal close COMMIT/ROLLBACK
commands bypass history, matching the Swift close path. Disabled recording is
checked at terminal time and never retroactively appends entries.

History keeps the newest 1,000 entries from the last 30 days, with stable
insertion order for identical timestamps. Trimming occurs on record/load/save;
future timestamps follow the reference retention rule. History is shown newest
first, with UTC date/time, outcome, source preview and Open in SQL Tab. The common
History command is enabled. Its panel provides Record executed SQL, Clear History,
Clear SQL Drafts, Retry Save and Retry Load. Clear History publishes immediately;
the toggle and ordinary edits use the reference one-second debounce.

## Atomic storage and recovery

WorkspaceStore retains the same `Arc<DataDirectory>` as ProfileStore. All reads,
migrations and publications take its mutation mutex, including across clones
and background writes. Reserve a `SaveRequest` on the UI thread before dispatch;
its sequence prevents an older queued debounce from winning. A final flush takes
the same mutex, waiting for old running writes before publishing the newest state.

Absent version/v0 migrates to v1 only after a synced exact-byte private backup.
Existing backups are never overwritten; retries choose a UUID-suffixed name.
Backup creation captures fresh absence and uses the common byte-oriented
`PreparedSave` publisher, with the original parent and retained staging handle.
Its Windows protected current-user descriptor exists before the first byte;
Unix staging and the completed backup use 0600. Exact source/history bytes are
never decoded or normalized for the backup. A late collision or failed backup
aborts before primary replacement; cleanup removes only a retained owned staging
identity. Published or foreign backup evidence is retained. Unverified Windows
backup publication reports `PublicationUnknown` and leaves migration blocked.
Known-unpublished replacement failure preserves the source. Corrupt/future/unknown-key,
duplicate-ID/duplicate-key, invalid UUID/title/date/profile files are refused.
Reads reject nonregular/symlink/reparse paths, capture the regular-file length,
check allocation growth and read no more than that length plus one byte. Changed
length/metadata and incomplete/growing reads fail. Accepted editor sources have
no 8 MiB field or 64 MiB aggregate rejection; serialization uses checked buffer
growth, and all current source/history is preserved. Structural limits remain:
documents at 1,024, history input at 100,000, titles at 16 KiB and IDs/outcomes at
4 KiB, with strict JSON/schema validation. History still follows the reference
1,000-entry/30-day policy. No fallback snapshot overwrites a failed load.

Publication writes a create-new 0600 same-directory temporary, syncs it, compares
current source bytes with the loaded version again, and publishes through the
shared captured-destination PreparedSave owner. Exact temporary handle identity
and prepared bytes are rechecked before publication and owned-only cleanup.
Unix also syncs the directory (including before migration replacement). The owned
Unix directory is 0700; Windows temporary creation installs a protected
current-user-only descriptor before content, retaining the intended destination
DACL only at publication. There is no delete-destination fallback. Temporary cleanup retains
the owner guard. External changes, Windows sharing/locked files and replacement
failures produce fixed errors without SQL, credentials or filesystem paths in
logs. Advisory ownership and byte comparisons do not provide an adversarial
external-writer compare-and-swap; actual Windows/Linux filesystem/ACL/power-loss
behavior needs native fault acceptance.

Errors remain visible in the workspace and History panel. Retry Save keeps current
SQL and retries publication. After an external repair, Retry Load validates the
saved file and merges missing durable documents/history without replacing this
window's current source, selection, explicit preference changes or history clear.
It never deletes or renumbers a newer/future file to force recovery. Save SQL/Save
As remain available for manual recovery. A final flush error keeps the window and
all documents retryable and never permits exit or silently applies tab/clear removal.

## Close boundary and later-task APIs

`history_view.rs` owns Workspace restoration and scheduling:

- `document_snapshot(cx)` captures the explicit SQL-only safe DTO. Future table
  documents must keep `DocumentKind::Table`; they never serialize result/grid state.
- `schedule_documents(cx)` reserves the latest snapshot and schedules one second
  after the last change. Call after editor text, title, profile binding, document
  creation/removal/order/selection, and completed file open/save callbacks. Existing
  subscriptions/callbacks already do this; rendering never reconstructs editors.
- `RestorationState.error`, `revision` and `saved_revision` expose fixed failure
  and latest-completion state. `ready` suppresses scheduling during restore/recovery.
- `WorkspaceStore::new(ProfileStore::data_owner())`, `load`, and
  `reserve(snapshot).commit()` retain owner-scoped, fallible serialized storage.
  Do not save a whole live document or connection/profile library snapshot.

`finish_close` enters Finishing after the existing decisions and disconnect ACKs.
`flush_close_documents` captures the **desired intent**: window/profile close
preserves open SQL; tab close removes only that UUID and resolves remaining
selection; ClearDrafts removes SQL documents/selection only after all common
close guards. Profile save/delete retains SQL, so a later failed profile mutation
cannot lose drafts. No saved SQL file is deleted. Clear cancellation preserves
exact editor entities, SQL, durable state and running sessions.

Finishing owns persistence and renders editors read-only until completion/failure;
editor events cannot queue a competing full snapshot after a tab/clear flush. After awaiting the worker, it compares the latest intended
snapshot and reflushes changes made while waiting. Comparison and final removal
occur in one UI callback, before exit permission/window removal/data-owner release.
A failed flush releases close ownership, keeps documents open and schedules their
current safe state for retry. Original token/helper/transaction/unknown/Cancel
semantics remain intact. Task 22 now captures and awaits file_request in the same flow.

Tasks 14/15 should use the existing document constructors and call
schedule_documents after intentional source/title/binding/order/selection changes;
keep table/catalog/service sessions outside DTOs. Task 22 extends the same token/
Finishing boundary with staged changes/Apply/export/file decisions and must retain
the recheck loop and failure recovery. Task 26 should use a separate explicit
appearance DTO/file under the same data owner rather than widening SQL snapshots
with live settings or overwriting historyEnabled from an old preference capture.
Ubuntu GNOME logout integration remains Task 29; forced termination cannot promise
a final asynchronous flush or known database outcome.

## Prepared checks and remaining acceptance

Prepared tests cover schema allow-lists/opaque IDs/Unicode/order/selection; v0 exact
backup/defaults/retry; malformed/future/unknown/duplicate/structural rejection; large-source and
64 MiB-plus aggregate roundtrip without data omission; atomic
failure/temp cleanup/retry/external changes; private modes/symlinks/Windows locked
files; owner lifetime and ordered concurrent/final writes; stable history retention,
disabled recording and outcome labels; retained disconnected restoration/reopen;
per-statement deduplication/skipped work; actual panel toggle/clear callbacks;
clear Cancel and failed-clear recovery; and edits during a window's final flush.
They are compiled code, **not executed evidence**.

Additional prepared actual-load regressions inspect an empty v0 migration staging
handle before its first byte, then exact source/history backup and unchanged DTO
identity on restart. The Windows branch deliberately broadens only its owned
synthetic parent and retains a protected source and backup. Write/sync faults
exercise owned-only cleanup and foreign staging identity preservation; a late
foreign backup target refuses migration and remains untouched on a later retry.
These additions remain unrun and await the coordinated final test-target check.

Completed static checks only: default/native-smoke all-target check and Clippy
with warnings denied, fmt and whitespace. Logs: ignored build/gpui/task13-*.log.
No Rust/Swift/Go/database/UI/credential test ran. The existing block 0.1.6 future
incompatibility notice remains. No target-native compilation/runtime or acceptance
is claimed; all 171 native cells and Task 2 remain open.

Run at final integration with completed summaries and explicit skips:

```sh
./scripts/gpui-prototype.sh test --locked -- restoration::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked -- commands::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- workspace_tests --test-threads=1
```

Run matching native helpers/build runners on Windows/Linux. Exercise ordinary
restart, failed load/recovery, file permissions/locks, concurrent writes and close
with final edits/failed flush, both engine outcomes, history settings/clear/reopen,
and clear Cancel with saved SQL files intact on Windows 11, Ubuntu Wayland and
Ubuntu X11. Native focus, accessibility, actual disk-failure/upgrade and installed
state retention remain required acceptance work.

Task 14 uses add_document_for_profile with the final Table/Inspection kind before any schedule, keeping catalog metadata, definitions, results and sessions outside safe SQL DTOs. Profile.demo explicitly marks built-in fixtures, so config=None restored placeholders never resolve to sample catalog or SQL. See CATALOG.md.

Task 17 keeps table originals, local drafts, editor buffers and preview handoff
outside these SQL-only DTOs. Clear SQL Drafts now scopes SQL documents only,
preserving unrelated table edits and their service sessions. Its close review
and final flush continue using the captured intent and latest SQL snapshot.

Task 18's table preview/preparation/cancellation/query/session/grant state is purely
transient and remains outside SQL snapshots/history. Restoring a table or SQL
source never starts Preview. Task 22 captures Preview/Apply cleanup or review
and awaits its original owner before the existing intent-specific latest SQL flush. See PREVIEW.md.

Task 22 also awaits purpose-bound finalization participants and original owned
helper/window teardown before the final latest SQL flush. Later LSP/preferences/
theme/shortcut integrations must register their actual owners/revisions through
close::finalizers, keeping those states outside SQL snapshots. A changed participant
revision during final publication repeats its flush before removal. See CLOSE.md.

Phase 1 quality regressions also replace the actual prepared workspace temporary
with a synthetic foreign file and verify publication/cleanup refusal. The large
source case repeats a final flush after exact reload. These are prepared test
targets; runtime and ordinary native Quit/restart observation remain pending.
