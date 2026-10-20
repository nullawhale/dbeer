# GPUI retained appearance Settings view

Task 26's retained Settings workflow is now integrated and implementation
code-ready (2026-10-20). `appearance_settings.rs` owns startup/preferences/store,
OS observation, actual command routing and close publication. Runtime/native
acceptance remains open; see APPEARANCE_SETTINGS.md for current evidence. The
macOS product stays SwiftUI/AppKit, Mac GPUI development only, and Task 2/all 171
Windows/Linux native cells remain not-run.

## Implemented controls and ownership

`src/settings_view.rs` and its subtree provide a real retained `SettingsView`
entity, not just a Settings data model. It renders the pinned Kit 0.7.3 Select,
Button and Editor widgets using the existing global application theme roles.

The application menu offers System, Lager and Porter, followed by the supplied
normalized library. The editor menu independently offers Follow App Appearance
and the same library in the same order. Titles and normalized colors come from
the owner's `appearance::Theme` slice. There is no copied catalog, color parser,
theme renderer or preferences persistence implementation in this view.

Both controls display the committed choice, support Kit's searchable popup and
native keyboard focus, arrows, Enter and Escape, and use explicit accessible
names. Missing/future stored IDs stay selected as disabled unavailable rows;
their strings remain unchanged in the owner. The preview resolves through the
actual `Preferences::resolve` and `EditorPalette::input_style` APIs.

One synthetic read-only SQL `EditorState` is created with the existing shared
SQL editor policy when the Settings entity is created. Every render uses the
maintained `Editor::editor_style` boundary on that same entity, including opposite
application/editor modes and alpha syntax styles. Theme changes never set its
text, selection, scroll or Undo state. It retains its original accessibility
guard and stable native preview identifier. Its fixed English sample is the new
`fixtures/settings-appearance/preview.sql`; no helper, DB or LSP starts, and no
workspace documents, grids, running operations or snapshots enter the view.

Fixed status/error text uses only `appearance::StoreError`. Write failure exposes
Retry Saving and Reload Saved Settings. Corrupt/future/read failure and external
conflict expose Reload without offering a misleading Retry Save. Reload explicitly
replaces current choices; its accessible name says so. Saving/reloading disable
duplicate Reload, and Reloading disables selectors. Read-only fallback permits
preview choices while explicitly saying that they cannot be saved. Done remains
available, including unchanged read-only fallback; it emits a request to the owner
and does not declare a save successful or authorize application exit.

`section(id,title,description,cx)` and
`SettingsView::set_additional_sections(Vec<AnyView>,cx)` supply a shared native
style and scroll/footer seam for later independently owned Settings sections.
Theme import/removal and shortcut recording/rebinding are not implemented here.

## Public integration API

```rust
let presentation = settings_view::Presentation::new(
    presentation_revision,
    &preferences,
    system_scheme,
    &authoritative_themes,
    persistence_state,
);
let settings = cx.new(|cx| {
    settings_view::SettingsView::new(presentation, window, cx)
});
```

- `Presentation` is an immutable nonserializable projection. It contains selected
  display IDs/rows, the resolved `EditorPalette` and `PersistenceState`, never a
  mutable `Preferences` or store. Read-only accessors expose the choices,
  selections, editor palette, revision and persistence state.
- `PersistenceState` is `Saved`, `Saving`, `ReadOnlyFallback`,
  `SaveFailed(StoreError)`, `PreviewOnly` or `Reloading`. `can_retry`, `can_reload`,
  `choices_enabled`, `error` and `summary` describe the actual visible controls.
  These values grant no filesystem write authority.
- `SettingsEvent { revision, action }` is emitted by the retained view.
  `SettingsAction` is `ChooseApplication(String)`, `ChooseEditor(String)`,
  `RetrySave`, `Reload` or `Close`. `Presentation::accepts` rejects stale
  revisions, unavailable IDs and actions not offered by the current state.
- Menu values retain their originating presentation revision through Kit's
  deferred Confirm event. Button callbacks retain their rendered revision.
  A stale callback cannot be relabeled as an action on newer preferences.
  Kit's tentative local menu selection is restored to the owner's projected
  value before emitting or rejecting Confirm, so a rejected row cannot linger
  as though it were an accepted preference.
- `set_presentation(next,window,cx) -> bool` reuses the original controls and
  preview. Advance the monotonic presentation revision for every changed
  projection, including status, theme library, OS mode and preferences changes.
  Lower or conflicting same-revision publications are refused; exact duplicate
  projections are harmless. Revision exhaustion must refuse new work, not wrap.
- `focus_application(window,cx)`/`Focusable` are for initial dialog opening only.
  Updating a palette/status never explicitly focuses or replaces a control.
  `request_close(cx)` routes the enclosing dialog's Cancel/close path to the
  same typed Close action. `invalidate_accessibility()` must run before the
  original Settings/modal owner is removed. Drop also invalidates its guard.

`mod settings_view;` is declared and production consumes the view. The temporary
module-local dead-code allowance has been removed. Disposable workspaces use
PreviewOnly with a truthful summary and disabled Reload, while corrupt/read-only
personal settings retain explicit Reload recovery.

## Completed production ownership and native selector forwarding

Workspace retains `appearance_settings::State`, its preferences, exact original
stores/data owner, latest reserved save/completion, load/write authority and
monotonic preference/presentation revisions. Both menus use the normalized
library loaded before saved preferences resolve. Fixed library load errors render
as an Alert section without resetting saved IDs. Actual import/removal is Task 27.

The common Appearance command opens one retained Settings entity/subscription.
Every callback checks its original entity, current authoritative presentation and
origin revision. Closing routes through the typed Close event, invalidates the
preview guard, dismisses pending completion/signature ownership and restores the
original focus. Palette/status/OS updates never explicitly focus controls.

Accepted changes reserve latest full preferences before spawning; old successes
and Superseded never mark newer values Saved. Read-only previews reserve nothing,
state that restart discards them, and cannot overwrite corrupt/future bytes.
Explicit Reload is the only route back to write authority after repair. The
normal-close Appearance finalizer awaits the exact reserved publication, retains
the original store and rechecks revision before SQL finalization/removal.

The maintained `gpui-component::Select::accessibility_id` now forwards through
`gpui-base::Select::accessibility_id` to **self.base**, its actual ComboBox root.
Application and editor controls consume `dbeer.settings.application-theme` and
`dbeer.settings.editor-color-scheme`. Existing name/value/focus/disabled/keyboard/
activation/option behavior is retained; no semantic duplicate is added. Vendor
patch notices and LOCAL-CHANGES.json contain the exact changed-source provenance.
The Theme Library selector consumes the same builder in Task 27. Native UIA/
AT-SPI properties are prepared acceptance work, not observed evidence.

## Prepared verification and source freeze

New pure cases cover both selectors against the actual bundled library, System
changes, named Follow App preview, native reselection, independent selectors,
missing/future IDs, invalid/duplicate/reserved menu entries, revision-stale
choices and fixed error/retry/reload/close eligibility. The new fixture subtree
contains only synthetic English preview text and selection expectations.

Prepared `native-smoke` headless cases instantiate only the Settings view, not a
Workspace/helper/DB. They cover actual Kit keyboard menu events/Escape focus,
typed Retry/Reload/Done callbacks, stale callback refusal and retained control/
preview identity, text, selection, scroll, readonly/focus under opposite palettes.
They also cover restoring the authoritative menu display after a stale
confirmation and refusing a stale incoming presentation.
These cases are prepared code; they have not run and are not native evidence.

Owned Rust/fixture paths are at **SOURCE FREEZE** for shared declaration/checking.
Scoped rustfmt and rustfmt --check completed with exit 0 on these five owned Rust
files. An explicit scan of all eight owned source/docs/fixture files found zero
trailing-whitespace/Cyrillic/final-newline issues, and the additive JSON fixture
parsed successfully. Logs are under ignored `build/gpui/task26-settings-*`.
The Task 24 writer
had already started checks on a frozen module set, so it intentionally left
`settings_view` undeclared. All-target typecheck/Clippy of this view is pending
declaration by the next shared writer; Task 24's checks must not be attributed to
it. Record the completed-run output after declaration, and resolve any diagnostics
before production integration.

No runtime Rust/Swift/Go/DB/UI/credential/clipboard tests or probes were run.
No Windows/Linux native build, OS appearance observation or acceptance occurred.
No baseline, frozen fixture/hash/manifest, existing asset, plan checkbox, release
metadata, Git staging/branch/commit/reset/rebase/push or publication was changed.

After all remaining implementation through Task 32 is integrated, the prepared
focused commands are:

```sh
./scripts/gpui-prototype.sh test --locked -- settings_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- settings_view:: --test-threads=1
```

Then perform actual Settings/restart/System/save conflict/recovery/latest-close
and editor/grid/operation preservation workflows on Windows 11 x64 and Ubuntu
24.04 x64 Wayland/X11, with completed summaries and native evidence. Runtime
execution remains explicitly deferred until that final integration.

## Task 25 declaration checkpoint

The sole shared Task 25 writer declared `mod settings_view;`. Default/native-smoke
all-target check and Clippy with warnings denied now compile the frozen view and
its test targets. Narrow compile-only fixes replace a native test wildcard import
that recursively imported the GPUI test macro, and explicitly import the actual
TestAppContextExt trait. These changes do not implement Task 26's Workspace,
startup, persistence, OS notification or close requirements. Runtime tests and
native Settings acceptance remain unrun. Logs: ignored `build/gpui/task25-*.log`.


## Task 27 section integration

Production Appearance Settings now retains ThemeLibraryView and its subscription
beside this original view, mounting it through set_additional_sections. Both named
menus and the library section receive the same committed normalized catalog.
The library owner captures original native chooser/request/preview identities,
reserves only explicit imports/removals and composes its latest close participant
with Appearance. Task 28 may append its section beside the retained library
without replacing either preview/entity. See THEME_LIBRARY_SETTINGS.md.


## Task 28 common shortcut section

The common Settings owner now retains ShortcutSettingsView and its typed
subscription alongside the original ThemeLibraryView using the additional-section
vector. Shortcut Settings enters the same command/modal/focus path and deliberately
focuses its first retained native input initially. Every status/OS/palette/save
publication keeps those original entities. Before dialog dismissal/common close,
Workspace synchronously calls shortcut dismiss to invalidate recording, pending
capture and semantic guards, then restores the original captured focus. Shortcut
preferences/persistence/native routing/finalization live solely in the original
Workspace owner. Appearance and ThemeLibrary mutation/preview/close gates remain.
All runtime/native input/accessibility observations remain pending.
