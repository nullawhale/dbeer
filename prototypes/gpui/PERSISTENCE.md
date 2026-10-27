# GPUI profile and credential persistence

The Windows/Linux client owns its own `connections.json`, credential service
`dev.dbeer.gpui-prototype`, and kernel-held data-directory lock. The macOS
SwiftUI/AppKit library and Keychain identity are never opened or migrated by
this store. Mac GPUI retains its separate development path and service.
See WORKSPACE.md for ownership and IMPLEMENTATION.md for deferred verification.

## Library versions and identity

Version 2 stores `version`, `connections`, and nullable `selectedProfileId`.
Selection refers to the unchanged opaque saved profile ID, not a vector index.
Saved IDs cannot contain a colon; reserved `demo:` identities cannot enter the
saved library. Selecting a demo clears saved selection. Startup restores only
metadata/selection and creates disconnected profiles; loading and migration do
not read passwords, connect, or execute SQL.

The former GPUI version 1 file is validated before migration. Its exact bytes,
including whitespace and line endings, are saved to
`connections.json.v1.backup` before the v2 replacement. An existing backup is
never overwritten; retries choose a unique additional backup. Failed backup
or replacement aborts migration. Backup preparation captures fresh absence and
uses the shared byte-oriented `PreparedSave` publisher, preserving exact original
bytes without decoding. The parent and retained staging handle remain anchored;
only a provably owned named staging identity can be cleaned after failure.
Late collisions and foreign replacements survive. An unverified Windows backup
publication returns `PublicationUnknown` before primary migration and retains
any published evidence. Unknown fields (including secret fields),
corrupt data, future versions, duplicate IDs, invalid settings and invalid
selection are refused without overwriting the source. Current records require
explicit policy fields. Reads are bounded to 4 MiB and refuse nonregular files,
symlinks and Windows reparse points.

Migration retains the validated exact primary bytes, stable file binding and
captured parent before backup work. The converted library is prepared against
that same authority after the required backup succeeds. An in-place edit,
replacement (including identical bytes in a new file), or changed parent refuses
migration; a later valid, corrupt or future primary is never adopted as the
expected source. A confirmed exact old backup remains retained after refusal.

New profile factories use environment `unspecified` and `readonly: false`
(user decision D01). Missing v1 policy fields retain the old `development` and
`readonly: true` defaults. Existing explicit values survive migration unchanged;
factory defaults never serve as corruption recovery for v2 files.

## Atomic mutations and recovery

All migrations, profile updates/deletions and selection writes use the mutation
mutex belonging to the existing `DataDirectory` owner. Store clones and
prepared replacements retain that owner, including during asynchronous work.
Every mutation reads the current library under the mutex; no background worker
writes a captured library snapshot. Editor updates compare the original profile
with its current persisted value and refuse stale saves. Selection requests
reserve an order before dispatch; superseded requests cannot overwrite a later
selection. Prepared files also compare their original source bytes before
replacement, refusing an intervening external change.

An update/deletion validates and serializes the full next library to a private
same-directory temporary file and syncs it before accessing credentials. If the
password is unchanged, the secure store is never accessed. Otherwise it reads
the previous optional credential, saves the replacement or deletes the item,
and atomically renames the prepared metadata over the original. A failed secure
store operation or metadata replacement restores the previous credential:
`None` deletes the item; `Some("")` recreates an empty item; other strings restore
the exact value. No other profile's credential is accessed. A native secure
store may fail after mutation, so even a reported credential failure attempts
rollback. Rollback failure has a separate fixed error; it never reports a
successful save/deletion. Metadata remains at its previous state after a
refused replacement. Review/re-enter the affected password before connecting
or retrying after rollback failure.

Missing and stored empty passwords remain distinct in secure-store operations.
Connection authentication supplies an empty password for a missing credential,
matching the Swift behavior. Locked, unavailable, denied or invalid credentials
remain errors, rather than becoming empty passwords. Platform error payloads
are never displayed or logged. Passwords never enter library metadata, backups,
command arguments, environment variables or diagnostics. Recovery deliberately
does not write a secret journal. As with the Swift implementation, process/OS
failure between the native credential operation and metadata rename is not a
cross-store transaction; final installed fault acceptance must exercise that
boundary and require credential review when appropriate.

Unix app directories are private (`0700`); only the owned app directory is
tightened, never shared parent directories. New metadata, migration backups and
temporary files use `0600`. Windows uses the user's local application-data
location; shared creation installs a protected current-user-only descriptor before
the first byte in metadata staging and exact migration backups, independent of
broader parent inheritance. Authorized replacement transfers the original
destination DACL only at publication. The required backup is synced before
primary replacement; a directory durability error retains the completed backup
and aborts migration. Windows sharing/locked-file refusal is reported and triggers
credential rollback; the original is never deleted to force a replacement.
Dropped prepared files are removed only while their named identity is still owned.

## Prepared validation, not acceptance evidence

`connections.rs` contains synthetic-store/replacement fault cases for v1 exact
backup and failed migration; missing/empty/nonempty rollback on update/deletion;
actual legacy-load protected-before-first-byte and exact-byte backup/restart;
backup name collision/late foreign destination; backup write/sync fault cleanup
with retained foreign identity and unchanged synthetic credentials;
successful backup with an in-place/replaced valid, corrupt or future primary,
same-byte identity replacement, changed Unix parent, explicit retry and restart;
read/write/delete failures before and after mutation; explicit rollback failure;
nonreplacement edits; stale editor/prepared writes; concurrent merge and ordered
selection; current/unknown/future/corrupt files; policy defaults; private files;
symlink refusal; and a Windows locked-file replacement case. Windows/Linux
adapter cases cover missing versus empty credentials and locked/unavailable
store errors. The opt-in Mac credential test targets a disposable Keychain only.
Feasibility probes retain their separate reserved service and owned-account
cleanup behavior.

Only compilation, formatting and static checks ran during Task 5. Execute the
Rust cases and actual Windows/Linux secure-store/locked-file/ACL cases at final
integration, with completed-run summaries. No native desktop, credential, UI,
database, Go or Swift test result is claimed here. Task 2 and all 171 native
acceptance cells remain open. Task 6 now implements the guarded profile lifecycle, native CA chooser and
explicit startup (see LIFECYCLE.md); its runtime verification is deferred.
Task 7 supplies portable transfer: see TRANSFER.md. Selected rows append under
the same owner mutation mutex in one validated atomic replacement, with fresh
IDs and no credential access. Concurrent additions/selection survive; changed
or deleted original records refuse stale review.

Task 13 adds a separate source-only workspace.json under this same DataDirectory
owner and mutation mutex. See RESTORATION.md for the Swift-shaped v1/v0 format,
private backups, ordered debounce, corrupt/future preservation, history and fallible
final flush. Profile metadata and credentials never enter that snapshot.
