# GPUI SQL files

Task 12 is code-ready; runtime tests and native acceptance are deferred. GPUI
is for Windows 11 x64 and Ubuntu 24.04 x64 (Wayland/X11). The macOS product
remains SwiftUI/AppKit; Mac GPUI is a development host. Task 2 and all 171
native cells remain open. Builds never depend on ignored planning documents.

## Reference behavior and commands

`ApplicationWorkspace.openSQLFile/saveSQLFile` is the Swift reference: native
multiple selection, explicit UTF-8, last-component titles, Save to the binding,
Save As with overwrite confirmation, cancellation without mutation and atomic
UTF-8 writes. Initial UTF-8 BOM signatures are consumed; saves use the captured
text's UTF-8 bytes. Embedded BOMs, non-BMP characters, empty files and CRLF are
preserved. There is no new application size or extension cutoff. Reads use
checked allocation, a metadata-sized chunked bound and before/after checks;
nonregular files, invalid UTF-8, changing reads and allocation failure are refused
before constructing a document. Each valid file in a multi-open gets its own
complete, disconnected document; another invalid selection creates no partial tab.

`OpenSql`, `SaveSql` and `SaveSqlAs` now enter the common command registry from
menus and Ctrl+O/S/Shift+S (Cmd on Mac development). The implementation calls
GPUI's real `prompt_for_paths` and `prompt_for_new_path`, including the platform
Save dialog's overwrite decision. The pinned API has no content-type filter
option: the SQL prompt and default `.sql` name are supplied without inventing an
extension rejection. Live new documents use reference `SQL N` titles. The Save
suggestion is the existing filename or `title + ".sql"`, including custom titles.
Demo sample titles retain their existing names. Cancel retains title, binding,
saved text and destination. Errors contain neither paths nor SQL.

## Capture and publication

`CommandCapture.file: Option<Arc<FileCapture>>` captures full source, source
revision, original document/profile/settings/generation, title, binding and file
revision before any await. Local Open/Save/Save As require no helper, credential,
saved-profile membership or database session. Unbound and missing-profile documents
keep their original binding identity. Open captures its intended profile context
without making an unrelated active table/inspection tab a SQL source owner.
Dispatch requires exact current source for saves. Picker/write
continuations retain one `FileRequest` token and the chosen target; they never
read the active tab or selected profile. Every successful Save chooser continuation
synchronously captures `CapturedDestination` before scheduling preparation: the
original parent handle and existing identity/stamp/exact bytes or explicit absence
remain the overwrite authority. A newly appeared destination, external edit or
replacement, or replaced parent cannot become an implicit new overwrite decision.
Save As back to its original binding uses `capture_for_binding`, comparing the
older binding before accepting the chooser snapshot. Ordinary bound Save retains
its original binding checks. Publication checks the original owner,
file metadata revision, token, prepared source and chosen destination in one
synchronous UI callback. Closing, removed documents, profile/settings changes,
replaced bindings and obsolete tokens cannot publish or reopen an origin.
Source edits after the picker began may save the captured text; the newer text
remains dirty. A late callback cannot clear another request.

Chooser saves use `files::PreparedSave::prepare_captured`; ordinary bound saves
use `prepare` with the existing `FileBinding`. The common publisher reads/locks
the original, compares the bound
file's identity/stamp and exact bytes, writes a new same-directory exclusive
temporary, syncs and verifies its bytes. It checks
the original again after the slow write. The original is never truncated.
`publish` validates the target and temporary identities, stamps and exact prepared
content in fixed-size chunks immediately before one atomic rename. New destinations use no-replace rename flags. Unix
operations and cleanup use an owned directory descriptor and no-follow opens;
retargeted parents and leaf symlinks are refused. Windows retains an owned
non-delete-shared directory and uses a relative UTF-16 owned-handle rename,
including long paths. Existing DACL/protection is copied with handle-based
GetSecurityInfo/SetSecurityInfo only at the authorized publication boundary.
Windows CREATE_NEW supplies a protected current-user-only descriptor and retained
read/write/delete/security rights before the first byte. Staging stays private
through sync and ownership checks, including new destinations and loaded exports.
Unix destination permission bits also transfer at publication. No chmod/ACL workaround is
applied to the destination. Unpublished temporaries are removed on error,
cancellation or stale ownership; a colliding, unowned temporary is not deleted.

Unix atomic replacement can replace a read-only inode through a writable parent;
its permission bits are retained. Windows read-only attributes and denied
sharing refuse preparation/replacement. Cooperative exclusive file locks are
refused on both platforms. Unix locks are advisory: unrelated editors must
cooperate, and stamp/byte checks cannot provide a filesystem compare-and-swap
against an adversarial writer racing the final rename. Normal external edits
are refused; unsupported filesystems, OS failures and power loss need native
fault validation. Directory sync after publication is best effort; a published
save is never reported as an unchanged destination because that sync failed.
Windows rename errors reconcile target/source identity once: observed publication
is accepted; observed original/absence is a write error; ambiguity reports an
explicit unverified save outcome, retains the original binding and never retries.
No broad filesystem failure guarantee is claimed from Mac compilation.

Windows definitions follow Microsoft's [FILE_RENAME_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_rename_info),
[SetFileInformationByHandle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle),
[GetSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo)
and [SetSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo).
The earlier Q1-Q8 correction metadata-typechecked the actual Windows publisher
and its tests with the Windows standard library. That isolated compile does not
establish full native application linkage or OS behavior on the Mac host.

## Tasks 13 and 22 API boundary

- `DocumentState.file: files::DocumentFile` holds `binding: Option<FileBinding>`,
  monotonic `revision`, `saved_source: Option<Arc<str>>`,
  `saved_source_revision: Option<u64>` and transient `publication_uncertain`. `FileBinding.path` is a native PathBuf;
  it and byte/stamp snapshots deliberately have no Debug or serialization.
- `DocumentFile::dirty(&str)` compares exact current editor text with the last
  opened/saved source. An unbound document with no saved source is dirty.
  `record_saved(binding, source, source_revision)` records only captured source
  and increments the file revision. Successful older saves never mark newer
  source clean. Unverified Windows publication advances file revision and keeps
  dirty true without rebinding. Source `DocumentState.generation` is independent.
- `Workspace::add_sql_tab_for_profile(title, sql, ProfileId, window, cx)` returns
  `Option<DocumentId>` and creates an explicit-profile disconnected editor;
  it never connects or executes SQL. File open uses it instead of temporarily
  retargeting selection. IDs remain monotonic and are never reused.
- `Workspace.file_request` and `file_task` own the single chooser/read/write.
  Common availability blocks overlapping workflows. Task 22 captures this owner
  in CloseFlow, retains the native future and source/destination, and awaits
  publication or safe unpublished cleanup before teardown. See CLOSE.md.
- File title/binding changes occur in `finish_file_open`/`finish_file_save`;
  Task 13 must schedule draft snapshots there as well as at editor/title/profile/
  order changes. Do not persist binding paths or saved byte/stamp state merely
  because these transient fields exist. Reference restart snapshots need title,
  text and profile, not file URLs, Undo, selection or scroll. Clearing drafts
  must never delete a saved SQL file.
- Task 13's awaited fallible final draft/history flush still belongs in
  `close::finish_close` in Finishing, before window/document removal, exit
  permission or storage-owner release. Failure retains a retryable window.

## Prepared verification, not executed evidence

Prepared cases cover UTF-8 BOM/invalid bytes, empty files, exact Unicode/CRLF,
spaces and paths over 260 characters; sync failure, dropped preparation,
external edits during preparation/publication, appeared targets, temporary
corruption/cleanup, locked files and permission preservation; Windows read-only
and deny-sharing handles, DACL snapshots and ambiguous publication classification; Unix symlink/retargeted-parent refusal. Production
headless cases exercise common menu/shortcut/button capture, real chooser
callbacks, tab/profile switches, source edits, cancellation, repeated requests,
close while choosing, removed origins, stale tokens and prepared failure without
binding changes. These cases are code, not passed tests. Windows DACL/rename
layout and failure reconciliation still require native compilation and fault
execution, along with actual chooser overwrite/filter behavior and permissions.

Static checks only: default/native-smoke all-target check and Clippy with
warnings denied, formatting and whitespace. Logs: ignored build/gpui/task12-*.log.
Cargo's existing block 0.1.6 future-incompatibility notice remains. No Rust,
Swift, Go, database, UI or credential test ran. At final integration run:

```sh
./scripts/gpui-prototype.sh test --locked -- files::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked -- commands::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- file_view::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- workspace_tests --test-threads=1
```

Use supported native Windows/Linux build runners and retain completed summaries.
Native Windows 11 and Ubuntu Wayland/X11 must verify Open/Save/Save As,
overwrite/Cancel/errors, source/focus changes, exact bytes, locking/ACLs,
long paths, symlinks/reparse points, external changes and shutdown interactions.

Task 13 now snapshots safe source/title/opaque profile/order/selection after
finish_file_open/finish_file_save and other document changes. File bindings/stamps/
saved-source/publication uncertainty remain transient. The awaited intent-specific
close flush is in RESTORATION.md; file_request still blocks close before its flow.


Task 20 introduced `CapturedDestination::capture(&Path)` and
`PreparedSave::prepare_captured(source, path, &capture)` for export targets; SQL
chooser saves now use the same authority and publisher.
Existing arbitrary bytes or explicit absence are retained before encoding;
changed/appeared paths refuse preparation. Export wraps PreparedSave without
recording a SQL binding or changing saved source. Temporary cleanup retains its
original handle and compares identity before removing the named temporary,
preserving an unrelated replacement. `Workspace.export_request` joins file guards
and Task 22 captured close waiting. See EXPORTS.md; tests remain deferred.

## Task 22 close composition

Close now captures the file_request token and retains the original native chooser,
read or prepared-write future. Wait permits only that captured Save continuation;
Stop marks cancellation and drains the future before dropping an unpublished
temporary. Open drains without adding documents to a frozen close scope. Cancel
close retains the source/editor/file binding; older Save publication leaves newer
source dirty. No picker is abandoned or redirected to another tab. Final SQL
source/history persistence remains latest-state and disconnected. See CLOSE.md.

Phase 1 quality regressions additionally prepare fresh zero-profile Open/Save/Save
As, missing-profile manual recovery, Open from inspection tabs, 8 MiB-plus file
roundtrip/restoration, secure Windows creation before any write, private staged
DACLs in a broad inheritable directory, failed/stale preparation and CREATE_NEW
collision preservation. Runtime/native execution remains deferred.

The Q9 regressions drive the actual first-Save and Save-As native prompt callbacks,
then pause the deterministic executor after destination capture and before
background preparation. Appeared targets, edited/replaced existing targets and
Unix parent replacements preserve foreign identity/bytes and the original editor
binding. Unchanged first Save and Save As (absent, existing and original-bound
targets), ordinary bound-Save conflicts, same-binding pre-chooser conflicts and
the existing bound-Save success case remain prepared. No helper, database,
credential or clipboard authority is needed for these local-file workflows.
These regressions are unrun; compilation/static evidence remains separate from
the final runtime freeze and native acceptance.
