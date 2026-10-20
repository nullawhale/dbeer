# GPUI persistent appearance integration

Task 26 is implementation code-ready on 2026-10-20. Runtime verification remains
deferred until final integration after Task 32. Windows 11 x64 and Ubuntu 24.04
x64 Wayland/X11 native acceptance, Task 2 and all 171 native cells remain open.
The macOS product stays SwiftUI/AppKit; Mac GPUI remains development only.

## Authoritative startup and live presentation

`appearance_settings::State` is retained in the original Workspace. It creates
one `LibraryStore` and one `AppearanceStore` from `ProfileStore::data_owner()`.
It loads normalized imported themes before resolving saved selector IDs, then
applies the complete application palette before the first visible frame. Both
Settings selectors use that same eight-builtin-plus-imported library. Neither
store opens an imported source file or widens SQL restoration/history DTOs.

Settings > Appearance now opens a real retained `SettingsView` with its original
subscription, focus return and guarded preview. System/Lager/Porter or named
application schemes, independent editor schemes and Follow App Appearance are
live. The toolbar/menu Toggle Light / Dark explicitly selects the same persisted
native choice, exiting a named application scheme without changing the editor
choice. The old production-only unpersisted palette path is removed; the simple
`apply_theme` helper is confined to disposable native-smoke/test harnesses.

Every event is checked against original Settings entity identity, the current
immutable owner projection and originating presentation revision. Stale menu
confirmations, retries, reloads and closed-view events cannot acquire current
authority. Preference and presentation revisions use checked arithmetic. Initial
opening focuses the application selector; live updates never explicitly focus.
Done/Return/Escape route through the original typed Close path, invalidate preview
accessibility and restore the captured focus. Completion/signature owners are
invalidated when opening/closing Settings without editing source.

`Context::observe_window_appearance` delivers actual GPUI OS notifications. The
handler reads the window mode, performs toolkit system refresh, then reapplies
the authoritative workbench palette, including named schemes. It does not save,
change preference/source revisions, reconnect, query or replace an entity.

`Workspace::editor_palette` is the independent resolved value used by the retained
SQL Editor and both assistance popups. A read-only global projection supplies
retained SQL review previews and catalog definition editors outside Workspace's
direct render. `Editor::editor_style` preserves explicit alpha and syntax/font
rules at the actual input boundary. Native diagnostic popovers read that original
editor's explicit style; ordinary application controls and grid field editors
keep application roles. No live change writes source, selection, scroll or Undo,
or replaces document, grid, operation, helper/session or transaction ownership.

## Persistence, errors and close

An accepted writable change synchronously reserves the latest full appearance-only
preferences before dispatch. The worker retains its exact request/store; replacing
a UI observer or closing Settings does not cancel publication ownership. Its
channel closes only after recording the result, allowing both the UI and close
finalizer to await the same immutable completion. Only latest Published marks
Saved. Superseded is never publication evidence. Failed writes retain preview
and offer Retry Saving; retries reserve current preferences, never an old DTO.

Missing saved IDs remain disabled/unavailable rows and retain their original
strings while resolving safe fallback. Fixed theme-library errors appear as a
Settings Alert. Corrupt/future/duplicate/unreadable appearance originals remain
untouched and never grant write authority to fallback defaults. Read-only choices
are explicitly preview-only and say restart discards them. External repair alone
does not grant writes; explicit Reload Saved Settings replaces the preview,
invalidates older reservations and rechecks its original owner/ticket. Closing
Settings while Reload is pending invalidates that completion. Disposable
workspaces use PreviewOnly, with no personal write or misleading Reload action.

The Appearance `close::finalizers::Finalizer` registers once while open. It retains
original store, latest request completion and preference revision, and awaits
that exact save before the latest SQL snapshot/removal. The common graph rechecks
revision before handling either success or failure; an obsolete result reflushes
the latest owner. Pending/failed/Superseded publication cannot authorize exit.
Retry or explicit Reload remains available after refusal, and existing Cancel,
SQL/file/draft/transaction/unknown-outcome guards retain all original owners.
Unchanged corrupt/read-only startup and labeled previews have no accepted writable
reservation, so close does not invent a default save or require recovery to exit.

## Native selector seam

Maintained component/base `Select::accessibility_id` forwards the ID to the
existing ComboBox semantic root. Settings consumes
`dbeer.settings.application-theme` and `dbeer.settings.editor-color-scheme`, with
names Application theme and Editor color scheme. Existing values, disabled state,
focus, keyboard navigation and activation remain on the same root. There is no
second combobox or invisible semantic substitute. Exact vendor source hashes and
patch notices are updated. Actual UIA/AT-SPI identity and behavior remain
unobserved and must be verified on supported target desktops.

## Prepared cases and completed static checks

`appearance_settings/tests.rs` prepares actual startup/restart with normalized
imports and no original sources; missing IDs; corrupt/future/duplicate originals;
read-only close; broadcast completion; failed/Superseded refusal; revision
exhaustion; common menu Settings; stale/closed callbacks; independent schemes;
System/named refresh; latest reservation; retry/conflict/reload; original editor
text/selection/scroll/Undo, grid selection and running operation preservation; and
actual common-close latest-owner drain, including obsolete failure, unchanged
close token/affected scope, latest-error refusal and retry. Existing generic close
cases also prepare stale-success refusal before latest publication. Existing
appearance/Settings/native editor/core cases remain part of final verification.
`fixtures/appearance-workspace/cases.json` supplies real OS notification, native
selector/DPI, restart, repair and close/Cancel workflows. These are prepared,
unexecuted cases, not native evidence.

Completed with exit 0: default and native-smoke `check --locked --all-targets`,
both `clippy --locked --all-targets -- -D warnings` configurations, root formatting
check, scoped vendor formatting check, provenance hash and owned English/whitespace
inspection. Exact logs/statuses are ignored `build/gpui/task26-*.log` and
`build/gpui/task26-static-results.json`. Only the existing block 0.1.6 future
incompatibility notice remains. No new vendor unit test code was added, so no
separate dependency unit-target check was required. Go/Swift code was unchanged.

No runtime Rust/Go/Swift/database/UI/credential/clipboard test, target build,
native notification probe, installed-upgrade check or supported desktop acceptance
ran. No frozen baseline/manifest/hash/reference/replay, signing/trust, release
metadata or Git branch/staging/commit/publishing action changed.

After all remaining implementation through Task 32, run with completed summaries:

```sh
./scripts/gpui-prototype.sh test --locked -- appearance_settings:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- appearance:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- settings_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- appearance_settings:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- settings_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- close:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- workspace_tests --test-threads=1
```

Then execute the prepared actual Windows/Ubuntu workflows and record exact
skips/native evidence. Task 27 now integrates native theme import/review/removal,
library mutation reconciliation and latest library/appearance close finalization;
see THEME_LIBRARY_SETTINGS.md. Task 28 now mounts its retained recorder section
in this same original Settings dialog, retains one original shortcut store and
registers its separate latest-save close participant. See SHORTCUTS_CORE.md;
runtime/native acceptance remains open for all three integrated workflows.


Task 26 is at full source freeze, including its source, prepared tests/fixtures,
vendor extensions/provenance, tracked handoffs/tracker/changelog and three
implementation plan boxes. No Task 27 import/removal or Task 28 shortcut workflow
was implemented here. The next shared writer may reuse this original owner.


Task 27 mounts one retained ThemeLibraryView beside the original appearance
controls and reuses both stores. It captures original picker/request/preferences
before awaiting, reserves only explicit commits, selects the editor only after
current successful import and resets matching preferences only after Removed.
Common close invalidates original uncommitted Settings authority and drains retained
native/worker/library jobs before the separately required latest appearance save.
The implementation is code-ready; runtime/native verification remains deferred.
