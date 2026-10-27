# GPUI retained shortcut Settings section

Task 28 is implementation code-ready on 2026-10-20. The section is declared and
integrated through the original Workspace and common Settings owner in
`shortcut_settings.rs` and `appearance_settings.rs`. Startup, persistent authority,
normal-close finalization, exact native routing and menu/toolbar synchronization
are implemented. This document describes the retained view contract; see
SHORTCUTS_CORE.md for production ownership and exact final commands.

The macOS product stays SwiftUI/AppKit; Mac GPUI is development only. Windows 11
x64 and Ubuntu 24.04 x64 Wayland/X11 native acceptance, Task 2 and all 171 cells
remain open. No runtime tests run until final integration after Task 32 code.

## Actual retained controls and authority

`ShortcutSettingsView` renders real pinned Kit Input and Button controls inside
the shared `settings_view::section`. It plugs into the frozen
`SettingsView::set_additional_sections(Vec<AnyView>,cx)` seam. The section owns
one original `InputState` and `InputAccessibilityGuard` for each entry of
`shortcuts::ConfigurableCommand::ALL`. Command names, defaults, custom mappings
and explicit unbinding come from the actual shortcut `Preferences` APIs. No
second command/default list, parser, persistence DTO, helper or store exists in
this view. Current labels remain authoritative until Workspace projects its
accepted value back; recording and validation use a temporary preference clone.

Each row displays the current key and Default/Custom/Unbound source, the actual
registry-derived default, Record / Rebind, Clear, Restore Default and a focused
native input. The Record button becomes Cancel Recording during capture. That
same retained button remains in the tab graph after cancellation; there is no
disappearing Cancel tab stop to receive and then lose Tab focus. Native names
include the command, current mapping and default. Real Input and Button builders
receive native accessibility identifiers. Section/row/error/status groups have
their own semantic identities; a local ElementId alone is never claimed as
Windows UIA or Linux AT-SPI identifier evidence. There are no test-only duplicate
controls or hidden focus proxies.

The original focused Input reads its own `EntityInputHandler::marked_text_range`
inside `capture_key_down`, then immediately calls `InputSafety::from_gpui` and
the actual `Recording::capture`. No cached/asynchronous safety, invented scan
code, macOS keycode, physical-key promise or fabricated composing/dead-key flag
is used. On Linux, the read therefore occurs within the existing original native
Wayland/X11 KeyDown scope. Synthetic/outside-scope Linux input remains Unknown.
Windows uses the inspected ToUnicode/character-priority contract from the
existing core; Mac development recording retains that core's conservative
named-key limits. Native target behavior remains unobserved.

IME, dead-key, unknown, character-priority and Ctrl+Alt/AltGr events reach that
original input handler. Repeats and modifier-only events never bind. Clear
Escape cancels and consumes its original event before the enclosing Dialog's
Cancel action; it does not close Settings. Clear Tab/Shift+Tab cancel, then use
the actual Window `focus_next`/`focus_prev` tab graph exactly once. Unknown or
composing events preserve their original input path. Blur, window deactivation,
recorder replacement, new presentation and explicit Settings dismissal cancel
capture. Scratch input text is never a shortcut mapping, persisted or logged;
cleanup refuses to destroy active marked text.

## Public integration API and stale-event contract

The production module is declared in `src/main.rs`. The Workspace creates one
section for its original retained Settings owner:

```rust
let projection = shortcut_settings_view::Presentation::new(
    revision,
    &workspace_shortcuts,
    shortcuts::NativePlatform::current(),
    persistence_state,
)?;
let section = cx.new(|cx| {
    shortcut_settings_view::ShortcutSettingsView::new(projection, window, cx)
});
// Keep the typed event subscription and section entity alive with Settings.
// Pass section.into() among the existing Settings additional sections.
```

`Presentation::new` validates the full actual preferences, returns the existing
`ValidationError` and keeps a nonserializable clone only for candidate validation.
`rows`, `revision`, `persistence`, `candidate(Edit)` and `accepts(Event)`
expose the immutable projection. Candidate uses the existing set/clear/default/
reset/whole-mapping validation methods and never changes the owner.

`PersistenceState` is Saved, PreviewOnly, Saving, ReadOnlyFallback(StoreError),
SaveFailed(StoreError), Reloading or Recovering. A failed load is read only:
record/clear/reset are disabled, Retry is absent, and explicit Reload is offered.
Recover Defaults appears only for read/invalid-binding fallback and describes
preserving the original bytes first. Unsafe/oversized/unreadable recovery can
still fail in the real store and must remain read only. External Conflict offers
Reload, never a misleading Retry or recovery overwrite. Only Write failure
offers Retry Saving. Status and validation text use fixed existing error enums.

`Event { scope: Scope { revision, epoch }, action }` carries its original
presentation and checked local epoch. `Action` is Edit(Edit), RetrySave, Reload
or RecoverDefaults; `Edit` is Bind(existing command, existing Shortcut), Clear,
RestoreDefault or ResetAll. Both rendered callbacks and native captures retain
their original scope. A recorder has an additional original command token.
Focus leave/return cannot revive it. A bound request remains guarded by that
original input's blur subscription until owner projection; blur invalidates even
a queued request. Epoch exhaustion refuses new work instead of wrapping.

Before accepting an emitted event, the Workspace subscriber must recheck:

1. The original Settings/modal and section entity still belong to this owner.
2. `event.scope.revision` equals the current owner projection/base revision.
3. `section.read(cx).event_is_current(event,window,cx)` is true. This checks the
   pending original scope and, for a captured Bind, the actual original focus.
4. A candidate recomputed from the **current Workspace preferences** using the
   existing shortcut APIs validates completely against the current registry.

Do not relabel an old event with a newer revision. A pending request disables
further section mutations until the owner projects its outcome. Advance the
owner's checked monotonic revision for every changed projection or handled
request, including rejected/no-change requests and persistence status; send it
with `set_presentation(next,window,cx)`. Lower and conflicting same-revision
publications are refused; exact duplicates are harmless. Updates retain every
original Input and never explicitly focus it. `focus_first`/Focusable is only
for initial navigation. Call `dismiss(window,cx)` synchronously **before** the
parent Settings/modal closes or is replaced, including its native close path;
Drop also invalidates guards. Dismissal is terminal for that section entity.

## Implemented shared persistence and command integration

The production Workspace creates exactly one `ShortcutStore` from the existing `Arc<DataDirectory>` owner,
load before the first visible frame, and keep actual preferences/load error/
latest reservation/request/save status in Workspace. Do not use SQL restoration,
history, profile transfer or the UI clone as persistence authority. Never acquire
a second data owner from Settings.

For each accepted changed candidate, validate the base revision and whole value,
then synchronously call `store.reserve(latest,platform)` **before** debounce or
spawn. Retain the store, owner, reservation revision and latest complete value.
Only that current value updates key routing/menu/toolbar labels. Published from
an older request and Superseded cannot mark the latest revision Saved. Retry
reserves the current still-valid latest preference, never an obsolete captured
DTO. Reload runs through the same store and invalidates older reservations;
publish a result only to its original still-current owner/request. Explicit
RecoverDefaults invokes the existing `recover_defaults`: preserve exact bounded
original bytes in its private exclusive nonoverwriting recovery file first,
then recover and invalidate older reservations. No UI or normal close fallback
may silently overwrite corrupt bytes or grant write authority.

Register a latest-value shortcut finalizer in the existing common close graph.
Freeze Settings mutations while final closing, retain the original store/latest
request and await the actual latest publication (`flush_latest` or retained
latest request plus `latest_saved`). A Superseded result is not latest success.
New changes require another flush. Keep retry/cancel and every existing SQL
transaction/Stop/uncertain-outcome/disconnect decision. An unchanged failed-load
default fallback has **no writable reservation** and must not trap normal close
by attempting an impossible default save. Read-only Settings never creates a
reservation. Successful explicit reload/recovery alone reestablishes authority.

Remove/replace the old configurable default key bindings when installing the
actual preference route; do not blindly install generic `KeyBinding` aliases.
Use the exact `Preferences::command_for_native` matcher inside the original
synchronous safe input callback, then enter the common Workspace command path
with Shortcut origin and its captured original document/operation. Preserve
native editing/modal/text-field/grid/IME/busy/session gates. Stop retains its
original-operation gate. Fixed registry commands, including Task 24 Complete
SQL Ctrl+Space and future additions, remain automatically protected. Read
toolbar/menu labels/tooltips from that same authoritative Preferences snapshot.
No helper call belongs in the Settings or native recorder path.

The inspected retained Input, focus/blur/window-activation, native semantic-name,
exact native safety and real traversal APIs are sufficient for this bounded
section; no missing native API was papered over. Full Task 28/29 must still prove
original Dialog Escape interception, Windows/Linux native composition/dead keys,
non-Latin defaults/AltGr and native identifiers/roles/value/focus with actual
owned desktop sessions. Mac or headless behavior cannot provide that coverage.

## Prepared verification and source freeze

Prepared pure cases cover actual registry row/default equality on all display
platforms, explicit Unbound versus Default, candidate-only clear/reset/conflicting
restore, fixed editing/completion conflicts, original revisions/epochs, repeated
recording, blur/replacement/dismissal, queued-capture focus ABA, exhaustion,
corrupt fallback/retry/reload/recovery eligibility and the additive synthetic
`fixtures/shortcut-settings/capture-safety.json` marked/dead/unknown/priority/
AltGr/repeat matrix. Prepared native-smoke headless cases use these same actual
production controls for Record/Cancel/Clear/Restore/footer requests, retained
Input identity/focus, actual marked text, stale blur and revision publications.
Named Escape/Tab cases are limited to Mac/Windows where synthetic events have
the core's named-key evidence; Linux explicitly tests refusal without its real
native scope. Real Linux Escape/Tab behavior remains target acceptance work.

Owned source paths are at **FULL SOURCE FREEZE**. Default/native-smoke all-target
check and Clippy with warnings denied, plus root fmt --check completed using Rust
1.99.1. The initial newly declared view test import issue was fixed with explicit
imports; both test-target configurations now compile. The broad temporary
module allowance is removed. Exact final statuses are in ignored
`build/gpui/task28-static-results.json` and `task28-final-*.log`.
Source/privacy/provenance scans are separate compile-time evidence. No new
vendor unit tests or Go/Swift changes require additional target builds.

The production owner additionally prepares actual shared Settings requests,
restart/recovery/reload after dismissal, original retained controls and no-backend,
composition/AltGr/native identity, latest save and common close scope cases.
These and existing pure/headless tests remain unexecuted; native observation
still requires owned Windows/Ubuntu desktops.

No Rust/Go/Swift/database/UI/credential/clipboard runtime tests or probes ran.
No native Windows/Linux build, native acceptance, plan checkbox, baseline/frozen
fixture/hash/manifest, release metadata or Git history/index was changed.

After declaration, resolve all default/native-smoke all-target check and Clippy
diagnostics before production integration. After remaining code through Task 32
is integrated, run and retain completed summaries for:

```sh
./scripts/gpui-prototype.sh test --locked -- shortcut_settings_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- shortcut_settings_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- shortcuts:: --test-threads=1
```

Then complete actual supported-target Settings/menu/toolbar/keyboard sync,
clear/reset restart, corrupt recovery, latest close and native interaction/
accessibility workflows. A prepared case or compile does not close acceptance.
