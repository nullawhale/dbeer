# GPUI theme library Settings integration

Task 27 is implementation code-ready on 2026-10-20. Runtime verification is
explicitly deferred until final integration after Task 32. Windows 11 x64 and
Ubuntu 24.04 x64 Wayland/X11 desktop acceptance, Task 2 and all 171 native cells
remain open. The macOS product remains SwiftUI/AppKit; Mac GPUI is development
only. Builds consume checked-in source/assets/fixtures, never ignored docs or a
Mac application build.

## Original owner and native workflow

`appearance_settings::State` retains its original single `LibraryStore` and
`AppearanceStore`, both sharing `ProfileStore::data_owner()`. Startup loads the
normalized theme library before resolving saved selectors. The same eight actual
DBeer/VS Code/Solarized/JetBrains assets plus committed imports supply both named
menus and one retained `ThemeLibraryView` mounted through
`SettingsView::set_additional_sections`. The ten source assets and four original
licenses/notices remain byte-for-byte copies of Swift resources. No original Mac
asset was changed. Redistribution must include these notices.

`appearance_settings/library.rs` owns the production workflow. Every event checks
the original Settings and section entity IDs, exact immutable presentation and
monotonic presentation revision. Import requests, parse-preview tokens and
removals have checked, never-reused serials. Before dispatching the real native
Open picker, an import captures its original Settings owner, mode and preference
revision. The selected path remains private in the request/worker; previews contain
only the existing normalized Theme. JSON/JSONC, TextMate XML/binary plist, ICLS and
supported local includes use the existing bounded parser on a background worker.
There is no second parser, theme DTO or persistence implementation.

The pinned GPUI native picker exposes neither extension filters nor a cancellation
handle. Its prompt names supported suffixes and the parser checks actual selected
bytes. Native Cancel changes no selection or file. UI Cancel invalidates the exact
original request/preview; canceled native futures stay retained until the original
OS callback drains. This does not claim that an API dismissed the OS picker.
Retry of an unreadable selected source keeps its original private file authority.
A native chooser failure has a separate fixed error and offers a fresh chooser,
without pretending that a selected source exists.

Browsing and normalized review change only the section preview. They never reserve
a library write, choose an uncommitted imported ID, save preferences or start a
helper/database/LSP operation. Explicit Import synchronously reserves the original
store mutation before dispatching publication. Recovery is a separately labeled
request and commit; the store preserves an exact private nonoverwriting recovery
copy before replacing bounded corrupt/future original bytes. Unreadable/oversized/
symlink originals never receive recovery write authority. Preview-only disposable
workspaces browse built-ins with no false error, save or personal Reload action.

After actual `Imported`, the owner reconciles normalized library values in order.
The application selection remains independent. Only the original still-live
Settings/request with its ORIGINAL unchanged preference revision may select the
new scheme for the editor, through a separate AppearanceStore reservation. A
newer explicit choice during the worker, Settings close or an obsolete request
cannot be overwritten by that late automatic selection. A committed library is
retained even when the automatic selector is no longer authorized.

Remove targets an actual imported ID. Only exact successful `Removed` removes
its menu value and resets matching CURRENT preferences through
`Preferences::remove_theme_selection`, followed by the separate appearance save.
Newer unrelated choices survive. Failure, Unchanged and Superseded retain selectors;
Superseded is not proof of publication. Fixed write errors keep safe retry intent
while the original review is live; conflicts, read/recovery refusal and unverified
publication require explicit Reload. If the original controls close, fixed failure
remains visible and explicit Reload is the recovery route. Reload invalidates
uncommitted chooser/parse/review authority and publishes only to its original
Settings ticket. It does not reopen original imported source files.

## Retained controls and common close

Every library/palette/status publication reuses original menu, preview EditorState,
SQL editors, grid and operation owners. The preview retains text, caret, scroll,
Undo and accessibility guard. The existing actual ComboBox root receives
`dbeer.settings.theme-library-scheme` through maintained Select ID forwarding.
Escape captures the rendered original request AND preview token before installing
its handler; it cannot cancel a later request. Escape is disabled during library
publication; Done may hide Settings while retaining the dispatched job.

Common close invalidates the original Settings preview/chooser authority before
review, blocks new mutations, and retains every original picker/read/commit/reload
job. The ThemeLibrary finalizer waits for those exact completions and the latest
accepted mutation. Completion includes foreground reconciliation and any required
Appearance reservation. The Appearance finalizer then awaits the latest actual
preference save. Both participants retain original stores/data owner. Revision
rechecks prevent old successes or failures from authorizing/refusing a newer owner.
Failed/unverified/Superseded publication cannot authorize final SQL snapshot/removal.

Unchanged corrupt/read-only startup and canceled uncommitted preview reserve
nothing and do not force recovery to close. Existing SQL/file/draft/transaction/
Stop/unknown-outcome/Cancel decisions retain their original owners. No theme action
issues SQL, reads credentials, reconnects or replaces helper/session ownership.
No source path, native error payload, SQL, results, credential or connection string
is added to status, logs, fixture evidence or restoration/history DTOs.

## Prepared verification

New `appearance_settings/library/tests.rs` cases prepare production native chooser
responses, exact cancel/stale request refusal, explicit review without reservations,
late in-flight editor choice, original editor/section identity, normalized restart
after source removal, independent application selection, removal-before-preference
ordering, unrelated newer choices, external conflict, exact corrupt recovery,
native-future close drain and common-close latest-library/appearance revision proof.
`fixtures/theme-library-workspace/cases.json` specifies actual target workflows.
Existing parser/store/view cases and additive shared Swift/Rust theme fixtures
remain required; none is a runtime pass at this checkpoint.

After remaining implementation through Task 32, execute with completed summaries:

```sh
./scripts/gpui-prototype.sh test --locked -- theme_library:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- theme_library_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- appearance_settings:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- theme_library:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- theme_library_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- appearance_settings:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- close:: --test-threads=1
./scripts/test.sh --filter GPUIThemeParityFixturesTests --filter EditorThemeTests --filter JetBrainsEditorThemeTests
```

Then observe real Windows/Ubuntu picker Cancel/focus, locking/permissions/recovery,
all formats/alpha/fonts/scopes, source deletion/restart, failed latest saves, close
Cancel, retained editor/grid/Undo, IME/DPI and UIA/Narrator/AT-SPI/Orca on every target.
No headless test, API presence or Mac compilation establishes that acceptance.

## Task 28 handoff

Task 27 owns the original appearance/dialog/library fields and jobs in
`appearance_settings.rs` and `appearance_settings/library.rs`. Reuse them; do not
create a competing store or replace the retained section. Mount additional
Settings sections beside `dialog.library` via the existing vector seam. Keep all
original import/request/presentation/preference gates and captured Escape tuple.
`register_appearance_finalizer` registers ThemeLibrary before Appearance so the
separate required preference publication is drained. Add shortcuts under its own
purpose-bound finalizer, preserving both participants. Task 28 now declares and
mounts that retained section in the same original dialog and registers Shortcuts
separately. The original library/preference request gates and Escape tuple remain;
see SHORTCUTS_CORE.md for the integrated production contract and static evidence.


## Completed static evidence

The final coherent root Rust/consumed-fixture snapshot completed with exit 0:
default `check --locked --all-targets` (1.28s), native-smoke all-target check
(1.39s), default all-target Clippy with `-D warnings` (1.64s), native-smoke all-target
Clippy with `-D warnings` (2.06s), and root `fmt -- --check` (0.84s). Exact commands,
statuses and logs are ignored `build/gpui/task27-static-results.json` and
`task27-*.log`. The only remaining notice is the existing block 0.1.6 future
incompatibility. The Task 30 portable fault and Task 31 optional transport Rust
checkpoints were frozen for this snapshot; compilation does not complete those
later tasks.

The static source/fixture/privacy/provenance scan passed, including all fourteen
copied asset/notice bytes against Swift originals. A coordinated Task 31 Swift
`build --build-tests --disable-sandbox` compile-only invocation also covered
GPUIThemeParityFixturesTests; its completed output is
`build/gpui/task31-transport-swift/build.log` (exit 0, 17.07s). No new Task 27 Swift,
Go or vendor test code required another target build. No runtime test or probe
executed. Task 27 implementation is at full source freeze; final runtime/native
acceptance and Task 28+ integration remain open.


## Phase 2 publication correction

The theme store now uses the shared `files::CapturedDestination` and
`PreparedSave` publisher for import, removal and explicit recovery. Captured
absence uses atomic no-replace publication; the shared retained parent, original
destination identity/bytes and staged identity/content checks remain authoritative.
Both store expected-byte comparisons, the original data-owner mutation lock,
normalized validation/bounds and synchronous reservations remain in place. Only
known publication advances the expected library and returns Imported or Removed.
The theme store retains its post-publication directory durability check: a failure
reports PublishedUnverified and requires Reload, without claiming unchanged bytes.

Recovery copies use `PreparedSave::prepare_bytes_captured`, which accepts exact raw
bytes and refuses every existing capture. Corrupt non-UTF-8 originals survive
without conversion. The same private creation runs before any staging or backup
byte: protected current-token-user DACL on Windows, mode 0600 on Unix. New backup
publication never overwrites a colliding/appeared file, and failed preparation
cleans only the retained named identity. An already confirmed recovery copy stays
retained when the later primary publication fails or is superseded.

Windows unverified publication has a separate PublicationUnknown error. It keeps
saved selectors and in-memory imports unchanged, blocks retry/Cancel as proof of
no write, and requires inspection followed by Reload. Its fixed import/removal
summaries do not claim that the destination is unchanged. The existing original
Settings/request/preferences checks, separate Appearance reservation and library
before Appearance close-finalizer ordering are preserved. No SQL, helper, session,
credential, clipboard or native-probe authority is added.

Prepared actual-store regressions cover destination appearance after the final
expected-byte check, changed/replaced destinations, import/removal/recovery staging
replacement and in-place edits, a replaced captured parent, later reservations,
exact non-UTF-8 backups, foreign staging retained after backup failure, and latest
close-finalizer refusal until a later confirmed publication. Owned Windows cases
inspect empty staging and recovery descriptors under broad inheritable parent
permissions before the first byte. Shared raw-copy cases retain collision,
appeared-target and foreign-cleanup checks. All new cases are UNRUN.

The preceding Task 27 static receipt is historical. Current scoped changes and
receipt supersession are recorded in ignored
`build/gpui/reviews/phase2-smells-fixes/`; the parent owns fresh combined-source
check/Clippy/fmt evidence after all writers freeze. Scoped formatting and actual
Windows common-publisher metadata compilation are static evidence only. Runtime,
Windows/Ubuntu desktop privacy/sharing/locking, native linkage and installed
acceptance remain pending; Task 2 and all 171 native cells remain NOT RUN. The
macOS product remains SwiftUI/AppKit, with GPUI on Mac for development only.
