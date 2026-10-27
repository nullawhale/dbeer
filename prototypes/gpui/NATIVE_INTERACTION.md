# Native interaction and accessibility

Task 29 production integration is code-ready. Runtime execution and actual
Windows 11 x64 / Ubuntu 24.04 x64 GNOME Wayland and X11 observation remain open.
Mac GPUI is a development host; the macOS product remains SwiftUI/AppKit.
Task 2 and all 171 frozen native acceptance cells remain not-run. Nothing in
this document substitutes compilation for a screen-reader or desktop result.

## Retained production ownership

`accessibility/workspace.rs` consumes the maintained AccessKit bridge on the
actual original DataTable root, rows, headers and cells. The original table
FocusHandle owns focus; its active realized cell supplies the active descendant.
Column ordinals and original source row IDs remain separate from virtual visual
positions. The tree supplies total loaded row/column counts, realized viewport,
full-row/sparse selection counts and exact realized selection membership. It
reads only retained loaded data; accessibility never connects, executes, counts
or browses a database. Paging is still an explicit table operation.

Every native callback rechecks the original Workspace, active document, source
revision, original result entity/operation/set, snapshot, selection publication,
draft ownership and modal state before using original focus, selection, retained
scroll, inline editing or common context-menu paths. TableDelegate's narrow
`will_mutate` hook invalidates before mutable delegate access; common command
and synchronous input entry also invalidate prior captures. Native cell Click
opens the existing typed editor or read-only Row Details. SetValue on cells is
never advertised. Delete and F2 use the original staged delete/edit workflow;
Preview and Apply remain the only database-edit path.

SQL NULL, empty text, literal text NULL, DEFAULT, exact numeric strings and binary
Base64/byte count stay distinct. These exact values intentionally reach assistive
technology, but no tree, source, value or payload is logged or serialized as
verification evidence. Grid captures cap at 8,192 nodes and a 16 MiB text budget;
a value exceeding the remaining budget gets its type, byte count and an explicit
Row Details instruction. Other cells and grid navigation remain available. A
newly realized or excess cell keeps a truthful read-only native projection while
its bounded guarded capture is pending; stale actions are absent. Offscreen
selection counts do not expand into an unbounded cell product.

The original SQL, catalog definition, script review, changes review, inline and
Row Details EditorState entities now retain their respective accessibility
guards. Guards reject replaced document/review/row/modal owners immediately
before native actions. Maintained Input also captures the actual source and
independent native selection epoch, rejecting caret ABA, readonly/disabled edits,
active composition and stale text runs. Selection/replacement invalidate captured
actions before mutating the original native engine; Undo, IME, original selection
and independent editor palettes are preserved. Settings retains its original
preview guards, inputs, sections and independent application/editor choices.

TextRun/TextSelection, SetTextSelection and ReplaceSelectedText use the original
engine's UTF-8 grapheme boundaries. CRLF is one selectable unit. Text above
16 MiB/65,536 runs or with a grapheme larger than AccessKit's u8 length ABI keeps
the existing value-only route. Actual retained source-valid single-visual-line
bounds are published; wrapped, stale, offscreen and pending-scroll geometry is
absent. Character/magnifier coordinates and full native virtual-item provider
behavior are explicit capability limits requiring target observation.

Named dialogs use a monotonic original dialog generation for popup/descendant
native identity, refusing stale canceled/reopened dialog nodes. They publish
Dialog/AlertDialog semantics on their actual popup surface
and original FocusHandle. Their original fullscreen host still owns focus traps,
Return/Escape ordering and dismissal. The maintained context-menu handle opens
the original menu at actual retained trigger bounds. Ordinary context triggers
support Shift+F10/Menu on their focus path; grids preserve the captured current
cell through their own keyboard route. Tab/Shift+Tab traverse focus; arrows,
Home/End and Page keys select/realize original grid IDs. Field editors keep their
own native navigation. Recorder precedence, protected editing/Complete SQL,
completion/signature popup ownership and native raw key safety are unchanged.
Icon-only buttons use their visible tooltip as a fallback accessible name.

## Candidate author IDs and native observation

The source explicitly publishes author IDs; these are candidate selectors until
UIA or AT-SPI observes the exact installed artifact. An ElementId, source string
or API property alone is never an observed native AutomationId.

| Surface | Explicit source author ID |
| --- | --- |
| Workspace | `dbeer-workspace` |
| SQL editor | `dbeer-sql-editor-{runtime document ID}` |
| Result filter | `dbeer-result-filter-{runtime document ID}` |
| Grid / row / header / cell | `dbeer-{document}-2-{NodePart}-{result set}-{original row ID}-{original column ordinal}-{operation}-{snapshot}` |
| Object definition | `dbeer-object-definition-{runtime document ID}` |
| Script / changes review | `dbeer-sql-batch-review` / `dbeer-table-changes-review` |
| Row Details | `dbeer-row-details`; `dbeer-row-detail-{snapshot}-{original row ID}-{ordinal}` |
| Dialog popup | `dbeer-dialog-{original dialog generation}`; name is the displayed title |
| Appearance / themes / shortcuts | Explicit `dbeer.settings.*` IDs on existing retained controls |

Grid/row containers use zero for their non-column key; the row-number header/cell
uses the reserved ordinal `u32::MAX`. Author IDs contain opaque identities only.
They contain no SQL, profile names, connection addresses, keys or cell data.

## GNOME startup and terminal close authority

Normal Linux production startup attaches `session_end::Client` after the window's
common close guard. Disposable demo/smoke modes never register. The owned private
session connection registers `app.dbeer.DBeer`, uses the original returned path
and unique service owner, and retains events/snapshot/readiness through reconnect
and bounded teardown. Startup ID is bounded and never logged. The readiness
publisher remains retained even after moving the client into asynchronous
shutdown, so an input/common-owner mutation can demote readiness before mutation.

QueryEndSession has one second and EndSession ten seconds in GNOME 46. Neither
permits opening UI. Absent/Waiting always refuse with a fixed nonsecret reason.
Only common `TerminalEvidence`, constructed after original operation terminals,
transaction decisions, disconnect acknowledgments, owned helper exit, current
participant saves and the latest successful document flush, can publish Ready
for its exact original token and current registration generation. No required
flush follows Ready on normal teardown. Bounded unregister/connection cleanup
continues only that graph's terminal removal; the original snapshot and finalizer
revisions are revalidated again. The adapter never calls Quit, finish_close,
permit_exit, Commit, Roll Back or Stop.

Response is informational. Cancel clears only the OS association, preserving the
user's independently chosen transaction/Stop decision. Service loss/reconnect
clears readiness and allocates a new generation. Stop/forced session termination
provides no known transaction or successful-flush evidence. Restoration remains
disconnected and uncertain database outcomes remain unknown. GNOME may override
a refusal during forced logout; interactive logout review is not claimed.

Windows continues to subclass only its owned HWND with WM_QUERYENDSESSION and
WM_NCDESTROY cleanup. Alt+F4/system-menu and compositor close keep the common close
graph. The new ignored real-Windows harness creates its own hidden HWNDs, checks
actual subclass delivery/coalescing, canceled-query unknown state, owned teardown
and an untouched unrelated owned HWND. It remains unrun and uncompiled for Windows
on this Mac host; the root Mac build does not establish Windows FFI correctness.

## Prepared verification, deferred execution

Production cases now prepare exact wrapper native properties/typed values,
DEFAULT/large-cell budget behavior, bounded offscreen selection totals, original
focus/selection/details without backend work, stale source/snapshot/selection/
modal actions, and retained Tab/context-menu focus return. Dependency cases add
live owner refusal and actual native source-independent selection ABA. GNOME
publisher cases cover teardown ownership and registration-generation refusal.
The pre-existing private-bus test uses only its own bus and fake GNOME service.

After **all Task 32 code and review fixes are integrated at GLOBAL FREEZE** and
final runtime execution is authorized, execute with completed-run summaries:

```sh
./scripts/gpui-prototype.sh test --locked -- accessibility:: --test-threads=1
./scripts/gpui-prototype.sh test --locked -- session_end:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- accessibility::workspace::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- workspace_tests --test-threads=1
# Owned Linux test host/private dbus-daemon only:
./scripts/gpui-prototype.sh test --locked -- session_end::gnome::protocol_tests --ignored --test-threads=1
# Owned real Windows desktop, unique filter in its own test process:
./scripts/gpui-prototype.sh test --locked -- termination::windows::owned_hwnd_subclass_lifetime_and_native_query_delivery --ignored --test-threads=1
```

Dependency test targets need separate compilation/execution; root all-targets does
not include dependency unit tests. Use the supported exact Task 30 stages on
owned native Windows/Linux x64 hosts. These stages retain reviewed standalone
locks, enable `test-support` (plus `tree-sitter,tree-sitter-sql` for the component),
and explicitly apply **all four** maintained `gpui-pre`, `gpui-base`,
`gpui-component` and `gpui-pre-linux` patch paths. They use the isolated unmarked
verification target/cache paths under ignored `build/`; they do not execute the
root lock as a substitute for the reviewed standalone graph.

```sh
./scripts/test-gpui-parity.sh --final-integration --stage vendor-base-units --stage vendor-component-units
```

```powershell
./scripts/test-gpui-parity.ps1 --final-integration --stage vendor-base-units --stage vendor-component-units
```

`vendor-component-units` includes the maintained input/accessibility `dbeer_`
cases.
The complete required maintained-source suite is selected by `--all-headless`.
See [PARITY_RUNNER.md](PARITY_RUNNER.md) for the exact source/feature/lock review,
offline prerequisites, required assertion counts and additional native stages.
These commands are deferred recipes, not completed-run evidence.

Actual target runs must separately observe UIA/Narrator and AT-SPI/Orca names,
roles, exact values, typed distinctions, selection patterns/text ranges, focus,
virtualization and native author IDs. Exercise readonly/password/IME refusal;
CRLF/non-BMP/bidi/wrapped/large text; Tab/Shift+Tab/arrows/Home/End/Delete/F2,
Shift+F10/Menu; each modal's Return/Escape defaults; completion/signature/recorder
priority; native IME/dead keys/AltGr/non-Latin layouts and clipboard consumers.
Retain only nonsecret evidence. Also exercise real Windows HWND lifetime,
Alt+F4/system-menu Close; Ubuntu compositor close; actual GNOME register/query/end/
cancel/repeat/service-loss/forced limits; standard/fractional/high/mixed DPI,
monitor movement/window bounds/fonts, System/light/dark/high contrast and visible
hover/selection/focus. All these runtime/native gates remain open.

Static completion record: default/native-smoke all-target check and Clippy
(--locked --offline, warnings denied), root fmt, separate component/base lib+test
target check, actual GNOME source harness check/Clippy and changed vendor source
fmt all completed with exit 0 on Rust/Cargo 1.99.1. Exact current source/provenance
hashes are audited. Logs/commands are retained under ignored
`build/gpui/task29-static-results.json` and `task29-final-*.log`. The existing
block 0.1.6 future-incompatibility notice remains. No runtime test/probe executed
and no target Windows/Linux build or native observation is inferred.
