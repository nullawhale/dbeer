# GPUI appearance core and integration handoff

Task 26 is implementation code-ready as of 2026-10-20. The production owner is
`src/appearance_settings.rs`: actual startup, persisted independent selectors,
retained Settings, OS notifications, SQL/review/assistance palettes and awaited
normal-close publication now consume this core. Runtime and native acceptance
remain open. The macOS product stays SwiftUI/AppKit; GPUI targets Windows 11 x64
and Ubuntu 24.04 x64 Wayland/X11. Mac GPUI is development only. Task 2 and all
171 native cells remain not-run. See APPEARANCE_SETTINGS.md for exact integration,
static evidence and final verification commands.

## Selection and normalized values

`src/appearance.rs` exposes:

- `Preferences { version, appearance_theme, application_color_theme,
  editor_color_theme }`, serialized as `version`, `appearanceTheme`,
  `applicationColorTheme`, `editorColorTheme`. These are appearance-only
  preferences, never part of `restoration::Snapshot` or live `DocumentState`.
- `NativeAppearance::{System,Lager,Porter}` has storage IDs `system`, `light`,
  `dark` and display titles System, Lager, Porter. `NATIVE` is `native`;
  `AUTOMATIC` is `automatic`, displayed as Follow App Appearance.
- `choose_application(id, themes)` selects a native appearance or valid named
  library ID. A native choice exits the named application scheme even when
  the native choice did not change. Named choices preserve the underlying native
  preference. `choose_editor(id, themes)` edits the independent editor selector.
  Invalid choices return false and do not alter either selector.
- `resolve(system: Scheme, themes: &[Theme]) -> ResolvedAppearance` is a pure
  value operation. Application and editor resolve independently. Follow App
  Appearance follows the entire named app scheme, or the native-light/native-dark
  DBeer editor matching the resolved application appearance. Unknown/missing IDs
  fall back without changing their stored strings. Unknown native values resolve
  as System. `remove_theme_selection(id)` resets only the explicitly removed ID.
- `Theme`, `Scheme::{Light,Dark}`, `Color`, `TokenRule`, and `TokenStyle` are
  normalized values matching the Swift `EditorTheme` JSON shape. Colors contain
  finite sRGB `red/green/blue/alpha` channels. `Color::hex` accepts #RGB, #RGBA,
  #RRGGBB and #RRGGBBAA. `Theme::is_valid` checks normalized bounds.

The reference is the actual Swift `AppAppearance`, `AppColorScheme`,
`EditorTheme`, `EditorThemeStore` and `AppearanceSettingsView` source. Native
editor fallback colors mirror the two local DBeer JSON assets, rather than
requiring a generated Mac resource bundle or ignored documentation.

## Palettes and live presentation

`AppPalette::from_theme` mirrors Swift's workbench key precedence, opaque
surface alpha composition, text/secondary contrast correction and accent
fallback. `AppPalette::native` supplies readable Lager/Porter application
surfaces and the DBeer amber accent. GPUI roles additionally cover hover,
active/selected, disabled, focus, buttons, inputs, dialogs/popovers, all list/table
states, menus, scrollbars, title/status bars, error/warning/success/info/link,
charts and terminal ANSI colors.

`apply_application(&ResolvedAppearance, Option<&mut Window>, &mut App)` changes
only the GPUI global presentation using Kit 0.7.3 `Theme::change` followed by
`Theme::update`. It maps **all 139 actual ThemeColor fields**, so a prior scheme
cannot leak its tokens into the next one. It does not touch Workspace, an
EditorState, document, grid, language provider, operation or SQL restoration.

`EditorPalette::from_theme` preserves the editor's alpha and normalized syntax
styles independently of the application. It exposes source/gutter/line-number/
active-line/selection/caret/invisible/diagnostic/completion-popup colors.
`EditorPalette::input_style() -> gpui_kit::base::input::InputEditorStyle` includes
an application-owned `HighlightStyleResolver`, mapping actual Tree-sitter token
categories to Swift-compatible SQL scope stacks. Bold/italic/underline/
strikethrough, background and explicit font reset survive normalized resolution.
Terminal colors and editor popup colors are value APIs; their consumers must use
these values rather than hard-coded global colors.

**Integrated render seam:** the maintained `Editor::editor_style` projects the
resolved independent `InputEditorStyle` at the actual retained input boundary.
SQL, catalog definition and SQL review previews use their original EditorState.
Completion/signature popups share `Workspace::editor_palette`; native diagnostic
popovers read the original editor's explicit style. Ordinary app/grid field
editors retain app roles. No theme change replaces text, selection, scroll or Undo.

## Owned preferences storage

Construct exactly one `AppearanceStore::new(profile_store.data_owner())` per
Workspace and clone it for workers. It retains the existing `Arc<DataDirectory>`
and uses its mutation mutex; it does not acquire a new storage owner.

- `load() -> Result<Preferences, StoreError>` reads only `appearance.json` under
  the GPUI-owned data directory. `load_or_default() -> LoadedPreferences` returns
  readable in-memory defaults and a fixed error if loading fails.
- Call `reserve(latest_preferences)` synchronously when the user makes a choice,
  before dispatch/debounce. `SaveRequest::commit() -> Result<SaveOutcome,
  StoreError>` publishes the latest reservation or returns `Superseded`. Clones
  share the sequence. Explicit load invalidates queued pre-recovery requests.
- Publication validates an explicit allow-list DTO, writes a create-new private
  same-directory temporary, syncs it, compares original bytes and reservation
  order again, atomically renames, then syncs the Unix directory. Drop removes
  temporaries while the owner remains retained. There is no delete-destination
  replacement fallback. Unix new files are 0600 and the existing data owner
  maintains its 0700 directory. Windows retains the existing per-user directory
  permissions and refuses sharing/locked-file replacement.
- Reads cap at 64 KiB and reject nonregular files, symlinks and Windows reparse
  points. Corrupt/future/unknown-field/duplicate-key files remain byte-for-byte
  untouched. Failed load never makes fallback defaults writable; explicit load
  after external repair is needed before a later save. Unknown selector strings
  within the current DTO are retained so a temporarily missing library can return.
- External changes cause a fixed conflict. Filesystem paths, credentials, SQL,
  result values and native error payloads are never logged or displayed.

Owner locking plus byte comparisons protect cooperating app writers and detect
ordinary external edits; they are not an adversarial filesystem compare-and-swap.
Actual target OS permissions, locking, durability and power-loss behavior require
native final acceptance.

## Production integration

`appearance_settings::State` is retained in Workspace and loads the original
`LibraryStore` before appearance preferences resolve. The same profile data owner
backs both stores. Settings events are checked against original entity identity,
current immutable presentation and monotonic revision. Application/editor choices
resolve live, reserve the latest full preferences synchronously, then dispatch
an owned worker. System notifications refresh toolkit mode first and reapply the
complete selected palette without saving or changing preference/source revisions.

`CommandId::Appearance` opens actual retained Settings. Toggle Light / Dark uses
the same persisted native selector. Closing Settings invalidates its preview
guard and returns original focus while store workers remain retained. Actual
ComboBox roots now receive the two documented native IDs through narrow maintained
Select builders; native target observation remains pending Task 29/acceptance.

An exact broadcast save completion supports both UI status and the Appearance
close finalizer. Only latest Published is successful drain evidence. Stale finalizer
errors as well as stale successes recheck revision before proceeding. Writable
failure remains retryable; explicit Reload replaces the preview and invalidates
pre-recovery requests. Corrupt/future startup has no writable reservation and
cannot trap normal close. Such previews say they are discarded on restart.
Disposable workspaces have an explicit PreviewOnly state and no save/reload action.

The broad temporary appearance/Settings dead-code allowances are removed. Task 27 also consumes
`remove_theme_selection` after successful removal and retains the original library
mutation owner; its former temporary field/function allowances are removed.
Production import/removal and close integration is in THEME_LIBRARY_SETTINGS.md.

## Task 27 library/import contract

Use the exported normalized `Theme` directly; do not add a competing style DTO.
Serde names are `id/name/appearance/colors/tokenRules/isImported`, with
`TokenRule {scopes,style}` and `TokenStyle {foreground,background,fontStyle}`.
`None` inherits each style property; `Some("")` explicitly clears inherited font
traits. Preserve rule order and RGBA channels through source parsing and library
persistence. `Theme::style(&[outermost, ..., innermost])` resolves dotted scopes,
comma alternatives, whitespace parent chains, `L:`/`R:` prefixes and ` - `
exclusions. Specificity then later source order determine property precedence;
unsupported grouping/intersection constructs are ignored instead of misapplied.

Task 27 supplies the complete eight-theme bundled library, source assets and
notices, JSON/JSONC/TextMate/JetBrains parsers, safe supported local includes and
private normalized import-library persistence. Existing local Swift resources
are authoritative and must remain buildable. Built-in IDs are `native-light`,
`native-dark`, `vscode-light-plus`, `vscode-dark-plus`, `solarized-light`,
`solarized-dark`, `jetbrains-light`, `jetbrains-darcula`; imported IDs use
`imported-<UUID>`. Refuse reserved selector IDs and duplicate IDs. Library recovery
must preserve corrupt original bytes before a deliberate import recovery, using
the same existing DataDirectory owner. Removing an imported theme calls
`Preferences::remove_theme_selection(id)` only after successful library removal.

Match the Swift parser limits and protections: 1 MiB/file, 4 MiB aggregate,
16 files, depth below 8, bounded 10,000 colors/rules, canonical root containment,
symlink/traversal/cycle/remote-path refusal, XML external entity refusal and
16 MiB/64-entry normalized imported-library bounds. These parsers and library
mutations are now integrated by Task 27 through the original Settings owner.

## Prepared verification and current limits

Prepared tests cover independent selectors, native reselection, System changes,
named Follow App behavior, missing/future selectors without data loss, DTO
allow-list, normalized alpha/font/scope precedence, sparse palette contrast,
139-token completeness, absent/restart/corrupt/future/duplicate/oversize storage,
external conflict/recovery, failed atomic replacement/temp cleanup, ordered and
concurrent reservations, reload invalidation, SQL-file isolation, private modes,
symlink refusal, Windows locked destination and retained ownership. A headless
native-smoke contract captures original editor text/selection/scroll/Undo,
document ID, grid entity/selection and running operation while applying several
independent palettes; it does not stand in for the pending actual Settings render
workflow or target desktop acceptance.

Only formatting and static source inspection completed in the independent core
handoff; the shared integration writer performs all-target compilation after the
source freeze and records its result separately. No runtime Rust/Swift/Go/DB/UI/
credential/clipboard tests or probes were executed. No frozen baseline/manifest/
hash/reference app or existing theme asset was rewritten.

At final integration, run the prepared cases and then actual Settings/restart/
System/preview/entity preservation workflows, reporting completed summaries:

```sh
./scripts/gpui-prototype.sh test --locked -- appearance:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- appearance:: --test-threads=1
```

Use the supported matching native build runners on Windows 11 and Ubuntu 24.04
Wayland/X11. Opposite app/editor schemes, every dialog/popup, local import source
removal, DPI/focus/IME/Undo and installed persistence require actual target
observations. Task 2 and all 171 native acceptance cells remain open.
