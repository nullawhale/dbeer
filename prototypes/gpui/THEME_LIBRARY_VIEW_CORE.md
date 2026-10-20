# GPUI retained theme library Settings section

Task 27 is implementation code-ready on 2026-10-20. The production original
Settings owner now mounts this retained section and integrates native chooser,
background parse, exact normalized review, explicit import/recovery/removal,
ordered library/appearance publication and common-close drain. See
THEME_LIBRARY_SETTINGS.md for current ownership and evidence. Runtime/native
acceptance remains open; the macOS product stays SwiftUI/AppKit and Mac GPUI is
development only. Task 2 and all 171 native cells remain not-run.

## Owned files and actual controls

The additive `src/theme_library_view.rs` and subtree implement a retained
`ThemeLibraryView`. It mounts through the frozen Task 26
`SettingsView::set_additional_sections(Vec<AnyView>, cx)` seam and uses
`settings_view::section` for its actual section group. No existing source,
parser, asset, persistence, Settings, vendor, Cargo, Swift, Go, plan, tracker or
changelog file was edited by this independent work.

The real Kit Select browses the owner's supplied normalized library in its
original order, including all eight actual built-ins and imported themes. Both
named appearance menus must receive that same library from the owner; this view
does not invent a second catalog. Browsing changes only this section's preview.
Built-ins cannot be removed. Remove targets the exact displayed imported ID,
never an index or a later selected theme.

Real Kit buttons request a native chooser, explicit normalized import review,
commit/cancel, imported-theme removal, fixed failures, safe retry and explicit
reload. Recovery is a separately named Choose/Commit path. An unreadable fallback
permits browsing, not ordinary import/removal. Only the store-projected
`recovery_available` flag offers recovery import. Publication conflicts and
unverified publication require reload; the latter never claims unchanged bytes
or offers a blind save retry. Retry Selected File is offered only for a fixed
unreadable-source error. No native error payload or source path enters status.

The preview is one original read-only `EditorState`, created with the shared
SQL editor policy and the dedicated fixed English
`fixtures/settings-theme-library/preview.sql`. Rendering projects the actual
`EditorPalette::input_style()` using `Editor::editor_style`, preserving alpha,
fonts and normalized scope resolution. Changing browse/review/status reuses the
same editor and menu, without replacing text, caret, selection, scroll, Undo or
focus. This section never applies global appearance or touches a SQL document,
helper, database, LSP, grid, operation, SQL history or restoration DTO.

Buttons have native semantic names/IDs, the section and status use real group/
status/alert wrappers, and the preview retains the original
`InputAccessibilityGuard`. Task 26 now supplies Select native-ID forwarding on
the actual ComboBox root. Task 27 consumes that builder on
`themeLibraryScheme`, forwarding `dbeer.settings.theme-library-scheme` to its
actual ComboBox root alongside the existing name and local GPUI ID.
A wrapper ID, API call or headless finding does not prove native UIA/AT-SPI
identity. Actual keyboard, native chooser focus, IME, selection, Undo and
UIA/Narrator/AT-SPI/Orca observations remain pending.

## Public API and captured authority

The shared Task 25 writer declared `mod theme_library_view;` and `settings_view`;
both configurations typecheck them. Production Settings now consumes the section and its broad temporary dead-code
allowance is removed. Narrow identity/focus inspection APIs remain available.

```rust
let presentation = theme_library_view::Presentation::new(
    presentation_revision,
    &authoritative_themes,
    browsed_theme_id.as_deref(),
    fallback_scheme,
    library_access,
    workflow,
);
let library = cx.new(|cx| {
    theme_library_view::ThemeLibraryView::new(presentation, window, cx)
});
// Keep the entity and its LibraryEvent subscription alive in the original owner.
settings.update(cx, |settings, cx| {
    settings.set_additional_sections(vec![library.clone().into()], cx);
});
```

- `Presentation` is an immutable, nonserializable value projection, containing
  only normalized `appearance::Theme`/`EditorPalette`, browse ID, revision,
  `LibraryAccess` and `Workflow`. It has read-only accessors, `accepts`,
  `can_browse`, `can_reload`, `can_start`, `can_remove`, `cancel_action`, `error`
  and `requires_reload`. It never owns a store, mutable preferences or source
  filesystem authority. Invalid/duplicate supplied entries do not create
  ambiguous browse rows.
- `LibraryAccess` is `Writable` or
  `ReadOnly { error: theme_library::Error, recovery_available: bool }`.
  These are descriptive values, not write grants.
- `ImportMode` is `Standard` or separately explicit `Recovery`.
  `ImportRequest::new(origin_revision, nonzero_serial, mode)` returns `Option`;
  allocate it once from the original accepted chooser request.
  `PreviewToken::new(original_request, nonzero_serial)` identifies this parse
  completion. `ImportReview::new(token, &ImportPreview)` clones only the actual
  existing normalized preview. Its `preview()` can be cloned for the existing
  store reservation; `theme()` is read-only.
- `RemovalRequest::new(origin_revision, nonzero_serial, original_theme_id)`
  identifies a reserved removal/retry. Request/token getters expose the original
  revision, serial, mode/ID without native paths or payloads. Allocate monotonic
  serials with checked arithmetic; refuse exhaustion and never reuse serials
  across Cancel, reload or reopening Settings.
- `Workflow` is `Idle`, `Choosing(ImportRequest)`, `Parsing(ImportRequest)`,
  `Review(ImportReview)`, `ImportFailed { request, error }`,
  `SavingImport(ImportReview)`, `ImportSaveFailed { review, error }`,
  `Removing(RemovalRequest)`, `RemoveFailed { request, error }` or `Reloading`.
  No enum transition executes I/O. `summary`, `error`, `review` and
  `import_request` describe the projected state.
- `LibraryEvent { revision, action }` emits `Browse(id)`, `RequestImport`,
  `RequestRecoveryImport`, `CancelImport { original_request, exact_preview }`
  (field names are `request` and `preview`), `CommitImport(PreviewToken)`,
  `RetryImport(ImportRequest)`, `RetryImportSave(PreviewToken)`, `Remove(id)`,
  `RetryRemove(RemovalRequest)` or `Reload`. Every event is checked against the
  current exact presentation revision and offered action. Buttons capture their
  rendered revision and exact target. Menu values retain their revision through
  Kit's deferred confirmation; rejected confirms restore the authoritative
  display rather than leaving a false local selection.
- `ThemeLibraryView::set_presentation(next, window, cx) -> bool` accepts only a
  higher monotonic revision or an exact same-revision duplicate. A lower or
  conflicting same-revision projection is refused. Advance the revision for
  every library, browse, request, workflow or status change; never wrap.
  `presentation()` is read-only. `focus_browse(window,cx)`/`Focusable` are for
  deliberate opening focus only.
- `request_cancel_import(revision, request, preview_token, cx)` routes enclosing
  Cancel/Escape to the same event. Capture all arguments with the original
  modal handler; never look up the current request in a late old handler.
  Call `invalidate(cx)` before the original Settings/modal owner is removed.
  It invalidates editor accessibility and permanently refuses later publications
  and events. Drop also invalidates the original guard.

## Required production integration and ordering

1. Retain the single existing `LibraryStore::new(profile_store.data_owner())`
   beside the appearance owner. Load the normalized library before resolving
   application/editor selectors or publishing the first Settings presentation.
   Carry its fixed failure and exact `recovery_available` flag. Both Settings
   menus and this section use the same successfully committed library values.
2. Keep one section entity and event subscription in the original Settings/modal
   owner. Recheck that owner, exact current presentation revision, original
   request, preview/removal token and offered action in every callback, including
   chooser, parse, save, retry, reload, Cancel and close. The section's own checks
   do not give asynchronous Workspace callbacks authority.
3. On `RequestImport`/`RequestRecoveryImport`, allocate the original request
   before starting the actual native Open picker, capture its Settings/modal
   identity and original selection authority, then project `Choosing`. Filter
   JSON, JSONC, TextMate XML/binary plist and ICLS sources. Preserve native Cancel
   as cancellation, not a parse error. Retain the selected path only privately
   in the owning request/worker; never put it into `Presentation`, status, logs
   or evidence. If the original chooser is dismissed, Settings closes, reload
   starts, or another request supersedes it, invalidate that exact request.
   An old native chooser completion must never be relabeled as a new request.
4. Project `Parsing(original_request)` and call the existing
   `theme_library::preview_import(&Path)` on an owned background worker. Capture
   the request before dispatch, not after completion. Check the original owner
   and request again before publishing `Review(ImportReview)`. A canceled/late
   parsed preview is simply discarded: parsing and rendering reserve no save,
   persist no preview ID and change no preference. Retry retains the exact
   original selected file authority; use a new preview token for a new parse.
5. On accepted `CommitImport(token)`, synchronously reserve
   `reserve_import(review.preview().clone())` or, only for the explicit recovery
   token, `reserve_recovery_import(...)`, before dispatching commit. Keep the
   original request/revision/token and latest reserved mutation task. Disable
   duplicate commit, reload and Cancel while publication is in flight. Explicit
   recovery must preserve the original unreadable bytes through the store's
   existing backup path before replacement; this UI never mutates files itself.
6. On actual `CommitOutcome::Imported(theme)`, reconcile committed normalized
   library values in reservation order. The actual Swift import behavior selects
   the imported theme for the editor only. Leave application selection unchanged.
   Selecting the editor is a SEPARATE preference edit and AppearanceStore
   reservation after library success, and requires the original request/modal
   plus captured editor-choice authority to remain current. A late save terminal
   must not overwrite a newer explicit editor choice made while import was in
   flight. Never recapture a newer preferences revision to make an old request
   look current. If publication succeeded after Settings closed, preserve the
   committed library while refusing that obsolete automatic selector change.
   `Unchanged`/`Superseded` never select an uncommitted import. Do not automatically
   call load over newer pending reservations; explicit reload invalidates them.
7. On accepted `Remove(id)`, verify the current actual imported theme, allocate
   its original removal identity and synchronously `reserve_remove(id)`. Only
   `CommitOutcome::Removed(id)` authorizes
   `Preferences::remove_theme_selection(id)`. Apply that to CURRENT preferences
   after success, retaining newer unrelated choices, then separately reserve the
   resulting appearance save. Failed, unchanged or superseded removal never
   resets selectors. Missing IDs resolve through existing appearance fallback.
8. Present only fixed `theme_library::Error` values. Plain `LibraryWrite` may
   retry the same retained import/removal intent via a new ordered reservation.
   Conflict/read refusal/recovery-required and `PublishedUnverified` require an
   explicit reload; never blindly retry ambiguous publication. Explicit Reload
   invalidates outstanding chooser/parse/preview ownership before loading and
   publishing current saved values. Cancel before publication discards the
   uncommitted review and returns to the authoritative browse preview; it
   restores no preference snapshot because previews never changed preferences.
9. Closing Settings cancels/dismisses its native chooser and discards uncommitted
   parse/review ownership before `invalidate`. A publication already dispatched
   cannot be declared canceled or rolled back merely by hiding the section.
   Keep its owner/task alive, reconcile actual publication and suppress obsolete
   selector events. Integrate the latest library mutation AND latest appearance
   save into the existing awaited normal-close finalizer. Later reservations
   invalidate older finalizer captures; a pending/failed/ambiguous save cannot
   be reported as successfully drained. Preserve every existing SQL/file/edit/
   transaction/unknown-outcome/Cancel guard and data-directory lifetime.

## Prepared verification and deferred evidence

Dedicated `fixtures/settings-theme-library/` contains the fixed preview SQL,
synthetic JSONC import and immutable action matrix. Prepared pure tests cover
the actual supplied catalog, selector immutability, imported-only removal,
uncommitted normalized review, exact request/preview/revision matching, chooser/
parse Cancel, separately explicit recovery, safe retry, conflict/unverified
publication refusal and serial guards. Prepared `native-smoke` retained Kit
cases cover original menu/editor entity, text/selection/scroll/focus preservation
across browse/review/cancel palettes, actual visible import/commit/cancel buttons,
stale menu restoration, monotonic publications and closed-owner event refusal.
These cases do not claim real native chooser or persistence integration.

Completed independent checks: rustfmt parsed/formatted only the owned module
tree, dedicated fixture structure inspection, owned-file whitespace and Cyrillic
scans. No runtime Rust/Swift/Go/DB/UI/credential/clipboard test or probe ran. At
source freeze this module was not declared/typechecked; the sole shared writer
owns declaration and coordinated all-target checks. A later compile/Clippy
summary must be recorded separately and cannot be inferred from rustfmt.

After all remaining implementation through Task 32 and actual integration, run
with completed summaries:

```sh
./scripts/gpui-prototype.sh test --locked -- theme_library_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- theme_library_view:: --test-threads=1
```

Then execute actual Settings chooser/cancel/review/import/remove/restart, source
deletion, newer editor-choice versus late import, close/reopen/reload versus late
chooser/parse/save, write/locked/conflict/unverified errors, explicit corrupt/
future recovery and exact backup preservation on Windows 11 and Ubuntu 24.04
Wayland/X11. Observe independent selectors, retained SQL/editor/grid/operation
state, all dialogs/popups, native focus/keyboard/IME/Undo/accessibility and DPI.
Headless Mac compilation or these prepared cases cannot establish that evidence.

## Task 25 declaration checkpoint

After the independent core's source freeze, the sole shared Task 25 writer
declared `mod theme_library_view;` and compiled it in default/native-smoke
all-target check and Clippy with warnings denied. Narrow compile-only corrections
use explicit native-test imports to avoid recursive test macro resolution and
attach existing Group/Alert/Status semantics to actual Stateful Div IDs. Public
reexports remain intentionally unused until production Task 27 integration.
Runtime tests and native selector/library/import acceptance remain unrun; startup,
chooser/parser/publication/persistence/close owner wiring remains Task 27 work.
Logs: ignored `build/gpui/task25-*.log`.


## Task 26 owner handoff

Workspace now retains `appearance_settings::State`. Reuse its existing
`library_store`, `themes`, `library_error` and `library_recovery_available`, all
loaded before appearance preferences resolve. Do not create a second library or
data-directory owner. The real Settings entity/subscription/focus is in that
state; add this library section to that original dialog. Current appearance
choice/save/resolve/publication helpers may receive narrow sibling visibility as
Task 27 consumes them. Keep their original preference/presentation revisions and
ordered save/close ownership; import success is not appearance publication.
Task 26's Select::accessibility_id seam is implemented at the actual ComboBox
root; consume it on the library selector without claiming native observation.

## Task 27 production checkpoint

The preceding core handoff is now implemented by
`appearance_settings/library.rs`, retaining the original Task 26 library/appearance
stores and Settings owner. Native chooser/parse authority is captured before
awaiting; previews reserve nothing, explicit commits reconcile normalized values,
and original preference revisions gate the editor-only automatic selection.
Only successful Removed resets matching current preferences. Original request AND
preview token are captured for Escape. Dispatched jobs remain owned after hiding
Settings, and ThemeLibrary then Appearance finalizers drain their exact latest
publication evidence before SQL removal. Fixed source/native/publication errors,
explicit reload and separately authorized recovery retain original bytes and
selections. Disposable PreviewOnly access offers browsing with no personal reload.
See THEME_LIBRARY_SETTINGS.md for complete prepared cases, exact static logs,
limitations of the pinned picker and deferred native/runtime verification.
