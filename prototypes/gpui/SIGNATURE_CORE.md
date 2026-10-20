# GPUI function signature presentation core

Task 25's production implementation is code-ready in `src/signature.rs`,
`src/signature_view.rs` and `src/signature_view/`, with retained Workspace/editor,
common command, native key and render integration. Code-ready does not establish
runtime acceptance. Runtime checks remain deferred until all remaining code
through Task 32 integrates. Windows 11 and Ubuntu 24.04 Wayland/X11 acceptance remains open;
macOS GPUI is development only and the macOS product remains SwiftUI/AppKit.

## Ownership and service boundary

The core consumes the actual Task 23 `assistance::RequestOwner` and typed
`language_service::SignatureHelp`. `Request::help().await` sends one signature
request at the original native editor's UTF-8 caret offset through the existing
bounded assistance actor. It has no backend client, catalog pager, credential
store, connection or database session. Offline built-ins and connected function
metadata use the same Go LSP boundary. Only explicit Connect/Refresh may fetch
catalog metadata; typing, caret movement, popup navigation and theme changes
must never initiate database work.

All SQL semantics stay in Go: function identity, nested calls, PostgreSQL named
and default arguments, variadic arguments, overload ranking, quoting, comments,
literal handling, and SUBSTRING FROM/FOR separators. The Rust presentation
preserves Go's full labels, parameter byte ranges, active parameter per overload,
return type text and overload order. It validates bounded, nonoverlapping UTF-8
spans and expands active highlighting only to complete graphemes for display.

The initially ranked overload appears first, followed by original service order,
with at most eight displayed at a time, matching the Swift popup. Every one of
the service's at most 32 overloads remains reachable through Previous/Next or a
current overload-selection action. Changing the displayed overload uses that
overload's own active parameter; the client does not recompute argument indices.

## Stable integration API

`Workspace.signatures` retains one `signature::Ui`, its `signature_view::State`
and one replaceable `Option<Task<()>>`. Both modules are declared in `main.rs`.
Use `completion::selections(&editor, cx)` to read the maintained pinned Kit's
actual complete selection snapshot, including independent selection/focus
revision. Never synthesize a collapsed selection from an active range.

`Workspace::start_signatures` captures the shared `completion::Stamp` before
its 75 ms automatic debounce: original document/editor, full native document and
selection/focus revisions, profile/settings, physical catalog-service generation,
catalog and assistance revisions. It also retains the actual LSP process
generation. An admitted replacement cancels the original task synchronously;
source synchronization retries are bounded to five 40 ms waits and never fetch
metadata. All timer/request/reply boundaries re-enter current Workspace context.
Null and failed responses settle the original stamp, preventing render loops.

Source Change (including Undo/Redo/programmatic changes), the actual retained
editor observer and render call `refresh_signatures`. Blur, window activation,
tab switching, close, explicit Retry, modal and unavailable native context
invalidate it. Process/capture changes recheck `assistance_capture_current` at
publication and fresh prepaint. Complete SQL's common captured dispatch requests
both completion and Manual signatures. Native capture-phase Escape dismisses both
pending/visible owners and suppresses signatures through a pending source sync;
the same native snapshot cannot revive automatically. Completion navigation and
acceptance retain priority; signatures do not bind ordinary navigation/Tab/Return.

`Workspace::editor_palette` supplies the same value to actual retained SQL
`Editor::editor_style` rendering and both assistance popups. Task 26 now resolves
persisted independent editor choices at this single boundary, with production
Settings, startup, OS observation and latest-save close finalization. Runtime and
native observation remain open.

- `State::request(owner, editor, native_selections, invocation, window, cx,
  valid) -> Option<Request>` captures the actual native editor. `valid` must
  call `Workspace::assistance_capture_current`. `Invocation` is Automatic or
  Manual. The caller must first gate active SQL document, active window, current
  focus, editable/unmarked text and every modal/common-command context.
- `Request::{id(), capture(), help().await}` retains that owner without retaining
  a process/session/credential handle. `AUTOMATIC_DELAY` is the native Swift
  editor's 75 ms delay. On an admitted replacement, drop the previous task before
  scheduling its one executor timer. Recheck ownership after the timer and again
  before publication. Do not cancel an unchanged request merely because
  `request()` returns None: None can mean the same request or null reply is
  already cached. Invalid contexts explicitly invalidate and drop the task.
- `State::publish(&request, optional_help, native_selections, window, cx, valid)`
  rechecks frontend revision, exact source/context/LSP/process identity, current
  native selection revision, focus and IME before accepting the response. An
  unchanged null reply is retained as settled, preventing observer request loops.
  `failed(&request)` affects only the current request and never execution state.
- `State::refresh(native_selections, window, cx, valid)` rechecks pending as well
  as visible state. `invalidate()` synchronously advances an independent epoch
  and clears pending/visible help. Drop the UI's task on source/selection/focus/
  window/tab/profile/close/modal/unavailability invalidation. Never rely solely
  on the LSP text version to detect caret/focus changes or leave-and-return races.
- `interaction_id()` includes pending requests so Escape can cancel them.
  `act(id, PopupAction, native_selections, window, cx, valid)` handles Dismiss,
  PreviousOverload, NextOverload and ChooseOverload(index). Stale ids refuse.
  Escape suppresses that captured source/selection/context; automatic observation
  cannot immediately revive it. A new snapshot or Manual request permits help.
- `presentation(...current evidence...) -> Option<PopupPresentation>` produces
  one transient render capture. `render(editor_palette, handler, guard)` uses the
  **editor's independent** `appearance::EditorPalette`. `PopupHandler` is
  `Rc<dyn Fn(PopupId, PopupAction, &mut Window, &mut App)>`; every callback must
  re-enter current Workspace context and `State::act`. `PopupGuard` is
  `Rc<dyn Fn(PopupId, &mut Window, &mut App) -> bool>` and must recheck the current
  popup id, active SQL/modal context and `State::refresh` before fresh prepaint.

The Swift editor refreshes on source and selection changes, with a 75 ms delay,
and on manual completion. Mirror those events, including Undo/Redo and
programmatic source changes; do not infer SQL call boundaries in Rust. Manual
Complete should also request signatures with Manual invocation, clearing Escape
suppression. Escape dismisses completion and signature help together when either
is pending/visible; use the real native input evidence and the common owner.
`PopupAction::from_native` admits only a safe nonrepeat Escape. Ordinary arrows,
Return, Tab, Undo and Redo remain native editor actions. Common command registry
actions can route overload navigation to `State::act` without new global hooks
or a background callback. The Previous/Next mouse controls already use real
GPUI mouse dispatch, prevent default focus acquisition and recheck the owner.

The popup reuses `completion_view::EditorPopup::new(...).above_caret()` inside
`deferred()`. It reads the retained editor's fresh prepaint geometry, scroll and
window viewport, independently of a completion popup below the caret. Available
above-caret space is clipped; unusable/offscreen geometry hides the popup. Width
and height are logical native pixels, clamped to the viewport, and wrapped labels
scroll within the popup. Every render resolves background, foreground, active
parameter background/text and border from the editor palette. Theme/DPI/viewport
changes require repaint only. No editor entity, value, focus, caret, selection,
Undo stack, execution feedback or diagnostic decoration is mutated by this core.

## Prepared verification, not executed evidence

`signature_view/tests.rs` prepares bounded response/Unicode/grapheme validation,
exact name/type/default/variadic/return labels, Go-ranked overload order, eight
visible versus 32 reachable overloads, navigation bounds, request epoch races,
safe Escape/IME/dead-key handling and native editor key pass-through.

`fixtures/signature-help/fake_helper.rs` is a std-only owned LSP child fixture,
compiled only by the final tests. It admits the exact `--language-server` argument
and sanitized environment, rejects every non-LSP method, and supplies normal,
null, malformed UTF-16 span and delayed replies. Its bounded audit stores method
names only. Prepared cases cover real transport/typed response delivery and a
source change while a delayed signature request is in flight. The fixture never
records SQL, result values, catalogs, credentials or environment values.

`fixtures/signature-help/{cases,catalog}.json` prepares actual bundled-Go LSP
consumers derived from existing `helper/internal/sqlcomplete/signature_test.go`
and `builtins.go`: nested calls, outer commas, string/array delimiters, comments,
SUBSTRING FROM/FOR, PostgreSQL named/default/variadic parameters, overload ranking,
qualified names, PostgreSQL/MySQL NOW differences and no-help contexts. Synthetic
immutable catalog DTOs prove the same service-to-presentation path, **not** live
connected database metadata lifecycle coverage.

`signature_view/native_tests.rs` prepares a headless real retained-editor render
case for above-caret bounds, viewport clamping, actual mouse overload navigation,
light/dark editor palettes, fresh-prepaint guard dismissal, caret leave-and-return
revision, original focus/selection/text and retained native Undo. Headless logical
geometry is not target-native mixed-monitor DPI, IME or pixel evidence.

`signature/tests.rs` prepares actual Workspace pending Escape suppression,
same-text caret ABA, original profile/settings/service changes, focus, close,
nonempty selection and epoch exhaustion, stale overload callbacks, common
completion priority and native Atomic Undo with the retained editor. Its owned
fake actor cases prepare null/malformed-response caching without request loops
or execution feedback mutation. `assistance/tests.rs` additionally prepares a
delayed signature source-generation race and profile/settings/catalog replacement
with identical source bytes, through the real bounded actor and method-only audit.

`signature/tests/connected.rs` prepares both real adapters and the bundled Go LSP.
Only the explicit disposable-database runner permits its unique function fixture.
It pages signatures on the original read-only catalog service after Connect and
Refresh, checks names/types/defaults/returns after function replacement, retains
an independent SQL transaction, and asserts unchanged database-helper request
counters across source/caret updates and signature requests. This is prepared
code, not a completed connected-metadata or zero-query observation.

At final integration, run and retain completed summaries:

```sh
./scripts/gpui-prototype.sh test --locked -- signature_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- signature_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- signature:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- assistance:: --test-threads=1
./scripts/test-gpui-databases.sh
# Existing Go semantic cases; no new Go implementation or duplicate Rust lexer:
(cd helper && go test ./internal/sqlcomplete ./internal/sqllsp)
```

Also execute integrated Workspace callback tests and the real connected user
function Connect/Refresh/signature matrix on PostgreSQL/MySQL while an independent
SQL tab transaction remains open. Observe zero additional database queries during
typing and overload navigation, native Escape/focus/modal/close/retry races,
selection/IME/Undo, scrolling/wrapping, independent editor/application themes,
high contrast and mixed-monitor DPI on Windows 11 and Ubuntu Wayland/X11.
No native acceptance cell, frozen baseline or reference artifact is changed.

Core-only static evidence (2026-10-19): Rust 1.99.1; scoped `rustfmt --check`;
std-only fake-helper metadata compilation to ignored
`build/gpui/task25-core-static/fake_helper.rmeta`; JSON shape validation of 16
cases and three synthetic metadata overloads. These are compilation/static
checks, not test execution. Initial integrated checks found small core compile/
import issues, corrected before source freeze.

Completed integrated static evidence (2026-10-19): default/native-smoke all-target
check and both Clippy configurations with warnings denied, root fmt check,
std-only updated fake-helper metadata compilation, English/source-character and
whitespace checks. Logs and exact statuses are ignored `build/gpui/task25-*.log`
and `build/gpui/task25-static-results.json`. Settings and Theme Library UI cores
are declared and compile-only fixes are included; their actual Tasks 26/27
Workspace integration remains open. The existing block 0.1.6 future-incompatibility
notice remains. No runtime Rust/Go/Swift/database/UI/credential/clipboard test,
target application build or supported-desktop acceptance ran. No frozen native
cell, baseline/hash/manifest, Mac product, protocol, Go or Swift semantic source
was changed by Task 25.
