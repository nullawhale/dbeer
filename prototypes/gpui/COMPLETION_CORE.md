# GPUI completion and syntax diagnostic presentation core

Task 24's presentation core and production retained Workspace/command/vendor
integration are code-ready in `src/completion_view.rs`, its subtree and
`src/completion.rs`. The implementation checkboxes do not establish acceptance. All runtime
tests remain deferred until final integration after Task 32. The macOS product
remains SwiftUI/AppKit; Mac GPUI is development only. Windows 11 and Ubuntu 24.04
Wayland/X11 native acceptance, Task 2 and the 171 frozen cells remain open.

## Actual source boundaries

The pinned GPUI Kit 0.7.3 uses the maintained component/base input engines. The
inspected `CompletionProvider` does have automatic/manual requests and source
revision/caret/IME checks. Its component menu, however, highlights only a prefix,
does not accept Tab, and schedules insertion asynchronously without the
Workspace's profile/catalog/process ownership check. Its caret popup is private.
This core therefore supplies an application popup and synchronous captured edit
seam using the actual retained `EditorState`, not an invented toolkit API.

`helper/internal/sqlcomplete` remains the only SQL scope/matcher/identifier
authority. `helper/internal/sqllsp/completion.go` preserves engine order, safe
quoted `textEdit.newText`, whole-token replacement ranges and private UTF-16
`data.dbeerMatchRanges`. Existing alias/CTE/derived/correlated/LATERAL/projection/
ambiguity/FK JOIN and ON handling is reused unchanged. FK snippets are ordinary
plain text primary edits in the actual Go response. The Task 23 conversion layer
rejects snippet format and additional edits; no literal `${...}` insertion or
Rust snippet/SQL parser is introduced. Go's dialect lexer returns no candidates
inside literals/comments, including unfinished input. A response must arrive
before any popup can appear; there is no speculative keyword popup.

## Integration API and ownership

Retain one `completion_view::State` and its task owner in Workspace. Retain one
`completion_view::Diagnostics` per original SQL editor. Never persist these
objects, recreate an editor, borrow a SQL session, connect or fetch metadata from
a completion or diagnostic callback.

1. Invalidate/dismiss and drop the previous retained task synchronously on source,
   selection/caret, focus, active document, modal, profile, settings, catalog,
   service availability and close changes. `State::dismiss` advances a checked
   epoch, invalidating pending responses and stale pointer callbacks. An exhausted
   epoch cannot become valid by wrapping. Focus leave/return must invalidate
   independently of source text. Selection leave/return needs the real native
   selection revision described below.
2. Automatic requests originate only from actual user editing of the original
   input. `automatic_trigger(inserted,popup_was_open)` is a bounded UI character
   trigger, not SQL analysis. Empty insertion refreshes only a previously open
   popup. Restoration, programmatic replacement, completion insertion, execution
   and caret motion must not call this automatic path. Manual invocation goes
   through the common command registry/current SQL editor and protected native
   Ctrl+Space assignment. Do not enable a generic binding that bypasses Task
   28/29 original native key safety.
3. Call `Workspace::assistance_request(original_document_id,cx)`, then
   `State::request(owner,original_editor,selections,invocation,window,cx,valid)`.
   The caller must ensure that the editor entity belongs to that exact stable
   document; same source in another tab does not establish ownership. `valid`
   must call `Workspace::assistance_capture_current(capture,cx)` on current state.
   Reuse the exact Task 23 `RequestOwner`, never retain an LSP process on GPUI.
4. Retain/drop the task that awaits `Request::complete()`. The actor bounds and
   coalesces work; dropping the actual request future cancels its exact request.
   Awaiting tasks must not retain an unbounded request per keystroke. The
   integrator can debounce/coalesce before obtaining the newest RequestOwner;
   an InputEvent may precede the actor's matching source capture by a poll tick.
5. `State::publish` checks the exact epoch, document/URI/version/process/profile/
   settings/catalog/dialect/editor revision and immutable source, plus the real
   original editor/caret/selection revision/focus/editability/IME state. It keeps
   Go order and the first 100 valid candidates. A late failure cannot dismiss a
   newer popup. `failed`, service failure and diagnostics never write query
   execution status/error fields. Editing/execution remain usable.
6. Call `State::presentation` with current selection evidence/validator before
   rendering. `PopupPresentation::render(EditorPalette,PopupHandler,PopupGuard)` returns a
   deferred element anchored from the original editor's fresh current-frame
   `prepaint_caret_geometry`, with viewport clamping and above/below flipping.
   Rows use native uniform-list scrolling; keyboard changes reveal selection.
   Matched label spans expand to composed-character boundaries for display only;
   bold/color highlight retains disjoint abbreviation/typo spans. The fresh
   prepaint guard rechecks the actual Workspace capture and original native
   selection before rows enter the frame. Missing focused
   highlight inherits selected foreground. Editor theme changes restyle retained
   ranges without changing order, insertion, focus or Undo.
7. The popup handler receives its immutable `PopupId` and `PopupAction`. Re-enter
   `State::act` with fresh original selection/context evidence and the Atomic
   adapter. This is also the only acceptance path for safe native Return/Tab.
   Pointer-down preserves input focus. Escape dismisses and invalidates pending
   ownership. Up/Down/Home/End navigate; other keys retain native editing. The
   native key handler must stop propagation only when this current popup actually
   handles the event. Capture outside the modal/editor must not redirect Return.

The same real render seam is public for Task 25: `EditorPopup::new` takes the
original `WeakEntity<EditorState>`, preferred `Size<Pixels>` and a builder
`Fn(Bounds<Pixels>,&mut Window,&mut App)->AnyElement`. Always wrap it in
`deferred()`. Its builder receives fresh window-coordinate placement bounds;
it must build the actual visual popup at that size. `.above_caret()` chooses the
independent native signature placement. `caret_popup_bounds` and
`caret_popup_bounds_above` also expose the pure placement calculation.
`EditorCapture::read` and `matches_source` expose the same retained single-caret
ownership evidence for signature request/publish paths. These helpers never
interpret SQL or authorize an edit; current Task 23 captures remain mandatory.

`PopupAction::from_native` consumes only plain keys with clear original marked
text and shared native dead-key evidence. Repeated acceptance/dismissal,
character-priority, unknown/composing, modifiers, Shift+Tab and AltGr pass
through. The shared `InputSafety` named-key adapter recognizes Enter/Tab/Escape,
Up/Down/Home/End/Space and F keys while preserving Linux's original synchronous
raw native evidence. Unknown evidence never becomes Clear through a fabricated
flag. Ctrl+Space is consumed only in the focused native editor callback with
clear input evidence, then enters the common captured Complete SQL command. No
generic key binding bypasses that check.

## Required narrow retained-editor APIs

The maintained base now implements both APIs used by the enabled production
adapter. The original pinned public APIs expose only active selection, so the core deliberately
refuses missing, multiple or nonempty native selection evidence. It does not
erase secondary cursors or reinterpret selected SQL as a completion prefix.
The actual production adapter must populate `NativeSelections` from a real full
snapshot, not substitute a boolean/active-range count:

```rust
NativeSelections {
    editor: original_editor.entity_id(),
    document_revision: snapshot.document_revision,
    selection_revision: snapshot.selection_revision,
    selections: snapshot.selections.iter().map(|s| NativeSelection {
        anchor: s.anchor, head: s.head,
    }).collect(),
}
```

The native accessor `completion_selection_snapshot` returns
the original editor's entire real anchor/head set, native document revision,
and checked selection revision. Advance that revision at every actual selection
mutation seam, including active/iter-mut access and remove/merge/replace/cursor
motion. Returning to previous offsets must not revive a response. Exhaustion
must refuse rather than wrap. Take the snapshot and use it synchronously on the
UI owner; stale cached snapshots are not evidence of current secondary cursors.

`AtomicEdit` is the explicit function-pointer seam:

```rust
fn(&mut EditorState, Range<usize>, &str, &mut Window, &mut Context<EditorState>)
```

The range is absolute UTF-16 code units, already converted from strict captured
UTF-8 byte endpoints. It is not LSP line/column coordinates. The native adapter
must use the original state and perform this existing-engine sequence:

```text
refuse disabled/readonly/marked-text state
undo_manager.set_pending_intent(EditIntent::Atomic)
save completion_inserting; set completion_inserting = true
replace_text_in_range_silent(Some(range_utf16), replacement, window, cx)
restore completion_inserting
```

The maintained method is `replace_completion_text`. Do not temporarily
select the replacement range: the native history must capture the user's
original caret/selection, then restore it on Undo. Do not call `set_value`,
replace all text, issue one edit per character, insert additional edits, or
discard history. The core rechecks current Workspace capture immediately before
this synchronous callback, validates original editor/source/revision/caret/focus/
IME again inside its editor update, and checks the resulting exact Go primary
replacement. It focuses the same editor without resetting scroll.

This Atomic method is necessary: inspected `EntityInputHandler` explicit-range
replacement and existing `insert_completion` can choose Typing for empty inserts
or one-character rewrites. Merely calling them does not guarantee one-step Undo.
Real regression coverage must assert one Undo restores exact source plus original
caret/selection, Redo reapplies once, and further typing stays separate. Multiple
or range selection acceptance currently refuses unchanged; test reversed/range
and secondary selections remain intact rather than silently losing them.

## Independent versioned diagnostics

`Diagnostics::publish(original_editor,&DiagnosticsBatch,cx,valid)` checks current
Task 23 ownership and exact source, converts the already-validated byte ranges
to the pinned native engine's Unicode scalar Positions with `RopeExt` (its
Position struct has the LSP name but its diagnostic columns are not UTF-16),
and atomically replaces the original editor's
native syntax `DiagnosticSet` in document order. Native underlines/hover consume
that real set. Identical publications preserve the native popover; changed data
clears the old popover. Call `refresh` each assistance notification/render and
`clear` synchronously at invalidation/loss. A stale callback cannot erase a newer
valid diagnostic publication. Retain separate instances for independent tabs.

Execution error ranges remain in their existing independent
`RangeDecorationCollection`; query status/error/feedback state is not passed to
this module. Syntax diagnostics must never overwrite or impersonate execution
feedback, block running a query, or imply server validation of unsupported SQL.

## Prepared verification and final commands

The new tests consume the shared Go matcher UTF-16 fixture, composed emoji and
combining-mark display fixtures, deterministic priority/100-row cap, exact quoted
whole-token edit at a mid-word Unicode caret, invalid UTF-8/surrogate/CRLF/foreign
range refusal, stale epochs/overflow, and native Tab/Return/Escape/selection keys
with unknown/IME/AltGr/Shift+Tab/repeat pass-through. They are prepared cases,
not executed evidence. The production adapter adds original profile/settings/
catalog/source/native request stamps before its bounded debounce, cancellation
on original editor/source/selection/window focus changes, guarded fresh-prepaint
display, current Task 23 validation and separate per-editor native diagnostics.
The actual retained-view cases cover pending selection/focus ABA, programmatic
source changes, modal/close refusal, retained entities and execution-namespace
independence. Task 23's fake-process source/context/remote-error/timeout/restart
cases remain part of the same required final run.

The maintained base's actual lib/test target prepares non-BMP/CRLF insertion,
empty and one-character Atomic changes adjacent to typing, exact source plus
original caret Undo/Redo, reversed and secondary original selection snapshots,
focus, marked-text refusal and epoch exhaustion. Multiple/nonempty selections
refuse completion without dropping them. The additional actual bundled Go LSP
contract goes through Rust framing/typed conversion for both dialects' aliases,
CTEs/derived/correlated/LATERAL sources, projections, ambiguity, plain composite
FK JOIN/ON edits and comment/literal suppression without a database connection.

At final integration after Task 32, execute and retain completed summaries:

```sh
./scripts/gpui-prototype.sh test --locked -- completion_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- completion_view:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- completion:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- language_service::completion_contract_tests:: --test-threads=1
# Same matching environment, actual maintained dependency test target:
cargo test --manifest-path prototypes/gpui/vendor/gpui-base/Cargo.toml --locked --lib -- dbeer_completion --test-threads=1
# Actual Go engine and LSP scope/matcher/quoting/literal/snippet regressions:
cd helper
go test -race ./internal/sqlcomplete ./internal/sqllsp
```

Also run integrated native acceptance on owned Windows 11 and Ubuntu Wayland/X11
desktops for composition, dead keys/AltGr/layouts, literal/comment suppression,
typing/manual popup/navigation/Tab/Return/Escape, focus/caret/selection/Undo,
current-prepaint geometry/scroll/monitor DPI, theme contrast, rapid source/profile/
catalog/tab changes, service loss/restart and versioned diagnostics. A headless
compile does not close any native acceptance cell. No frozen baseline, protocol,
reference artifact, replay, Mac implementation or Go semantic code was changed.

Completed static evidence (2026-10-19): default and native-smoke all-target check,
both Clippy configurations with warnings denied, root formatting, maintained base
`check --locked --lib --tests`, source-character/hash and whitespace checks. Logs
and exact statuses are ignored `build/gpui/task24-*.log` and
`build/gpui/task24-static-results.json`. The existing block 0.1.6 future-incompatibility
notice remains. These are compilation/lint results, with no runtime test,
database/UI/credential/clipboard execution or supported-platform build implied.

Task 25 integration checkpoint: completion and signatures now share the actual
native/editor/modal capture and EditorPalette boundary with retained SQL Editor
rendering. Common Complete SQL requests both services; capture-phase safe Escape
dismisses both pending/visible owners and suppresses signatures at the current
snapshot. Completion navigation/acceptance retains precedence. Existing source
syntax diagnostics and execution decorations remain separate. Task 26 now supplies persisted independent editor choices at the shared palette
boundary, plus actual Settings/startup/OS/close integration. The Theme Library
mutation UI remains Task 27 work; runtime/native acceptance remains open.

Phase 1 modal lifecycle correction: retained connection editors/import reviews
are recovery entities, so their mere presence does not block assistance. The
shared completion/signature source gate checks their actual active state along
with native dialog/prompt/focus and pending work. Opening/reopening synchronously
invalidates pending help. Cancel/success ends the exact owner; failed Save stays
active and can reopen, while an old dismissal cannot close a newer form. Prepared
real-callback tests exercise those transitions and the owned fake LSP's manual/
automatic completion and signature popup publication afterward. Runtime remains
pending until final integration.
