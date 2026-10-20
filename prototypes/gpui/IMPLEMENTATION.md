# GPUI implementation and verification tracker

The user authorized continuous implementation of Tasks 4-32 on 2026-10-19.
Add verification cases with each change; **execute tests only at final integration**.
Compilation/typechecking (including test targets), formatting and static checks may run
during implementation. Code-ready means the implementation exists, not that tests or
acceptance passed. This tracked file is self-contained; builds do not depend on ignored docs.

User-authorized parallel policy (2026-10-19): independent subagents own disjoint core modules while a single integrator owns shared app files. Source freezes precede integrated static checks. A compiled core does not complete its later Workspace/editor/settings/native workflow; runtime tests remain deferred until final integration after Task 32 code.

The macOS product remains SwiftUI/AppKit. GPUI targets Windows 11 x64 and
Ubuntu 24.04 x64 (separate Wayland and X11 acceptance); Mac GPUI is development only.
Task 2 stays open until owned target desktops exist. All 171 native cells remain
not-run. Frozen parity baseline, manifests, reference app and replay remain unchanged.

Dated task notes preserve historical handoffs. A forward assignment in an older
note does not override the current table or the later task's integration record.
Earlier compilation/test evidence is scoped to its stated snapshot and is not a
current runtime result. Historical "deferred" and "not run" notes describe their
own checkpoints; the current status below records later partial execution.

## Current integration status (2026-10-20)

Runtime has executed in focused lanes and exposed production, fixture and
verification defects. Shared Go/native Swift, Rust contract/identity/portable-fault,
Python packaging/probe/guard, popup/grid and ordinary-product Clear Drafts fixes
have completed focused passes. Earlier failures and later supersessions remain
separate receipts under ignored `build/gpui/reviews/`; combining their counts or
different artifacts would not produce a current global pass.

Retained completion/shortcut input and actor source is frozen. The current
33-case original selection and seven routing cases all passed, covering 39 unique
symbols. Independent review completed the exact 60-path original scope and
resolved its original findings; changed dependency own-unit execution remains a
separate acceptance gate. Fresh default/native-smoke all-target checks, both
Clippy modes with warnings denied and root formatting passed on 1,044 stable
compiled inputs. That compiler receipt does not approve the separately changing
guard/provenance files. Their fresh review and actual changed Button/Div unit
runtime remain pending, as does the full available matrix. The original strict
Linux peer startup failure remains unresolved despite separate later passes.
There is no active GLOBAL FREEZE or current full-matrix result.

The prepared runner still has `runtimeReady`/`sourceReady` false. Final source/
provenance/pin review and full portable/dependency gates precede the
three owned PostgreSQL/MySQL pairs, TLS/fault/physical-helper/cleanup stages and
full supported Mac shared regression plus separate screenshot/measurement scopes.
The original Mac capture skips remain uncovered. Task 2, all 171 Windows 11 x64 /
Ubuntu 24.04 x64 Wayland/X11 cells, F57 and genuine installed prior/candidate
acceptance remain open. Mac GPUI/emulated Linux evidence supplies no native target
credit; macOS production remains SwiftUI/AppKit.

The table retains prepared task coverage. Its deferred/full-run status does not
mean that no focused runtime has executed, and no narrow pass completes a task's
remaining verification. Native paired builders compile only without options;
`-Test -Package` / `--test --package` request separate unmarked tests and immutable
unsigned development candidates under `build/gpui/candidates/`.

External CLI review is still NOT RUN after automatic approval rejection, with no
retry or workaround. The original local independent scope is complete; separate
dependency own-unit guard/provenance review remains active.

| Task | Deliverable | Implementation | Final integration verification | Native acceptance |
| --- | --- | --- | --- | --- |
| 1 | Freeze the baseline and parity registry | Previously complete | Prior baseline evidence retained | Not run |
| 2 | Prove the native GPUI feasibility gates | Probe/harness prepared; native gate open | Run probes on owned target desktops | Not run |
| 3 | Separate workspace state from GPUI presentation | Previously complete | Prior local 49/default and 65/DB feature passes retained | Not run |
| 4 | Complete the typed Rust helper contract | Code-ready; tests deferred | Contract fixtures; malformed/truncated frames; identity/metadata; helper death; queue saturation; cancellation; partial sets; bounded ACK/Stop | Not run |
| 5 | Harden profile and credential persistence | Code-ready; tests deferred | Exact-byte migration; credential update/delete/rollback faults; missing/empty passwords; stale/concurrent writes; ordered selection; private paths; Windows locked file; Linux store failures | Not run |
| 6 | Finish profile lifecycle TLS and explicit startup | Code-ready; tests deferred | Captured save/delete/Cancel/stale-ID lifecycle; bounded one-shot stdin; native CA chooser; PG/MySQL TLS trust/hostname/missing/unreadable CA matrix | Not run |
| 7 | Implement portable profile transfer | Code-ready; tests deferred | Shared v2/v1 roundtrip/malformed fixtures; every engine/TLS/policy value; bounds; CA syntax/remap/removal; captured preview/Cancel; atomic batch/export failure; concurrent merge without credential access | Not run |
| 8 | Port the execution fragment and dialect splitter | Code-ready; tests deferred | Shared Swift/Rust splitter/fragment/coordinate goldens; exact original spans; dialect routines; rejected client/import/incomplete input; pre-helper refusal; target-native caret/selection/CRLF | Not run |
| 9 | Build the common command registry and desktop menus | Code-ready; tests deferred | Common capture/origin equivalence; focus/field/modal/busy/unknown/IME gates; stale source/profile/session/operation/grid; native menu/Edit/AltGr/close acceptance | Not run |
| 10 | Implement scripts policy review and execution feedback | Code-ready; tests deferred | Whole-source allow/deny/Cancel review; ordered exact grants/session; routines/multiple sets; first/middle failure; Stop/unknown/stale races; Unicode feedback; cumulative display limits | Not run |
| 11 | Match basic close and running-operation decisions | Code-ready; GNOME startup/common terminal readiness integrated by Task 29; tests deferred | Cancel exact PID/window/session; repeated running/review/Commit/disconnect; terminal gaps; original helper/stale callbacks; disconnect ACK faults; Windows bridge native compile/runtime; actual GNOME session-end observation | Not run |
| 12 | Add native SQL file workflows | Code-ready; tests deferred | Captured Open/Save/Save As and picker Cancel/stale-tab/profile/source/close cases; UTF-8/BOM/Unicode/CRLF/long paths; atomic temp/sync/external-edit/lock/permissions faults; native Windows DACL/rename and desktop pickers | Not run |
| 13 | Add draft restoration and managed history | Code-ready; tests deferred | Safe DTO allow-list/UUID/opaque binding; exact migration/corrupt/future preservation; atomic failures/private files/ownership/concurrent writes; history outcomes/ties/retention/disabled; disconnected restore/reopen; clear Cancel; final flush latest edits/failure recovery | Not run |
| 14 | Complete catalog browsing search and object actions | Code-ready; tests deferred | Lazy kinds/details/retry/Refresh; unexpanded cross-profile search/coalescing/stale success/error; overload/quoted identities; original service client/settings/session; exact adapter actions/copy; atomic table snapshot/no autoexecute/SQL isolation; missing profiles and safe DTOs | Not run |
| 15 | Add dedicated table documents and server navigation | Code-ready; tests deferred | 200/201/empty pages; PK ties/no-PK notice; nine typed operators/exact numeric/binary/NULL; per-document navigation; atomic metadata/DDL/failure; stale service/revision; replacement locks; shared MySQL numeric/missing-object regressions | Not run |
| 16 | Complete grid interaction clipboard and row inspection | Code-ready; tests deferred | Rectangular/sparse/full rows; ordinal/exact typed TSV/JSON; original-row mapping; unique refresh/schema/page/operation/result retention; details/focus/stale snapshots; actual native external formats and target compilation pending | Not run |
| 17 | Add typed staged grid changes | Code-ready; tests deferred | Immutable originals/composite keys; ordinal capabilities; typed NULL/DEFAULT/exact/binary; update/insert/delete; retained editors/projection/copy; navigation/late browse; helper-call refusal; Discard/Cancel/repeated close/stale revision/profile failure; native focus pending | Not run |
| 18 | Add immutable changes preview and assessment | Code-ready; tests deferred | Purpose-bound fresh sessions; exact SQL/typed parameters; changes.apply batch assessment; stale context/Stop/grant revision/cleanup retry/original helper; headless close locks; DB observer/SQL-state cases; PREVIEW.md APIs/final commands | Not run |
| 19 | Implement atomic Apply and uncertain outcomes | Code-ready; tests deferred | Fresh exact one-shot Apply session; authoritative Stop/terminal/cleanup; unknown inspection/discard/reload; known commit plus failed reload; original helper/query ownership; observer/SQL-state/atomic rollback/metadata and fault cases; APPLY.md APIs | Not run |
| 20 | Add loaded result exports | Code-ready; tests deferred | Shared Swift/Go/Rust export values/CSV bytes; original physical rows/count/truncation; captured chooser/Cancel/stale origins; table/sibling edit/browse/Apply/recovery gates and zero request counters; destination/owned-temp/lock/fault cases; EXPORTS.md | Not run |
| 21 | Implement complete Run to File | Code-ready; tests deferred | Exact captured one-statement/session/export grant; full ACK progress; original-client Stop/terminal/history/recovery; Go/Swift/Rust additive fixtures; destination identity/digest, private output and Windows publication/fault cases; both-DB observer/session cases; RUN_TO_FILE.md | Not run |
| 22 | Complete the workspace close decision graph | Code-ready; tests deferred | Captured scripts/full/loaded export/file/Apply owners; fresh inline Apply review; original physical helper/session ownership; ACK versus observed exit; dead-helper unknown close; deferred Discard/later Cancel/store failures; latest awaited SQL/preferences finalization; CLOSE.md | Not run |
| 23 | Integrate the offline language service and metadata lifecycle | Code-ready; retained editor/worker/catalog/close lifecycle integrated; tests deferred | Default/native-smoke all-target check and Clippy; prepared bounded actor/coalescing/source/context/metadata/close/restart and both-DB pager cases remain unrun; LANGUAGE_SERVICE_CORE.md | Not run |
| 24 | Add completion diagnostics and insertion behavior | Code-ready; retained Workspace/editor/command integration; tests deferred | Default/native-smoke all-target check and Clippy; maintained base lib/test compile; prepared native Atomic/Undo/full-selection/focus/IME, popup/race/diagnostic and actual Go both-dialect scope/FK cases; COMPLETION_CORE.md | Not run |
| 25 | Add function signature help | Code-ready; retained Workspace/editor/common-command integration; tests deferred | Default/native-smoke all-target check and Clippy; prepared Go both-dialect semantics, native/core/fake/Workspace races and connected function metadata/no-query counters remain unrun; SIGNATURE_CORE.md | Not run |
| 26 | Implement persistent appearance settings | Code-ready; tests deferred | Production startup/Settings/OS/retained palettes/latest-save close; default/native-smoke all-target check/Clippy and formatting; prepared restart/error/revision/state cases unrun; APPEARANCE_SETTINGS.md | Not run |
| 27 | Port the theme library and import formats | Code-ready; tests deferred | Actual original Settings/native chooser/background parse/review/commit/cancel/recovery/removal/library-and-appearance close integration; default/native-smoke all-target check/Clippy and formatting; shared Swift consumer compiled by coordinated Task 31 build; prepared parser/store/production/native cases unrun; THEME_LIBRARY_SETTINGS.md | Not run |
| 28 | Add configurable shortcut settings | Code-ready; tests deferred | Actual original startup/Settings recorder/store/exact native routing/menu-toolbar/latest-close integration; default/native-smoke all-target check/Clippy and formatting; prepared core/control/production/restart/recovery/native-safety/close cases unrun; SHORTCUTS_CORE.md | Not run |
| 29 | Finish native interaction and accessibility | Production retained editor/grid/inspector/dialog/Settings and GNOME startup/common terminal readiness code-ready | Prepared actual owner/typed/large/offscreen/focus cases; native UIA/AT-SPI/input/DPI/GNOME/owned-HWND compilation and observation remain open | Not run |
| 30 | Complete the automated parity and failure matrix | Code-ready; execution deferred | Isolated unmarked Rust/database/shared Go stages, all 57 feature bindings, reviewed all-four-patch standalone graphs and complete candidate-bound before/after source inventories; PARITY_RUNNER.md | Not run |
| 31 | Prepare product identity and release packages | Code-ready; native package/runtime gates open | Actual empty/disconnected product startup, stable app identity with original data/credential owner, exact paired DB/LSP preflight, native compiler/resource hook, no-replace unsigned packages/notices/provenance and GPUI-only CI; static checks pass; BUILD_INTEGRATION.md | Not run |
| 32 | Run installed upgrade acceptance and close parity | Code prepared/frozen; installed/native run open | 57 prepared exact artifact/owner/provenance/state/real-DB/fault assertions, opaque owned lost-ACK relay and honest manual installed-only gates; INSTALLED_ACCEPTANCE.md | Not run |

## Final integration checklist

- [ ] Run default and native-smoke Rust tests with completed-run summaries on supported native hosts.
- [ ] Run shared Go race/protocol/export and focused Swift regression suites after shared fixture changes.
- [ ] Run PostgreSQL 16/17/18 and MySQL 8.0/8.4 plus TLS and fault scenarios.
- [ ] Run Windows 11, Ubuntu Wayland and Ubuntu X11 desktop probes and workflow acceptance.
- [ ] Run installed prior/candidate upgrade acceptance using owned private fixtures.
- [ ] Record actual passed/failed/skipped evidence; never promote compilation or unrun cases to acceptance.

## Phase 1 quality fixes

Findings Q1–Q8 are fixed and scoped source is frozen in
`build/gpui/reviews/phase1-fixes/source-freeze.json`, with complete per-finding
production/test/static disposition in `RESOLUTION.md` in the same directory.
Go/Rust Windows staging supplies protected current-user-only security at
CREATE_NEW with required retained-handle rights. SQL/loaded/profile exports and
connection/workspace/appearance saves use the common captured publisher,
including captured parent identity, no-replace absence, exact prepared temporary
identity/content and owned-only cleanup. Credential rollback, latest reserved
saves, explicit Windows uncertain publication and original file/session/close
ownership remain intact.

Local SQL file commands accept fresh unbound and missing-profile documents
without database authority; Open has no unrelated table/inspection source
requirement. Restoration removes only the former source/aggregate byte cutoffs
while retaining checked metadata-bounded reads, checked serialization growth,
strict corruption/future/schema/identity rules and existing history count/age
semantics. No source/history is silently omitted. Assistance distinguishes actual
active modal ownership from retained recovery entities; opening/reopening
invalidates pending help, Cancel/success restores access, failed Save remains
recoverable and old callbacks cannot close a newer form. Windows drive and UNC
normalization remain distinct and native identity checks remain required.

Completed compile-only evidence: Rust 1.99.1 default/native-smoke all-target check
and Clippy with warnings denied; exact actual files.rs Windows production/test
metadata plus exact Windows path-function/test metadata; Go 1.27.1 host and
Windows amd64 exportfile test-binary compilation. The full Windows root check
remains blocked at missing llvm-rc resources, and native MSVC/RC/linkage/runtime
is not established. The separate proof fixer owns final combined-source
check/Clippy/fmt after its disjoint fixture changes. No tests/helpers/apps/
databases/OS stores/clipboard/native probes/packages were executed for these
fixes. Shared verification/acceptance receipts require reviewed combined-source
refresh; historical proofs remain unchanged. All target-native/installed
acceptance and Task 2/all 171 cells remain pending.

## Phase 1 critical recheck Q9

Q9 is code-fixed and its three source/topic paths are frozen: the actual SQL Save
chooser captures parent and destination authority before queueing preparation.
First Save and all Save As routes use `prepare_captured`; `capture_for_binding`
also retains older-binding checks for original-path Save As, while ordinary
bound Save remains unchanged. Prepared additions are six native-smoke
`file_view::tests` callback regressions and one default/native-smoke `files::tests`
capture regression; exact names, module bindings and dispositions are in
`build/gpui/reviews/phase1-critical2-fixes/RESOLUTION.md`. No runner or acceptance
pins were refreshed. Scoped formatting/whitespace/character checks and actual
Windows publisher/test metadata typechecking passed. Full root callback-target/
Clippy evidence awaits the coordinated aggregate; no new test ran.
`source-freeze.json` in the same directory supersedes only the three changed
Q1–Q8 path hashes. Runtime remains held until GLOBAL FREEZE; Task 2/all 171 native
cells and genuine installed upgrades remain NOT RUN/pending.

## Phase 1 packaging and proof fixes

Findings I1/T1–T3 are fixed and scoped source is frozen in
`build/gpui/reviews/phase1-package-proof-fixes/source-freeze.json`; full production,
API/schema, regression and static dispositions are in that directory's
`RESOLUTION.md` and `static-results.json`. These are source-ready fixes with
prepared meaningful regressions, not runtime evidence.

The actual Task 30 producer uses `verification/source_contract.py` and retains
complete before/after `task30-reviewed-source-v1` inventories. The same raw-byte
path set includes every platform branch on every host. Candidate provenance
includes every named producer input; the installed adapter validates complete
current candidate/source consistency and joins each exact path/hash/size. All
completed Rust/database-version/Mac adapters require the same candidate-bound
inventory. Packaging's length-prefixed raw-byte aggregate and Task 30's per-file
hash aggregate remain distinct and are never equated. Missing inventories and
stale or mixed revisions refuse before credit.

Mac `--swift` still uses supported `test.sh --all`. Only the 62 literal reviewed
absent-fixture Go database/TLS roots in `verification/macos_coverage.py` may skip;
they remain exact uncovered database roots. Unknown/new/shared-contract and Swift
skips refuse. Separate completed real database/TLS layers remain mandatory, and
the Mac receipt gives no Windows/Linux native credit. Required real full-export
files use the runner-private retained parent/root/output owner, reserved absent
names, captured output identities and nonrecursive cleanup. A cleanup refusal
fails the required database test and proof.

The shared `package()` path stages retained verified source and original notice
bytes, validates the staged legal INDEX and rechecks original source/notice
snapshots before atomic no-replace publication. Late source/legal/index changes
refuse before a new candidate appears. Exact stage cleanup preserves unknown or
replaced content and foreign claim replacements; prior/published candidates are
never deleted. Actual direct/paired serializer, reviewed-skip/stale-source/parser
and filesystem ownership regressions are prepared and unrun.

The released Q1–Q8 + I1/T1–T3 snapshot completed both default/native-smoke locked
offline all-target checks and Clippy with warnings denied, root fmt, proof-schema
parsing and 47 Python AST/in-memory syntax checks. These are static results from
before S1/S2 and Q9, so they are not a pass for the final combined source. Earlier
input counts/static receipts remain historical until reviewed dependency/stage
pins, supplemental adapters and candidate metadata/provenance are refreshed from
the coordinated final source. Task 30 Run boxes, Task 2 and all 171 native cells
remain open; final F57 remains Pending.

## Phase 1 simplification fixes

Findings S1/S2 are fixed and scoped source is frozen in
`build/gpui/reviews/fix-simplification/source-freeze.json`; the complete disposition
and six exact prepared assertion bindings are in `RESOLUTION.md` and
`regressions.json` in that directory. New SQL Tab always reaches the established
local unbound-document constructor after optional selection of its valid captured
profile. Ordinary zero-profile startup can create independent empty disconnected
SQL drafts through the common button/menu/shortcut route. Captured saved/demo
profiles, explicit profile-tab authority and stale/modal/close gates remain.
Actual deletion intentionally retains the missing live profile row and original
draft binding; the actual deletion/NewTab case preserves that policy and does not
claim deletion empties the live profile vector.

Shortcut ordinary commit and explicit default recovery now use the common
captured/anchored publisher. Original expected-destination bytes, ordered
reservations, exact nonoverwriting recovery backup and successful-publication-only
latest revision remain authoritative. Retained staging identity/content is checked
before publication; foreign replacements are neither published nor deleted.
Windows unverified publication returns explicit `PublicationUnknown`, cannot
advance `latest_saved` and cannot authorize normal close.

Actual command/deletion/commit/recovery/normal-close finalizer regressions remain
unrun. The scoped six-file Rust formatting check and eight-file whitespace
audit completed; combined all-target checks, Clippy and root formatting
remain delegated to the aggregate owner after S1/S2 and Q9 release. S1 supersedes
the earlier Q receipt only for the authorized test-only synthetic-store fixture
exposure in `connections.rs`. No production connection behavior changes. Task 2,
all 171 native cells and runtime/installed acceptance remain open.

## Phase 2 shared publication and private backup fixes

CS1 is accepted/fixed and its eight source/topic paths are frozen under
`build/gpui/reviews/phase2-smells-fixes/`. Actual theme import/removal and explicit
recovery use the common captured/anchored publisher. Captured absence receives
atomic no-replace publication; both expected-byte checks, normalized validation/
bounds, owner locks, exact current reservation and successful-publication-only
state advancement remain. The shared raw-byte captured API refuses existing
backup targets and preserves arbitrary original bytes without lossy conversion;
text callers retain their original API and Arc source. Private Windows creation
precedes content and Unix copies use 0600. Original parent/file/staging identity,
exact content and owned-only cleanup preserve foreign replacements.

Theme recovery confirms its exact corrupt-byte backup before primary replacement.
Windows unknown publication is explicitly inspection/Reload-required and cannot
report Imported/Removed or authorize close; known post-publication durability
failure remains a distinct reload-required outcome. Original Settings/request/
preferences revisions, separate library/Appearance reservations and close-finalizer
ordering remain. Thirteen new/extended actual commit/ownership/privacy/recovery/
reservation/restart/finalizer regression bindings are PREPARED/UNRUN. Complete
names, cfg/stage limits and receipt supersessions are in that packet's
`RESOLUTION.md`, `regressions.json` and `source-freeze.json`.

CS2 is accepted/fixed and its eight assigned source/topic paths are frozen under
`build/gpui/reviews/phase2-private-backup-fixes/`. Profile/workspace migration and
shortcut explicit recovery now use the same common raw-byte API with fresh
captured absence. All three retain exact original bytes, private creation before
content, collision retry/no-replace behavior, original owner locks and confirmed-
backup-before-primary ordering, including required directory durability. Foreign
staging/target replacements survive failure. Windows uncertain backup publication
aborts primary replacement with explicit PublicationUnknown; originals and
published-backup evidence remain available for inspection. Source-only disconnected
DTOs, stable IDs/bindings, corrupt/future preservation and existing credential
absence/rollback rules remain.

Nine actual load/recovery before-write/privacy/exactness/collision/write-sync/
foreign-identity/restart regressions are PREPARED/UNRUN. Exact names and existing
default/native-smoke/persistence-faults bindings are in the CS2 `regressions.json`;
complete disposition, source freeze and prior receipt supersession are retained
beside it. Required suffix/proof pin review belongs to the final coordinator.

CS1 scoped seven-Rust-path formatting/eight-path text audits and actual Windows
common publisher/test-helper metadata compilation passed. CS2 scoped five-Rust-
path formatting/eight-path text audits passed. These narrow results establish no
current combined root/caller/test-target or native Windows UI/linkage pass.
Fresh default/native-smoke all-target check, Clippy with warnings denied and root
formatting remain with the parent's aggregate after both final releases. Earlier
Q/S/Q9/aggregate receipts are historical for superseded bytes, including CS1's
new `files.rs` bytes; Q9 behavior is retained. All CS regressions and native/macOS
runtime suites remain unrun. Task 2, all 171 native cells, Task 30/32 runtime and
installed gates remain open; F57 stays Pending. No runtime is released before
the parent's integrated GLOBAL FREEZE and explicit authorization. macOS remains
SwiftUI/AppKit; Mac GPUI remains development only.

## Phase 4 profile migration source authority

FQ1 and I2 independently identified the same legacy-profile migration interval;
both are accepted/fixed by the frozen two-path packet under
`build/gpui/reviews/phase4-profile-fixes/`. Actual migration now retains validated
original bytes, a stable primary file binding and parent before the exact private
backup. Main preparation after required backup success consumes that original
authority and refuses intervening content, identity or parent changes instead of
adopting a later valid/current, future, corrupt or same-byte replacement primary.
Confirmed old backups remain available. The common captured publisher and
`files.rs`, durable nonoverwriting backup, ordinary profile/selection/import/delete
semantics, stable IDs/policies, credential nonaccess and disconnected restore remain.

Three actual-load regression functions remain PREPARED/UNRUN. Two contain eighteen
successful-backup BeforeWrite/BeforeSync content/identity variants preserving exact
foreign bytes/binding, confirmed private old backup and zero synthetic credential
calls, followed by explicit original restoration/retry/fresh-store restart. The
Unix-only parent-replacement function instead verifies the common backup guard's
refusal before publication; it claims no successful backup or Windows observation.
Exact names, cfg/host/default/native-smoke/persistence-faults bindings and complete
dispositions are in `regressions.json` and `RESOLUTION.md` in that directory.

The focused default locked/offline all-target compile, scoped Rust formatting
and two-path character/whitespace audit passed. No test binary or runtime ran.
Final combined both-mode check/Clippy/format, required regression bindings and
Task 30/source pin refresh remain with the parent coordinator. `source-freeze.json`
explicitly supersedes the two CS2 path entries and changed-source entries in the
old post-CS aggregate and 1569-row `b7de2b...` source contract; those earlier
receipts cannot establish a pass for these new bytes. All runtime/native/installed
gates, Task 2 and all 171 native cells remain open; F57 remains Pending. No new
runtime is authorized before the parent GLOBAL FREEZE. macOS remains SwiftUI/
AppKit; Mac GPUI remains development only.

## Task 4 contract notes

Code-ready on 2026-10-19. See CONTRACT.md and backend_contract.rs/backend.rs.
Existing protocol v3 is unchanged. All catalog fields, typed browse filters/sorts,
changes preview/apply, export outcomes and ordered operation/authorization data
flow through validated backend entry points. Response identities, row widths,
metadata, completed partial sets and authoritative transaction status are retained;
invalid submitted outcomes remain uncertain. Ordinary saturation refuses only the
unsubmitted request; reserved ACK/first-Stop capacity remains bounded.

Added shared `protocol/fixtures/contract-v3.json` and Go/Swift/Rust consumers.
Rust fault cases cover malformed/truncated framing, helper death, identity,
metadata/export mismatch, regular queue saturation, repeated Stop, exact ACKs,
bounded progress/row/byte/set limits and completed-prefix recovery. These are
prepared cases, **not executed evidence**. Task 30/final integration must extend
and execute full native pressure/cancellation coverage.

Completed static checks only (2026-10-19): default and native-smoke `check
--locked --all-targets`, default and native-smoke all-target Clippy with warnings
denied, formatting and tracked-file whitespace check. Rust test targets compiled
but no tests executed. Logs: ignored `build/gpui/task4-{check,feature-check,
clippy,feature-clippy,fmt}.log`. Dependency `block 0.1.6` retains Cargo's existing
future-incompatibility notice. No Go/Swift/database/native UI/credential tests
ran; no test-execution or native acceptance checkbox is complete.

Run these **at final integration**, with completed summaries and explicit skips:

```sh
./scripts/gpui-prototype.sh test --locked -- backend:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- backend:: --test-threads=1
./scripts/test-go.sh
./scripts/test.sh --filter GPUIContractFixturesTests
./scripts/test-gpui-databases.sh
```

The Rust fixture/fault commands must also run against their native matching
helper on Windows/Linux using the supported native build runners
(`scripts/build-gpui-client.ps1 -Test`, `scripts/build-gpui-client.sh --test`).
Actual native Stop/backpressure/cancellation observations remain required on
Windows 11 and Ubuntu Wayland/X11 desktops. All Task 2 checkboxes and 171 native
cells remain open. Tasks 8-32 remain pending and authorized for continuous
implementation; each task adds its cases now and executes them at final integration.

## Task 5 persistence notes

Code-ready on 2026-10-19. See PERSISTENCE.md, the v1 fixture under fixtures/ and
connections.rs/profiles.rs/instance.rs. GPUI library v2 persists selection by
opaque saved ID. Valid prototype v1 metadata migrates with an exact-byte,
nonoverwriting private backup. Invalid/unknown/future files are refused.
Passwords remain exclusively in the same OS credential service. Updates and
deletion preserve exact optional credentials on failure; rollback failure is an
explicit error. Owner-scoped mutations merge current metadata, stale editor and
prepared-file snapshots are refused, and ordered selection requests cannot
restore a stale snapshot. Restored profiles remain disconnected. New factories
use unspecified/readonly=false; legacy omitted policy retains development/true.

Added synthetic failure/concurrency/migration cases and a Windows locked-file
case; platform cases retain Linux locked/unavailable-store errors. They are
prepared code, **not executed evidence**. Real Windows/Linux store availability,
ACLs, replacement/locking and desktop selection/restore require final native
execution. The native feasibility service/account cleanup remains separate.
Full profile lifecycle/TLS/startup UI stays in Task 6; transfer stays in Task 7.

Completed static checks only (2026-10-19): default and native-smoke all-target
`check --locked`, all-target Clippy with warnings denied, and formatting. Test
targets compiled; no Rust/Go/Swift/database/UI/credential tests ran. Logs:
ignored `build/gpui/task5-{check,feature-check,clippy,feature-clippy,fmt}.log`.
Cargo retains the existing dependency `block 0.1.6` future-incompatibility notice.
No test-execution/native gate or frozen acceptance cell is marked complete.

## Task 6 lifecycle and startup notes

Code-ready on 2026-10-19. See LIFECYCLE.md and profiles.rs/close.rs/
connections.rs/startup.rs. Save/delete capture immutable original settings and
stable IDs; close decisions and acknowledged physical disconnection precede
credential/metadata writes. Running Cancel sends no Stop, transaction/unknown
Cancel preserves the profile and form, and stale snapshots are refused again
inside the store. Profile actions are available through context and focusable
menus; CA selection uses the original form/window's native chooser. Save stays
disconnected; Save & Connect opens a fresh session without executing editor SQL.

Explicit --connect-stdin is one-shot, EOF-delimited, capped at 64 KiB with a
five-second deadline. Ordinary startup never reads stdin. Ownership is acquired
first; no background blocked reader survives, buffers are cleared, diagnostics
are fixed, and invalid input/storage failures leave manual recovery available.

Prepared cases cover parser/pipe limits and cleanup; GPUI profile transaction,
running, unknown, delete and stale-request cancellation; and a required private
PostgreSQL/MySQL TLS manifest covering modes/trust/hostname/missing/unreadable CA.
These are code, not executed evidence. Actual native chooser, secure stores,
stdin pipe deadlines/exactly-one-connect/no-query observation and TLS negotiation
must run during final integration on Windows 11 and Ubuntu Wayland/X11.

Completed static checks only: default and native-smoke all-target check/clippy
with warnings denied, formatting and whitespace check. Test targets compiled;
no Rust/Go/Swift/database/UI/credential test executed. Logs are ignored
build/gpui/task6-{check,feature-check,clippy,feature-clippy,fmt}.log. Cargo retains
the dependency block 0.1.6 future-incompatibility notice. No native TLS checkbox,
Task 2 gate or frozen acceptance cell is marked complete. Tasks 7-32 remain
authorized for continuous implementation with test execution deferred.


## Task 7 portable transfer notes

Code-ready on 2026-10-19. See TRANSFER.md, protocol/PROFILE_TRANSFER.md,
transfer.rs/transfer_view.rs and ProfileStore::import_profiles. Portable v2 and
legacy v1 match Swift's nested policy shape; omitted/null v1 policy means
unspecified/false, independent of GPUI private-library migration defaults.
Typed deserialization rejects duplicate and unknown keys (including secret
fields) before an untyped map could discard them. Bytes/depth/count/field/port/
engine/TLS/environment bounds apply before review or publication. Export emits
no identities, passwords or private keys and captures original settings before
the native chooser. Same-directory private temporary files are synced before
atomic export replacement; cancellation/failure preserves the destination.

Import review shows every relevant profile value, individual/all selection,
explicit native CA remapping and Cancel. POSIX, Windows drive and UNC CA hints
are interoperable syntax only; foreign hints never reach filesystem probes and
UNC always requires explicit chooser selection before probing. Missing CAs are
rechecked before publication without clearing the hint or changing TLS/policy.
The narrow Swift importer fix accepts foreign hints while requiring local CA
selection, and its native CA callback rechecks the original preview identity.
The shared four-stage Mac → Windows → Linux → Mac fixtures record explicit local
remaps; legacy fixtures retain omitted/null and explicit policies. Existing
fixtures/frozen baseline artifacts, manifests, reference and source hashes were
not rewritten.

One owner-scoped mutation appends the full selected batch with fresh saved IDs,
preserving current selection and concurrent additions. Changed/deleted original
records refuse stale review. It never reads/writes credentials, overwrites a
profile, connects or executes SQL. Preview allocates separate fresh IDs; cancelled
reviews ignore late native CA callbacks. Review freezes during atomic publication
and permits retry after a fixed failure without partial import.

Prepared Rust cases cover shared roundtrip/legacy/malformed fixtures, all engine
TLS modes and explicit policy values, byte/count/port/grapheme bounds, foreign CA
syntax and explicit remap/removal, regular-file read bounds, atomic export
failure/private-mode/cleanup, batch replacement failure, stale originals and
concurrent additions/selection with no credential calls. A headless GPUI callback
case covers individual/all selection, ignored unselected missing CA, Cancel and
late remap. New Swift consumer assertions cover all shared stages, fresh IDs,
exact settings/policy, legacy omissions/nulls, malformed rejection and foreign
CA requirements. These cases are prepared and compiled, **not executed**.

Completed static checks only: default and native-smoke all-target check and
Clippy with warnings denied, formatting, Swift application/test-target build
(`swift build --build-tests`, explicit installed TestingMacros library), and
whitespace checks. No Rust/Swift/Go/database/UI/credential test or native operation
ran. Logs: ignored build/gpui/task7-{check,feature-check,clippy,feature-clippy,fmt,
swift-build,whitespace}.log. Cargo retains the existing block 0.1.6
future-incompatibility notice; Swift retains existing AppKit deprecation and
Command Line Tools search-path/cache warnings. All Task 2/native gates and 171
Windows/Wayland/X11 cells remain not-run.

Run these **at final integration**, with completed-run summaries and native
Windows/Linux matching runners:

```sh
./scripts/gpui-prototype.sh test --locked -- transfer --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- transfer --test-threads=1
./scripts/test.sh --filter ProfileTransferTests --filter ProfileTransferFixturesTests
```

Native final acceptance must exercise chooser cancellation/stale callbacks,
locked destinations/private permissions, failed batch publication, concurrent
profile actions and explicit POSIX/Windows-drive/UNC remaps through the four
platform stages. Verify disconnected imports and no credential mutation, then
explicit connections using required TLS with actual local CAs. Actual desktop
rendering/accessibility/credential/trust negotiation remains unverified. Task 8
can now implement the execution fragment/splitter independently of transfer;
no Task 8+ behavior or acceptance is included here.


## Task 8 execution source notes

Code-ready on 2026-10-19. See PARSING.md, src/sql.rs/src/sql_tests.rs and the
new additive protocol/fixtures/sql-execution/v1.json corpus. This directly ports
the Swift UTF-16 execution scanner without depending on Tree-sitter, Go SQL
classification or ignored docs. Immutable SourceText/PreparedFragment/Statement
values retain exact selected text and original UTF-8 byte/UTF-16 spans across
client delimiter removal. Cursor hit areas include terminators with the Swift
priority for adjacent statement starts. Selection trim/clamp/partial behavior,
full scripts, LF fragment line labels, LSP CRLF/lone-CR lines, invalid
surrogate/continuation-byte boundaries and adapter one-based scalar positions
are explicit. Missing adapter positions remain absent, zero is a typed invalid
position, and past-end reference clamping is disclosed.

Live/demo Run now captures selection/current statement; only one diagnostic-free
statement proceeds. Live parse failure occurs before helper startup, credential
lookup or connect. Explicit transaction overrides parse their own bounded source.
Captured operations record original statement byte ranges and retain their
original helper client/session/context checks, stale terminal handling, Stop,
ACK and uncertain outcomes. Task 9 supplies common commands; Task 10 supplies
reviewed sequential scripts and source highlighting/error navigation. No batch
is accidentally dispatched as a whole editor buffer.

The shared corpus prepares 50 splitter cases and 33 fragment cases, plus
coordinate/error truth tables. Cases derive from Swift's nested comments,
dollar/E/standard strings, SQL BEGIN ATOMIC/nested CASE, MySQL quote/comment
rules, DELIMITER procedures/triggers, client commands/import rejection and
incomplete constructs. Added cases cover immediately-after-semicolon/custom
terminator hits, adjacent SQL, gaps, comments, empty/trimmed/partial/clamped
selection, invalid selection, full script, Unicode directive case, non-BMP,
combining marks, CRLF/lone CR/LF, EOF and invalid LSP columns/lines. Swift
SQLExecutionFixturesTests and Rust sql::tests assert exact selected SQL and
original byte/UTF-16 ranges. A headless GPUI case prepares actual editor
selections and refuses invalid/multiple inputs before helper startup.
These are prepared code, **not executed evidence**.

Reference nuance: a MySQL routine selected at the caret is reparsed by Swift's
fragment resolver without its DELIMITER directive and can produce multiple
fragments. The goldens preserve that observed behavior. Current Run refuses it;
Tasks 9/10 must never execute its routine pieces. Full-script preparation keeps
the original routine whole. PARSING.md documents the API and this constraint.

Completed static checks only: default and native-smoke all-target check and
Clippy with warnings denied, formatting, Swift application/test-target build
(`swift build --build-tests`, explicit installed TestingMacros library), JSON
syntax and whitespace checks. No Rust/Swift/Go/database/UI/credential tests or
native operations executed. Logs: ignored build/gpui/task8-{check,feature-check,
clippy,feature-clippy,fmt,swift-build,whitespace}.log. Cargo retains the existing
block 0.1.6 future-incompatibility notice; Swift retains existing AppKit
and Command Line Tools cache/search-path warnings. All Task 2 gates and 171
Windows/Wayland/X11 cells remain not-run; frozen baseline sources, fixtures,
reference app and manifests are unchanged.

Run these **at final integration**, with completed-run summaries and matching
native Windows/Linux build runners:

```sh
./scripts/gpui-prototype.sh test --locked -- sql::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- sql --test-threads=1
./scripts/test.sh --filter SQLExecutionFixturesTests --filter SQLScriptParserTests --filter WorkspaceCommandTests --filter SQLLanguageServiceTests
```

Actual Windows 11, Ubuntu Wayland and Ubuntu X11 caret/selection/native-input,
Unicode/CRLF, routines and subsequent reviewed script workflows still need
native acceptance with both engine families. This task does not claim SQL
grammar validation, adapter policy parity from lexical checks, command registry,
script review/execution feedback or native UI acceptance.


## Task 9 desktop command notes

Code-ready on 2026-10-19. See COMMANDS.md, commands.rs and commands/tests.rs.
File/Edit/Query/Connections/Settings menus, scoped default actions, toolbar,
profile/catalog/session/transfer/result-copy controls and titlebar/system/Quit
origins use one availability/capture/dispatch boundary. Profile targets are
stable IDs and original settings. SQL captures exact original fragment/source,
revision, document/session/generation and operation before asynchronous work;
stale captures refuse and tab switches cannot redirect them. Grid result copy
also checks captured entity/set identity. Live execution accepts the immutable
prepared fragment without rereading current editor state. Helper/session/Stop/
ACK/authoritative terminal/unknown handling is preserved.

Editor/grid/ordinary-input focus is explicit; a field editor inside a grid
keeps input semantics. Dialogs/prompts, transfer choosers, busy/unknown outcomes,
changed session settings and marked composition gate SQL. Edit commands dispatch
the toolkit's original actions on the captured focused control. Query keys use
DBeerSqlEditor > Input and no global key observer. Default primary Enter runs
selection/current; Shift+primary Enter declares full script and remains disabled
until Task 10. Stop has no reference default. Later 10/12/13/16/20/21/26/28
workflows are declared and visibly unavailable, without enabled placeholders.
No scripts, file workflow, persistent settings or additional close graph is
implemented by Task 9.

Prepared pure/headless cases cover origin equality, text fields, modal/IME,
busy/unknown/settings locks, invalid fragments before helper startup, source
edits, tab switches and stale source/session/operation. They are code, not
executed evidence. Real Windows/Linux menu focus, Edit/clipboard, AltGr/native
synthesized modifiers, IME and OS close paths remain unobserved.

Completed static checks only: default/native-smoke all-target check --locked,
default/native-smoke all-target Clippy with warnings denied, formatting and
whitespace check. Logs: ignored build/gpui/task9-{check,feature-check,clippy,
feature-clippy,fmt,whitespace}.log. Test targets compiled; no Rust/Swift/Go/
database/UI/credential test executed. The existing block 0.1.6 future notice
remains. Task 2 and all 171 native cells are unchanged and not-run.

At final integration run with completed summaries and native matching helpers:

```sh
./scripts/gpui-prototype.sh test --locked -- commands::tests
./scripts/gpui-prototype.sh test --locked --features native-smoke -- commands::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- workspace_tests --test-threads=1
```

Then perform the Windows 11/Ubuntu Wayland/X11 native menu/button/shortcut,
focused fields/dialog/settings, grid field editor, clipboard/Edit, AltGr/IME,
selection/current/script, busy/unknown/stale-target and guarded close/Quit
acceptance in COMMANDS.md. No runtime/native checkbox is complete. Tasks 10-32
remain continuously authorized with test execution deferred to final integration.


## Task 10 scripts and execution feedback notes

Code-ready on 2026-10-19. See SCRIPTS.md, commands.rs, scripts.rs, model.rs,
live.rs, workspace.rs and controls.rs. Run Script shares captured command dispatch
and the original immutable source/delimiter ranges. One ordered helper assessment
and exact grant precede a whole-source/classification review even for allow.
Denied, cancelled and stale reviews execute nothing; unused grants are revoked
before releasing the operation lock. Statements run sequentially on the original
client/physical session, retaining each status/source/result-set range, completed
prefix and authoritative transaction. Stop/failure/staleness skips later work;
submitted unknown outcomes block blind retry. One whole-run budget bounds sets,
rows and bytes without skipping SQL or terminal reconciliation. Results expose
statement/set context, elapsed/rows/truncation, original Unicode error navigation,
active source highlighting and success gutter marks cleared on edit/profile/new
run. Internal Commit/Rollback never mark unrelated editor text.

Prepared pure/headless/backend and opt-in DB cases cover allow/keyboard Cancel,
source/tab review races, prefix/multiset failures, terminal-gap Stop, unknown
locks, Unicode/CRLF errors, shared display limits with later command terminals,
exact grant order/session/revoke/replay and MySQL DELIMITER routines/typed multi-
set results. They are compiled code, not executed evidence. No later file,
history persistence or additional close graph is implemented. Task 11/13 APIs
and safe transient-state boundaries are documented in SCRIPTS.md.

Completed static checks only: default/native-smoke all-target check --locked,
default/native-smoke all-target Clippy -D warnings, fmt --check and whitespace.
Logs: ignored build/gpui/task10-{check,feature-check,clippy,feature-clippy,fmt,
whitespace}.log. Test targets compiled; no Rust/Swift/Go/database/UI/credential
test executed. The existing block 0.1.6 future notice remains. Frozen sources,
baselines/manifests/reference hashes are unchanged; Task 2 and all 171 native
cells remain not-run.

At final integration execute the focused commands in SCRIPTS.md and the supported
native Windows/Linux database runners, recording completed summaries and explicit
skips. Actual Windows 11/Ubuntu Wayland/X11 whole-source review, keyboard defaults,
Stop/helper loss, original error/gutter geometry and both engine families remain
required. Tasks 11-32 remain continuously authorized; tests stay deferred.


## Task 11 basic close notes

Basic workspace/session close was code-ready at the 2026-10-19 checkpoint.
The Ubuntu GNOME adapter assigned forward then is now integrated by
[Task 29](#task-29-production-native-integration), including normal Linux startup,
owned registration and terminal common-close readiness. Actual GNOME logout and
Windows session-end behavior remain native verification gates.
See CLOSE.md for the durable API/platform/case contract. `CloseFlow` captures
stable documents/profiles, settings/generations and the original helper.
`CloseToken` and expected phases make review/Stop/control SQL/disconnect/removal
continuations idempotent. Cancel sends no Stop and restores an original form;
failed transactions cannot Commit. Stop waits for the original authoritative
terminal/revocation lock, resolution cannot spawn a replacement helper, and
matching disconnect ACKs precede removal or profile/password mutation.
Unacknowledged teardown aborts close. Source edits do not cancel independent
Commit/Roll Back control SQL. Only reviewed window removal permits exit;
arbitrary backend/forced loss never creates a known database outcome.

Actual pinned backend sources were inspected. WM_CLOSE, xdg Close and
WM_DELETE_WINDOW use the shared window guard/common system command. Windows
WM_QUERYENDSESSION otherwise auto-accepts; a maintained owned-HWND comctl32
subclass vetoes it and queues a bounded foreground review request. WM_NCDESTROY
removes the subclass; all other messages are forwarded. This Windows cfg code
has not compiled or run on this Mac host. Forced WM_ENDSESSION is unknown.
Task 29 delivered GNOME session-manager owned registration/unregistration,
QueryEndSession/EndSession/CancelEndSession and cancellable common-flow replies.
Replies require terminal common evidence and do not open logout review. Neither
that implementation nor compositor close establishes a native logout result.

Prepared cases cover pure once-only/stale phases, production should-close
callbacks, exact PID/window/session/query Cancel, Return/Escape, failed Commit,
repeated running/review/selected Commit/disconnect, independent control source,
original/replacement helper, terminal-gap Stop/unknown loss, stale callbacks,
profile mutation Cancel, wrong-session disconnect ACK and Stop ACK versus query
terminal, actual-helper disconnect refusal, and server-observed PG/MySQL close
Cancel before Stop. The Windows callback policy case is synthetic and sends no
OS message; native subclass delivery/lifetime remains unrun.

Static checks only: default/native-smoke check --locked --all-targets, both
all-target Clippy -D warnings, fmt --check and whitespace. Logs are ignored
build/gpui/task11-{check,feature-check,clippy,feature-clippy,fmt,whitespace}.log.
The existing block 0.1.6 future notice remains. No Rust, Swift, Go, database,
UI or credential tests ran. Frozen baseline/artifact/hash/registry content is
unchanged; all Task 2 gates and 171 native cells remain not-run.

Run CLOSE.md's focused final commands with completed summaries, matching native
helpers and owned desktops. Tasks 12/13/22 must extend the same token boundary:
file/source/chooser decisions before teardown; awaited fallible draft/history
flush at finish_close before removal/exit permission; staged edits/Apply/export
review and terminal/publication outcomes before disconnect. Persist no live
session/grant/operation/credential state and restore disconnected. Those later
workflows were still pending at this checkpoint and are recorded as integrated
in Tasks 12/13/22 below. Continuous Tasks 12-32 work remains authorized;
runtime execution stays deferred to final integration.


## Task 12 SQL file notes

Code-ready on 2026-10-19; see FILES.md, files.rs and file_view.rs. Common
OpenSql/SaveSql/SaveSqlAs capture full original source and file metadata before
native pickers. UTF-8 multi-open stays disconnected; invalid files create no
partial document. Save uses a synced, byte-verified temporary and one validated
atomic publication; stale/cancelled callbacks cannot mutate another document or
binding. Newer editor text remains dirty after a captured older save.
DocumentState.file exposes binding/revision/saved_source/saved_source_revision
and exact dirty(&str); file_request blocks close before creating CloseFlow.
Task 13 now supplies its awaited fallible final flush in finish_close before removal; see RESTORATION.md.
Task 22 extends close-owned file phases; no complete dirty-file close graph is
claimed. Source, paths and file stamps are transient and never logged/persisted.

Prepared cases cover UTF-8/BOM/empty/Unicode/CRLF/long paths, sync and external
edit faults, changed temporaries, appeared targets, locks, platform permissions,
symlink/parent retarget refusal and production native-picker callback ownership.
Unix read-only inode replacement follows writable-parent semantics, preserving
permission bits. Windows uses owned-handle relative Unicode rename and DACL
copying, with explicit unverified-outcome reconciliation; that cfg branch is
uncompiled here. Advisory Unix locks cannot give adversarial writer CAS; native
filesystem, locking/ACL and chooser overwrite behavior remain acceptance work.

Static checks only: default/native-smoke all-target check and Clippy with
warnings denied, formatting and whitespace; logs ignored build/gpui/task12-*.log.
No Rust/Swift/Go/database/UI/credential tests executed. Cargo retains its existing
block 0.1.6 future-incompatibility notice. At final integration run the FILES.md
files::tests, commands::tests, native-smoke file_view::tests and workspace_tests
commands, then supported native Windows/Linux build runners and desktop file
workflows. Retain completed summaries and explicit skips. Task 2, all 171 native
cells and Task 29 GNOME session-end native observation remain open; the adapter's
production integration is recorded in Task 29 below.


## Task 13 restoration and history notes

Code-ready on 2026-10-19. See RESTORATION.md and restoration.rs/history_view.rs.
Explicit v1/v0 source-only DTOs persist durable document UUID/title/text/opaque
profile binding/order/selection and managed history. Editor/operation identity
remains independent. New/restored editors are retained and disconnected; missing
profiles retain SQL and never retarget or execute. History uses reference terminal
labels, once-per-submitted-statement guards, stable timestamp ties, 1000/30-day
retention and enabled-by-default recording; skipped/control SQL does not record.
History is a real common-command panel with toggle/open/clear/retry actions.

One-second reserve-before-dispatch saves and all publications share the data
owner mutation mutex. Exact-byte nonoverwriting v0 backups, bounded strict reads,
private synced temporary publication and external-change checks preserve corrupt/
future files and retryable failure. No sessions/results/credentials/grants/pending
DB edits/file paths/Undo/caret/scroll serialize. Intent-specific Finishing flush
awaits old writers, rechecks edits and completes before removal/exit permission.
Tab/clear snapshots remove intended drafts after guards; workspace exit retains
open drafts; failed profile mutation retains sources. Clear never deletes SQL files.

Prepared pure/headless cases cover the above allow-list/identity/migration/fault/
ownership/concurrency/history/restore/UI/clear-Cancel/finalflush paths. They compiled
but were not executed. Completed static checks only: default and native-smoke
all-target check, both all-target Clippy with warnings denied, fmt and whitespace.
Logs: ignored build/gpui/task13-{check,feature-check,clippy,feature-clippy,fmt,whitespace}.log.
No Rust/Swift/Go/database/UI/credential test ran; existing block 0.1.6 future notice
remains. Task 2, Ubuntu session-manager Task 29 gap and all 171 native cells stay open.

Final integration commands (matching Windows/Linux native runners required):

```sh
./scripts/gpui-prototype.sh test --locked -- restoration::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked -- commands::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- workspace_tests --test-threads=1
```

Tasks 14/15: constructors retain editor entities; schedule_documents(cx) follows
intentional source/title/binding/order/selection changes; table/catalog/session
state is outside document_snapshot. Task 22: retain token/Finishing awaited flush,
post-intent snapshot, latest-state recheck and fallible retry; file_request still
blocks close before flow creation. Task 26: separate explicit appearance storage
under the same data owner, preserving historyEnabled and the safe SQL DTO boundary.


## Task 14 catalog notes

Code-ready on 2026-10-19. See CATALOG.md and catalog.rs/catalog/tests.rs. Lazy
object/detail groups, counts/progress/empty/error/Retry/Refresh and bounded
debounced server search now use existing explicitly connected service sessions.
One in-flight search plus the latest query coalesces typing; stale success/error
and root/search branch ownership use exact revision, profile/settings/generation/
service session and originating helper identity. No typing-triggered connection
or credential lookup, SQL-tab session, SET, transaction or local dialect SQL is used.

Typed captured catalog targets extend the common command registry for context/
menu/button actions. Quoted names and overload identities come from helper output;
Copy Name copies that exact adapter value and Generate SELECT opens disconnected.
Double-click opens real non-SQL inspection or a minimal Table document. Columns
and actual helper browse rows publish atomically, retaining previous data on
failure; paging/sort/filter remain Task 15. Definitions use retained read-only
editors. Explicit Profile.demo excludes missing restored bindings from demo data.
Final-kind construction precedes scheduling; table/inspection/catalog/session/
metadata/results never enter SQL-only restoration DTOs or history.

Prepared pure/headless/backend/DB cases cover lazy request/identity/metadata,
retry, stale/reordered search success/error, helper/context replacement, atomic
refresh failure, exact copy, disconnected generation, retained editors, missing
profiles, close and coalesced typing. Real PostgreSQL/MySQL service tests search
unexpanded catalogs across two services and check independent SQL transactions.
Existing Go catalog cases cover quoted routines/overloads and all detail kinds.
All are prepared/typechecked only, not executed evidence.

Completed static checks only: default/native-smoke all-target check, both all-target
Clippy with warnings denied, formatting and whitespace. Logs are ignored
build/gpui/task14-{check,feature-check,clippy,feature-clippy,fmt,whitespace}.log.
No Rust/Swift/Go/database/UI/credential tests ran; existing block 0.1.6 future
notice remains. Task 2, Task 29 GNOME session-end native observation and all 171
native cells remain open; Task 29 below records the adapter's implementation.

Task 14 final integration validation (unchecked):

- [ ] Run default and native-smoke catalog::tests and commands::tests with completed summaries.
- [ ] Run native-smoke workspace_tests and isolated PostgreSQL/MySQL integration.
- [ ] Run existing Go race/catalog tests, quoted routines/overloads and engine versions.
- [ ] Exercise search delay/coalescing/reconnect/helper-loss errors and retry on real desktops.
- [ ] Verify context/double-click/keyboard actions, actual clipboard, definitions and SQL isolation on Windows 11 and Ubuntu Wayland/X11.

Final commands: `./scripts/gpui-prototype.sh test --locked -- catalog::tests --test-threads=1`,
its `--features native-smoke` variant, native-smoke workspace_tests,
`./scripts/test-gpui-databases.sh` and `./scripts/test-go.sh`. Use matching native
helpers/build runners; record skips. APIs and Task 15/23 extension obligations are
in CATALOG.md; do not widen restoration DTOs or bypass common close/file guards.

## Task 15 table document notes

Code-ready on 2026-10-19. See TABLES.md, tables.rs, catalog.rs and commands.rs.
Table/view documents use captured connected profile service work, never SQL-tab
sessions or implicit connection/execution. Each read runs columns/browse/columns;
matching typed metadata/ordinals/engine/widths and complete <=200 rows publish as
one application snapshot with committed navigation. Failed/stale/locked work
keeps old metadata/rows/grid/page/sort/filters with error. Full pages enable only
possible Next, empty next pages retain Previous, and checked protocol page limits
prevent overflow; no COUNT/lookahead or result-count estimate is introduced.
Server sort and nine typed explicit filters stay distinct from local loaded-view
sort/filter. Exact string/null/binary values remain typed. No-PK order notices
accurately disclaim stability even without changes. Read-only views and typed
ReplacementLocks prepare Tasks 17-19 without adding edits. Common command/menu
captures retain original table/service/snapshot/revision; safe SQL-only DTOs and
existing close/final-flush behavior remain intact.

Shared Go changes are narrow: both adapter no-PK notices; MySQL missing browse
returns known failure; exact MySQL integer/DECIMAL parameters receive validated
literal-scale DECIMAL casts without floating conversion, native-column rounding,
clamp or SQL interpolation. Signed decimal/exponent normalization rejects
unrepresentable values/specials explicitly. Protocol v3/fixtures/Swift UI unchanged.

Prepared pure/headless/DB cases cover nine operators and exact/null/binary values,
200/201/empty pages, PK ties, no-PK views, injection-as-data, changed metadata,
third-request failure, stale success/error/newer filter, per-document retention,
SQL transaction isolation and late replacement locks. Go cases add adjacent >2^53
decimals, int64/uint64, 65 digits/30 fractional places/exponents and invalid values.
These are prepared/typechecked only, not executed evidence.

Completed static checks only: default/native-smoke all-target check and Clippy
with warnings denied, formatting/whitespace; Go MySQL/session test binaries compile
without execution. Logs ignored build/gpui/task15-*.log. No Rust/Go/Swift/database/
UI/credential tests ran. Existing block 0.1.6 future notice remains. No target-native
runtime acceptance is inferred. Task 2 and all 171 native cells remain open;
Task 29 below records the delivered Ubuntu GNOME adapter; actual session-end
observation remains open.

Task 15 final integration validation (unchecked):

- [ ] Execute tables::tests, native-smoke catalog::tests/commands::tests/workspace_tests with completed summaries.
- [ ] Execute prepared Go exact numeric/browse/missing-object regressions and both disposable database suites across supported engine versions.
- [ ] Run focused Swift browse/catalog/navigation/grid regressions for shared helper behavior changes.
- [ ] Verify actual previous/next/sort/filter/Enter, local view distinction, per-document retention, no-PK notices, DDL/privileges/helper loss/stale callbacks and independent SQL sessions on Windows 11 and Ubuntu Wayland/X11.

Final commands are in TABLES.md: focused Rust tests, test-gpui-databases.sh,
test-go.sh and focused scripts/test.sh filters. Record precise passes/failures/skips.
Task 16 consumes ordinal grid state and committed snapshots; Task 17 consumes typed
metadata/result-column/snapshot fingerprints and ReplacementLocks. Preserve the
same captured scheduler/context/atomic-publication boundary for later editing.


## Task 16 grid interaction notes

Code-ready on 2026-10-19; GRID.md defines precise reconciliation and Task 17 APIs.
Per-operation/result TableState entities retain ordinal widths, viewport, local
sort, selection and details. Visible indices map explicitly to original source
ordinals/row IDs. Same-schema/same-navigation Refresh reconciles unique PK or
exact unique no-key rows; schema/server navigation/new operation never retargets
selection by index. Rectangles, sparse/full rows, mouse/context/key navigation,
field precedence and SQL grid/field refusal share retained state. Original
read-only details show exact/multiline/Base64/type/capability/reason information.

Actual selection Copy prepares Swift v1 JSON plus no-header selectively quoted
TSV before native publication. It preserves duplicate ordinals, NULL/empty/literal
NULL/marker collision/exact numeric strings and binary. Standard Edit Copy and
primary+C route common GridCopy with original entity/result/snapshot; Copy Rows
remains its separate loaded-view operation. Context actions capture original
payload/context cell and refuse stale replacement/retired operation. No paste,
staged edits, Preview/Apply, SQL session borrowing or restoration widening is added.

The owned Windows adapter prepares registered-format/HGLOBAL data before
EmptyClipboard and honestly reports partial publication. Mac development uses
the official GPUI text path plus the Swift NSPasteboard type. The bundled pinned
GPUI Pre Linux 0.3.9 patch promotes a bounded fixed-format envelope to real
Wayland MIME offers/FD sends and X11 TARGETS/INCR data, using existing lifecycle,
input serial and selection threads. It is not merely cached GPUI metadata.
Source hash/license/patch audit are in vendor/gpui-pre-linux/README.md; include
Apache notices in Task 31. No third-party clipboard utility/daemon/global hook.

Prepared pure/headless cases cover rectangle/sparse/full-row and actual cell/key
callbacks; duplicate ordinals/source mapping; NULL/empty/literal/marker/exact/
binary/multiline/large data; key/exact-row refresh, duplicate/missing identities,
page/schema/new result selection invalidation; retained entities/details/field
focus and stale common copy. Native-format serialization and the actual Linux
envelope parser are also compiled on the development host. None executed.

Completed static checks only: default/native-smoke all-target check and Clippy
with warnings denied, fmt and whitespace. Logs: ignored build/gpui/task16-*.log.
The existing block 0.1.6 future notice remains. Windows ABI and actual Linux
backend cfg branches are uncompiled/unrun on this Mac host, so native external
consumer acceptance remains open. No Rust/Swift/Go/DB/UI/credential runtime test
or clipboard probe ran. Frozen baselines/manifests/reference/shared fixtures
are unchanged; Task 2/all 171 native cells and Task 29 GNOME native observation
stay open. Task 29 below records the adapter's production integration.

At final integration run GRID.md's focused results/native_/native-smoke results
and commands tests with completed summaries; use native Windows/Linux build
runners to compile adapters and verify real external format consumers, native
input/IME/focus/resize/large-grid timing and refresh/result/context races.
Task 17 must retain original typed rows/column fingerprint/snapshot/source-row IDs,
set TableDocument ReplacementLocks before drafts, and preserve CloseToken,
Finishing/latest-state flush, retained editors and SQL-only disconnected DTOs.


## Task 17 typed staged-change notes

Code-ready on 2026-10-19. CHANGES.md is the durable contract and Task 18 handoff.
grid_changes.rs separates immutable typed originals from ordinal assignments and
projected rows. changes_view.rs retains captured inline/expanded editors, visible
capability reasons, Columns, markers/pending counts and explicit local Discard.
Copies/details use projected values with existing Swift v1 DEFAULT semantics;
original CAS values and numeric/binary/temporal strings remain exact. No local
editing action submits a helper request; Tasks 18-19 now supply Preview/Apply.

ChangesBatch freezes Capture+ChangesRequest, including original document/result/
grid, full original profile/settings/service/helper context, ordinal metadata/
result-column/snapshot fingerprint and draft revision. Table ReplacementLocks
block late navigation/replacement. ClosePhase::Changes/CloseToken retains exact
grid revisions; Discard clears only after later decisions/ACKs/final flush,
and successful profile publication. Cancel, stale callbacks and failed profile
mutation retain drafts and the same inline editor. Clear SQL Drafts scopes SQL
only; no table draft enters SQL DTOs. Task 29 below records GNOME implementation;
native logout/session-end observation remains open.

Prepared pure/headless cases cover originals/composite keys, update/revert/insert/
delete, generated/default/null/empty/literal/binary/exact/temporal values, ordinal
metadata/capabilities, selection mapping, immutable batch staleness, focused Run
refusal, retained editors/cancel, pending/late browse locks, helper-call counters,
Return/Escape/repeated close/later transaction Cancel/stale revisions, SQL-only
clear and profile failure. They are compiled code, not executed evidence.

Completed static checks only: default/native-smoke all-target check and Clippy
with warnings denied, fmt/whitespace; ignored logs build/gpui/task17-*.log.
Existing block 0.1.6 future notice remains. No runtime Rust/Go/Swift/database/UI/
credential/clipboard test or native Windows/Linux compilation ran. Frozen baseline,
manifests/reference/shared fixtures and SwiftUI/AppKit are unchanged.

Task 17 final integration validation (unchecked):

- [ ] Run CHANGES.md's focused grid_changes/results/close and native-smoke changes_view/commands/catalog cases, retaining completed summaries.
- [ ] Run disposable PostgreSQL/MySQL integration across supported engine versions and authoritative capability/permission/type/generated/default/binary/temporal cases.
- [ ] Verify actual native editors, focus/IME/input/Undo, selection/copy DEFAULT, Columns/markers, late browse and all Discard/Cancel/profile-failure origins on Windows 11 and Ubuntu Wayland/X11.

Task 2/all 171 native cells and Task 29 GNOME native observation remain open;
Task 29 below records the adapter's implementation. Task 18
must consume immutable ChangesBatch and revalidate metadata/policy/session/draft
ownership before every asynchronous submission/completion, using fresh idle
Preview/Apply sessions; it must not borrow SQL or catalog sessions.

## Task 18 immutable preview notes

Code-ready on 2026-10-19; PREVIEW.md is the durable contract and Task 19 handoff.
preview.rs owns typed Plan/PendingPreview/Previewed/PendingPreparation/Preparation,
purpose-bound FreshSession, sticky Cancellation and exact Arc/session/revision
Approval. Backend begin_assessment exposes its existing query ID at enqueue time;
wire v3 and frozen artifacts remain unchanged. Standalone preview_view.rs freezes
ChangesBatch, checks original table/profile/helper/draft after every await and
review, displays generated SQL separately from typed values, revokes unused grants
and awaits original-session teardown before review/unlock. Stop uses original
session/query plus captured flow token; no SQL-tab/catalog state is borrowed.
Task 19 now creates another fresh Purpose::Apply session for actual submission
and recovery; see APPLY.md.

Prepared pure/backend/fault cases cover typed values/order/display, stale proof,
session/Arc/revision grant scope, cancel before/after readonly submission, preview
failure/retry, failed teardown/retry and original helper replacement. Headless
production validation/locks/Stop/close cases cover per-stage mutable contexts and
draft preservation. Disposable PG/MySQL cases compare observer rows and unrelated
SQL transaction/SET state around two fresh previews of composite-key typed changes.
These are prepared cases, not executed evidence. Native credentials/UI timing,
temp-state and Windows/Linux acceptance remain open. A hung connect/query/teardown
keeps original ownership and close refusal; no mutation uncertainty is fabricated.
At this checkpoint Task 22 still owned complete close-graph integration; its
delivery is recorded below. Task 29 likewise records the delivered GNOME adapter;
actual session-end observation and Task 2/all 171 native cells remain open.

Completed static checks only: default/native-smoke all-target check and Clippy
with warnings denied, fmt/whitespace; logs build/gpui/task18-*.log. Existing
block 0.1.6 future notice remains. No runtime Rust/Go/Swift/DB/UI/credential/
clipboard tests/probes or target Windows/Linux compilation ran. PREVIEW.md lists
final focused preview/backend/headless commands and test-gpui-databases.sh.


## Task 19 atomic Apply and recovery notes

Code-ready on 2026-10-19; APPLY.md is the durable lifecycle contract and Task 20
handoff. Apply freezes new ChangesBatch, opens another original-helper idle
session, re-previews/assesses exact changes.apply, reviews exact SQL/bindings and
submits only with same-Arc/session/revision approval. Synchronous enqueue publishes
the owned query ID; one-shot revision consumption invalidates every old approval.
Stop stays sticky through credentials/connect/review and drains authoritative Apply
completion before original-session revoke/disconnect. Cleanup failures retain the
completion and session for cleanup-only retry. No mutation SQL or protocol/adapters
changed; Go remains full-row CAS/row-lock/metadata/atomic rollback authority.

A known commit clears only its matching draft revision and requests readonly
reload through the original captured table service when still valid. Failed/stale
reload leaves ReloadRequired, never a retryable committed batch. Submitted
transport/lost-COMMIT ACK leaves Unknown with original rows/drafts; disconnect
cannot prove rollback. Inspect Data must publish a successful validated new
snapshot on exact live helper/settings/service generation before Discard and Reload
can acknowledge inspection and clear the local batch. Empty/failed/stale inspection
cannot authorize recovery; failed reload still blocks editing/Apply/export. Existing
normal close refuses active flows or unknown outcomes until Task 22 composes the
complete graph. SQL-only restoration/history DTOs and latest Finishing semantics
remain unchanged. Task 29 below records GNOME implementation; actual session-end
observation and Task 2/all 171 native cells remain open.

Prepared pure/backend/fault/headless cases cover proof consumption/query IDs,
Stop before/after submission, known commit versus rollback, lost terminal/helper
death, cleanup retry/original client, stale post-submission context, known commit
plus failed reload, disconnected unknown, empty/stale inspection refusal, explicit
recovery and confirmed loaded export rows. Extended PG/MySQL orchestration cases
cover composite/generated/default/exact/binary success, later conflict/missing/
constraint rollback, metadata-after-preview races and independent observer plus
unrelated SQL transaction/SET/private temporary-table state. Existing Go suites
cover both adapters' deadlock/cancel and real lost-COMMIT-ACK observer seams.
These are prepared cases, not executed evidence.

Task 20: confirmed_loaded_table_snapshot(document,cx) captures confirmed backend
physical rows in original loaded order, excluding local projection/selection and
any draft/browse/Preview/Apply/cleanup/Unknown/ReloadRequired state. It allows a
clean disconnected snapshot without query or credentials. Retain exact document/
result/grid/snapshot around native save, respecting the export's own modal owner.
Inspect frozen Swift ResultExport.swift and the two exportLoaded call sites for
JSON/CSV/NULL marker/truncation/save details. Task 22 must preserve retained flow
completion, original-client ownership, deferred Discard and latest-state flush.

Completed static checks: default/native-smoke all-target check and Clippy with
warnings denied, fmt, fixture Python syntax and tracked/untracked task-file
whitespace. Logs ignored build/gpui/task19-*.log; existing block 0.1.6 future notice
only. No Rust/Go/Swift/DB/UI/credential/clipboard runtime test/probe or native
Windows/Linux compilation ran. APPLY.md lists final-integration commands and
acceptance obligations; retain completed summaries and precise skips then.


## Task 20 loaded export notes

Code-ready on 2026-10-19; see EXPORTS.md and exports.rs/export_view.rs. JSON/CSV
menu and toolbar actions retain immutable original document/result/grid/snapshot,
source/session/profile/settings generations before review and the native Save
picker. Review discloses actual loaded/reported counts and truncation; CSV requires
a nonempty collision-free NULL marker. Every continuation revalidates ownership.
All physical original loaded rows export in backend order; local filter/sort and
selection do not restrict output. Table and same-object sibling edits, browse,
Preview/Apply/cleanup and unresolved recovery block export. Clean disconnected
snapshots export without credentials/connect/query/assessment or SQL-file changes.

The pure encoder matches unchanged protocol/fixtures/export.json and the new
loaded-export-v1.json shared consumer cases. Ordinal metadata/value arrays retain
duplicate names, exact numeric strings, Base64, NULL/empty/literal NULL and Unicode/
CRLF. Swift/Rust loaded CSV compares exact CRLF bytes; Go full export retains its
existing LF/full-scope semantics with shared parsed-value checks. No wire change,
frozen fixture/manifest/reference/hash/replay rewrite or production Swift/Go
change was needed. New Go/Swift test consumers are prepared but unexecuted.

Native overwrite-confirmed destinations capture identity/stamp/bytes or explicit
absence before encoding. PreparedExport reuses owned PreparedSave temporaries,
locks, permission/DACL preservation, symlink/parent/external-edit checks and
one-shot atomic publication. Temporary cleanup now verifies original handle
identity so an unrelated replacement is not removed. Windows ambiguity remains
explicitly unverified, never an unchanged-file claim or automatic retry. All
failure/cancel/stale paths preserve SQL file binding/source clean state.

Prepared pure/headless/fault cases cover shared values and bytes, empty/large/
truncated sets, malformed counts/ordinals/widths, CSV collisions/quoted marker,
original-tab publication, chooser Cancel/stale context/token, table/sibling gates,
zero helper requests, appeared/externally changed/locked destinations and Windows
deny-sharing. FILES.md retains existing sync/permissions/DACL/rename fault cases.
These are prepared code, not passed tests. Task 21 receives Format/marker and
CapturedDestination/PreparedExport APIs; Task 22 still owns the full close graph.

Completed static checks only: default and native-smoke all-target check and Clippy
with warnings denied, formatting and whitespace. Logs are ignored
build/gpui/task20-{check,feature-check,clippy,feature-clippy,fmt,whitespace}.log.
Test targets compiled; the new Go consumer compiled with `go test -c` only,
and Swift application/test targets compiled with `swift build --build-tests`.
Additional logs: task20-go-compile.log and task20-swift-build.log. Swift retains
existing sandbox cache and Command Line Tools search-path warnings. No
Rust/Go/Swift/database/UI/credential/clipboard test or probe ran. Cargo retains
only the existing dependency block 0.1.6 future notice.
Actual Windows/Linux target branches, pickers/overwrite/cancel, locked/permission/
ambiguous publication and accessibility need final native validation. Task 2 and
all 171 native cells remain open; no parity acceptance is claimed.

The coordinated independent Task 23 language-service and Task 26 appearance cores
are declared in main.rs and included in static compilation. Their narrow local
dead_code allowance is temporary until their actual UI integration. Task 23's
editor/process/catalog lifecycle and Task 26's settings startup/persistence/theme
workflow remain pending; compilation of those cores does not complete either task.
Task 29's independent platform core is not declared or integrated in Task 20.
Its requested Linux zbus dependency and main declarations are handed to Task 21's
shared-file integration boundary after that agent reports readiness.

Final-integration execution commands and required native acceptance are in
EXPORTS.md. Keep completed summaries and explicit skips; do not promote compiled
test targets or simulated chooser cases to actual desktop evidence.

Task 20's shared integrator made only parent-authorized mechanical Clippy fixes
in the frozen language-service core: collapse a nested notification-error check,
initialize a ContextKey test value directly, and remove needless fake-helper
path borrows. No service behavior or ownership scope was expanded. These paths
were re-frozen before final static evidence; actual Task 23 integration is pending.


## Task 21 full export and shared integration notes

Code-ready on 2026-10-19. RUN_TO_FILE.md is the durable execution/publication and
Task 22 ownership contract. Common RunToJson/RunToCsv capture exactly one resolved
statement, original document/source/profile/settings/session, operation token,
format/marker and native destination identity/hash before credentials. Existing
SQL-tab physical sessions retain temp/SET/transaction state. Assessment/grant and
one execute submission carry the exact same export payload. Full Go streaming
bypasses every display limit without loaded-row encoding or a second SQL run.

Full query.progress uses correlated cumulative row/result counts and shared
stream.ack sequencing so it cannot overtake its terminal. Original-client Stop
awaits authoritative SQL/transaction recovery; ACK is never completion. Stale
source or active-tab changes do not redirect history, busy release or recovery.
Transient run_file_recovery retains original operation/query/session/generation,
export binding, SQL certainty and independent publication certainty. Pre-adapter
refusal is explicitly Not executed and creates no history. Known SQL success
plus publication failure is distinct from uncertain SQL/commit, with no SQL replay.

The helper now checks captured regular destination/parent identities and exact
hash/size/time, creates private same-directory output, hashes all generated bytes,
flushes/syncs and rechecks temporary identity/digest before publication. Unix
cooperative locking/no-replace publication and explicit Windows owner-only DACL,
ReplaceFileW/MoveFileExW replacement preserve known-failure destinations. Documented
partial Windows errors remain publication-unverified. Cleanup never deletes a
substitute at a temporary name or the destination as a retry fallback. Native
sharing/DACL/permissions/power-loss/fault acceptance remains open.

Protocol v3 gains optional capturedExportV1 hello capability, destination fields,
ACK-sequenced query.progress and sqlCompleted/sqlNotExecuted/exportPublication.
Rust/Swift refuse a captured export before SQL if the capability is missing;
legacy absent outcome fields cannot prove success. New run-to-file-v1.json has
Rust/Go/Swift consumers; all frozen fixtures/manifests/reference hashes remain
unchanged. SwiftUI/AppKit stays the macOS product, with matching safe capture and
protocol handling. Task 31 must add exact packaged GUI/helper build matching.

Prepared cases cover pure one-statement/client-command/destination refusal;
headless chooser Cancel/stale source/profile, original-tab late Stop/terminal,
one history entry and known SQL/file versus unknown SQL recovery; fake-helper
exact payload/grant/count/full progress/late ACK/helper loss/legacy capability;
Go complete JSON beyond all display budgets, CSV multiple sets/collisions,
original-target/temporary/readonly/lock/cancel/sync faults and SQL drain/counts;
Windows deny-delete-sharing; additive shared contract consumers; and disposable
PostgreSQL/MySQL independent observers, full counts, exact-once effects and SQL
session temp/SET/transaction preservation. These tests were compiled, not run.

Final static evidence for this frozen declared scope completed with exit 0:

- Default and native-smoke all-target cargo check --locked --offline.
- Default and native-smoke all-target Clippy --locked --offline -- -D warnings.
- cargo fmt -- --check; tracked git diff --check; new owned-source whitespace
  scans. The existing block 0.1.6 future-incompatibility notice remains.
- Host Go exportfile/protocol/session test binaries compiled with go test -c;
  host helper built. Windows amd64 exportfile test binary cross-compiled and the
  complete Windows helper cross-built. No binary was executed.
- Swift debug product and all test targets built with swift build --build-tests.
  Existing Keychain/AppKit deprecation, user-cache and Command Line Tools search
  path warnings remain. No Swift/AppKit suite was executed.

Logs and the declared-source SHA256 list are under ignored build/gpui/task21-*;
static command completion is also recorded in task21-static-results.json.
No Rust/Go/Swift/database/UI/credential/clipboard test or probe ran. No supported
Windows/Linux frontend native compilation or runtime coverage is claimed. Task 2
and every one of the 171 native acceptance cells remain not-run.

### Shared-core boundary for Task 22

The frozen Task 23 language_service and Task 26 appearance cores remain declared,
with actual Workspace/editor/Settings lifecycle pending. Task 27 theme_library and
Task 28 shortcuts are now declared and included in both static configurations.
Theme library has a temporary declaration-level unused-import allowance while its
UI is pending; its existing module dead-code allowance is unchanged. Exact new
Cargo dependencies are roxmltree 0.21.1, plist 1.10.1 with bounded streaming APIs,
sha2 0.10.9 and Linux zbus 5.19.0/async-io. Cargo.lock is resolved and --locked checks
complete. Theme/shortcut runtime tests and actual library/Settings/registry wiring
remain pending; a compiled core is not completion of those tasks.

Task 29 froze its existing Linux vendor key-safety hook, preserving Task 16's
clipboard code. The already declared gpui-pre-linux dependency contains that ABI;
Mac static checks do not compile Wayland/X11 branches. Task 29's new accessibility
and session_end modules, vendor/gpui-component and vendor/gpui-base are frozen but
are NOT declared/patched by Task 21. Task 22's integrator may add both exact
[patch.crates-io] entries and modules, then repeat root static checks against that
new scope. Component/base still resolve from registry in Task 21's lockfile.
Task 31 product identity/packaging core is in progress and undeclared; its new
package scripts are owned by that worker. No Task 29/31 production integration is
claimed here.

Task 22 receives run_file token/phase/capture/export/operation; original
DocumentState operation/phase/query_id/session/session_generation and QueryTab
operation_client/task; run_file_recovery original-client/operation/query/session/generation/export/
sql_completed/outcome_unknown/publication; separate loaded-only export_request,
file_request and Preview/Apply owners. Close/profile changes currently refuse
while run_file exists. Compose those phases with CloseToken, deferred draft
Discard, known committed ReloadRequired versus Unknown recovery and the latest
Finishing SQL flush. Never drop a submitted query Task or disconnect a replacement
helper as cancellation proof. The prompt resolver still has no prompts/task.md;
this task used the parent's explicit fallback instructions. No branch, commit,
staging, publication or frozen evidence was changed.

Final Task 21 ownership audit retained the original BackendClient in transient RunFileRecovery after authoritative completion, so an open physical SQL session survives replacement of Workspace.backend. Subsequent operations on that matching captured session choose its retained helper; Task 22 must also use that client for close transaction/disconnect resolution. The prepared stale-source/late-Stop headless case now replaces Workspace.backend and checks helper identity. Both all-target check and Clippy configurations and fmt completed again with exit 0 after this fix; no runtime tests ran.


## Task 22 implementation and final integration handoff

Task 22 is code-ready on 2026-10-19. All three implementation route items are
checked; runtime and target-native gates remain unchecked. No Rust/Go/Swift,
database, UI, credential, clipboard or session-manager runtime test/probe ran.
Task 2 and all 171 frozen native cells remain not-run. Mac GPUI remains a
development host; the macOS SwiftUI/AppKit product is unchanged.

The common close graph now captures original file_request/loaded export/run_file/
Preview/Apply owners and tokens, preserves existing review/native chooser futures,
waits or explicitly Stops affected work, and drains authoritative terminals,
publication and original-session cleanup. It never retargets active selection or
uses cancel ACK as completion. Catalog work has Wait/Cancel. Close Apply projects
inline input immutably, retaining its editor on Cancel/rollback, then opens a new
fresh purpose-bound session and performs ordinary exact preview/assessment/explicit
review/one-shot Apply. Known committed ReloadRequired remains distinct from Unknown.
Unknown-local-discard close matches actual Swift and remains available without DB
inspection merely to close; any retained document still requires successful current
inspection, explicit Discard and Reload, and successful reload before Apply.

General physical SQL SessionOwner now retains exact helper instance/session/
generation beyond success/cancel/known errors. Next Execute/COMMIT/ROLLBACK and
Disconnect use that owner, including Task 21 RunFileRecovery.client, never a
replacement helper with the same textual ID. Catalog services retain their original
helper too. Missing/stale ownership refuses. Transport usability is not actual
process exit: owned_process_exited uses retained Child try_lock/try_wait. Broken
transport preserves sessions until exact exit observation or real disconnect ACK;
unobserved exit refuses retryably. Explicit unknown acknowledgment plus observed
dead owned helper permits local teardown without fake ACK/rollback. Tab/profile
close never initiates helper termination and preserves sibling profiles/sessions.
Window Finishing retains all original client Arcs through ACKs and awaits exact
owned-child shutdown/reap before the latest local flush. Owned reapers no longer
hold the child mutex while waiting after a failed kill.

Discard stays revision-bound and deferred through later review, final flush and
successful profile publication. Clear SQL Drafts stays SQL-only. The latest-state
SQL source/history loop is preserved and extended with purpose-bound finalizers
for LanguageService/Appearance/ThemeLibrary/Shortcuts. Each registered original
owner supplies an immutable token/intent/document capture, owned future and
revision; finalization awaits and rechecks/reflushes newer revisions before removal.
Actual LSP/preferences/library/shortcut UI stores are not loaded yet.

Task 29 accessibility/session_end modules and exact gpui-component/gpui-base
0.7.3 path patches are now declared and Cargo.lock resolves them. No frozen vendor
source was functionally changed. The maintained Linux attach_session_end hook
observes registration generations, publishes Absent/Waiting common ownership and
awaits exact unregister/shutdown during normal window Finishing. No signal invokes
Quit/modal or marks Reviewed, and no premature Ready is advertised. Production
startup attachment/real native selector population and Windows/Linux compilation/
UIA/AT-SPI/focus/session delivery remain Task 29. Its dependency unit targets are
not built by root all-targets; Task 29's prior separate unit-target compile evidence
is retained, not repeated or claimed newly here.

Task 31 frozen product_identity is now declared. Two coordinated narrow core fixes
were made: a lifetime-general closure around env::var_os in its test and embedded
identity rejection of GNU Windows/musl Linux ABI mismatch. No Task 31 startup/helper/
package behavior integration is claimed. Actual Swift export capture omits optional
modifiedNanoseconds rather than converting NSDate/Double to Go UnixNano; the late
proposed cross-language timestamp-rounding concern was not present.

Prepared cases were added/updated for original helper/same textual session after
success/cancel/error and stale terminals, exact disconnect versus replacement,
transport versus actual owned exit, dead-helper explicit unknown close, shared-helper
sibling profiles, immutable inline projection/selection, deferred Discard/later
Cancel, cleanup-failure common-close release with retained terminal, native chooser
future retention and latest awaited preference revision. Existing script/full-export/
Apply fake-helper and real two-database observer cases remain unexecuted. CLOSE.md
lists final commands and native requirements.

Fresh Task 23 integration must own only its current retained language service,
advance exact document/context/process revisions, register close::finalizers::Finalizer
under LanguageService, close affected documents for tab/clear/profile mutations and
await its actual bounded shutdown for window close. Capture the original service in
each future; recheck its current revision after awaits. No LSP state may widen SQL
restoration or open a DB while typing/restoring. Tasks 26/27/28 must register their
actual revision-bearing stores under their separate finalizer kinds and consume the
maintained Editor::editor_style explicit-RGBA seam without replacing EditorState.

Task 30 handoff remains actionable: frozen new portable fault-helper needs existing
factory/cfg integration, its exact disposable marker/flavor/UUID contract and Windows
owned-exe teardown before directory removal. Existing Unix/Python-only faults are
not Windows coverage. live_tests.rs still has a fixed-delay slow-query cancellation
case; fresh Task 30 must use the existing physical server observer barrier before
native DB execution. Task 32 requires real stable native AutomationId/AT-SPI IDs on
rendered controls, not local GPUI Button IDs or name/index fallback. No baseline,
reference/replay, frozen fixture/hash, release metadata, branch or commit was changed.

Final Task 22 static evidence completed with exit 0 for this exact declared scope:

- Default and native-smoke `check --locked --offline --all-targets`.
- Default and native-smoke `clippy --locked --offline --all-targets -- -D warnings`.
- `fmt -- --check`, tracked `git diff --check`, and explicit source/Cargo/docs
  trailing-whitespace scans (134 files, zero findings).
- Cargo.lock includes the exact local gpui-component/gpui-base 0.7.3 path patches;
  accessibility/session_end and frozen product_identity are included in root
  compilation. No vendor dependency unit-target rerun is claimed.

Completion records: ignored build/gpui/task22-static-results.json, final logs
build/gpui/task22-final-*.log, task22-scan-results.json and declared-source SHA256
list. Only the existing block 0.1.6 future-incompatibility notice remains. These
are compile/static results, not tests or Windows/Linux native build/acceptance.
Runtime execution remains deferred until final integration after remaining code.

## Task 23 retained assistance integration (2026-10-19)

The isolated language core is now connected to actual retained SQL editors,
profile/dialect/source/context lifecycle and the original connected catalog Work
scheduler. `assistance` retains one worker owner and one latest bounded snapshot;
all process startup, configuration serialization, request cancellation, restart,
shutdown and final service drop run on that worker. Source changes never access
credentials or database sessions. Active tabs rotate within the core's document/
byte limits without reconstructing any editor; oversized assistance is explicit.
Catalog completion pages capture full original service settings/client/session/
physical epoch/work/refresh generations before and after every page, publish one
whole validated snapshot, preserve previous metadata on failure and invalidate
eligibility on disconnect/profile/helper changes. Explicit Refresh coalesces.

One current LanguageService finalizer awaits didClose writer delivery for affected
documents and bounded actual owned shutdown for Window. Its revision is checked
again before the latest SQL flush/removal. Failed/cancelled close reopens the same
current source context; pending Retry cannot spawn after final shutdown. LSP
state stays outside all profile/history/restoration DTOs, and existing SQL session
ownership, uncertain-outcome recovery, Root modal and close guards are preserved.

Tasks 24/25 consume `Workspace::assistance_request`, `RequestOwner` typed async
completion/signature methods, `assistance_capture_current` and the transient
versioned diagnostics map. Exact handoff and Go field semantics are documented in
LANGUAGE_SERVICE_CORE.md. Completion popup/insertion and signature UI are not
claimed here. Test cases are prepared, including fake LSP counts/stale source/
request cancellation/reopen/owned restart, DTO/active bounds/retained editors,
metadata failure/stale physical service and real both-adapter paging alongside
an independent SQL transaction. None has executed.

Completed static checks: default/native-smoke all-target check and both Clippy
with warnings denied, formatting and whitespace; ignored `build/gpui/task23-*.log`.
Only the existing block 0.1.6 future-incompatibility notice remains. No runtime
Rust/Go/Swift/DB/UI/credential/clipboard test, Windows/Linux application build or
native acceptance ran. Task 2 and all 171 native cells remain open. The macOS
product remains SwiftUI/AppKit; GPUI Mac remains development only.

## Task 24 retained completion, insertion and syntax diagnostics

The retained Workspace now owns one bounded completion request/popup and a
separate native syntax DiagnosticSet owner for each SQL editor. Common Complete
SQL dispatch and protected native Ctrl+Space use the same stable document path.
Automatic invocation originates only in the original input's nonsilent,
noncomposition InputTextEvent; restoration, set_value, Undo and completion
insertion do not request assistance. No typing path connects, accesses credentials
or borrows a SQL session. Go remains the only scope, fuzzy matcher, priority,
quoting, ambiguity and FK JOIN/ON authority.

The debounce retains the original profile/settings/catalog/service/source and
native editor/full-selection/focus epochs. Every response, rendered presentation,
fresh-prepaint popup and synchronous insertion checks current Task 23 capture
ownership. Original selection/caret changes, including leave/return without a
text edit, have a checked independent native epoch; window/editor blur and close
cancel work. Native Tab/Return/Escape/navigation consumes only proven clear input
evidence. Multi-selection or selected text refuses completion unchanged. Rows
keep Go order and exact quotes/primary ranges, display disjoint composed-character
match highlights, retain uniform-list scrolling and use current caret geometry.

Maintained base `completion_selection_snapshot()` exposes every real anchor/head
and revision. `replace_completion_text()` performs one Atomic silent explicit
UTF-16 replacement without programmatic selection and captures the original
complete selection set for Undo. Syntax diagnostics convert validated byte ranges
to the native engine's scalar Positions, recheck source/context versions and stay
separate from execution decoration/status/error state. Optional service loss
clears assistance while ordinary editing and execution remain available.

Prepared verification includes shared matcher ranges, graphemes, bounded order,
plain edits, unsafe UTF-8/surrogate/CRLF/ranges, request/pointer/epoch races, native
key safety, retained Workspace selection/focus/modal/source ownership, and the
actual bundled Go offline contract for both dialects' scopes, ambiguity and
composite FK edits. The real base test target additionally prepares non-BMP/CRLF,
empty/single-character Atomic edits, one Undo/Redo, reversed/secondary original
selections, focus/IME refusal and epoch exhaustion. Existing fake-service and
actual Go matching/scope fixtures remain required at final integration.

Completed static checks: root default/native-smoke all-target check, both Clippy
configurations with warnings denied, formatting, maintained base lib/test target
check, current vendor provenance hashes, English/source-character and whitespace
checks. Exact status records and logs are ignored `build/gpui/task24-*`. The frozen
Task 25 signature core is declared and typechecked; its production integration
and implementation checkboxes remain separate. Settings view is source-frozen
but intentionally undeclared for its next integration owner. No runtime
Rust/Go/Swift/database/UI/credential/clipboard test, target application build or
Windows/Linux native acceptance ran. Task 2 and all 171 native cells remain open;
the macOS product stays SwiftUI/AppKit and Mac GPUI remains development only.

## Task 25 retained function signatures

Code-ready on 2026-10-19. `signature.rs` retains one original Workspace request,
75 ms source/caret debounce, bounded actor synchronization, null/error settlement
and checked independent cancellation epoch. The shared native capture includes
full selection/focus revision, actual original profile/settings/catalog/service
and LSP process identity before timers, replies, callbacks and fresh prepaint.
Source Change includes Undo/Redo/programmatic edits; selection observations and
render refresh signatures without Rust SQL parsing. Explicit Connect/Refresh
remain the only metadata paths. Common Complete SQL requests both assistance
surfaces; capture-phase safe Escape dismisses/suppresses pending help, while
completion navigation/Tab/Return retains priority and ordinary editing remains
native. Window/editor blur, tab switch, modal, close and Retry invalidate owners.

The Go service supplies names, types, defaults, variadics, return labels, nested
call/argument semantics, SUBSTRING FROM/FOR and overload order/active arguments.
The popup uses above-caret fresh geometry, bounded viewport placement, wrapped
scrollable labels and the same EditorPalette value applied to the retained SQL
Editor and completion popup. Task 26 will replace only that palette resolver with
persisted independent choices. Signature failures never mutate execution status,
source diagnostics, selection, focus or Undo.

Prepared cases cover actual bundled Go both-dialect semantics, real transport
normal/null/malformed/delayed responses, retained Workspace pending Escape,
native/context ABA and stale callbacks, optional failure caching, common
completion acceptance and one-step Undo. The real isolated-database case prepares
original-service function metadata after Connect/Refresh, changed return metadata,
zero added helper requests during source/caret signature updates, and preservation
of an independent SQL transaction. All are unrun; connected/no-query and native
theme/DPI/IME acceptance remain open. See SIGNATURE_CORE.md for final commands.

Completed static checks only: default/native-smoke all-target check, both Clippy
configurations with warnings denied, root formatting, updated std-only fixture
metadata compilation, source-character/whitespace checks. Exact logs/statuses are
ignored `build/gpui/task25-*.log` and `build/gpui/task25-static-results.json`.
Only the existing block 0.1.6 future-incompatibility notice remains. No runtime
Rust/Go/Swift/database/UI/credential/clipboard test, target application build,
native desktop or installed-upgrade check ran. Frozen cells/baseline/manifests,
Go/Swift semantics, signing and the macOS product remain unchanged.

Task 25 also declares the already frozen Settings and Theme Library UI cores and
fixes only compiler/import/control-ID issues found by native-smoke typechecking.
Their actual startup/preferences/library/chooser/OS/close Workspace integration
remains for Tasks 26/27. Neither implementation task is complete from declaration.


## Task 26 persistent independent appearance

Code-ready on 2026-10-20. `appearance_settings.rs` retains the original profile
data owner, one appearance store, one normalized library store, current choices,
resolved palettes, original Settings entity/subscription/focus, monotonic
preference/presentation revisions and latest reserved publication. Startup loads
library before saved selectors and applies full application/editor presentation
before the first visible frame. System/Lager/Porter and loaded named application
schemes, independent editor schemes and Follow App Appearance are real Settings
controls. Toggle uses that same persisted native choice. Actual GPUI appearance
notifications refresh toolkit mode then reapply named workbench tokens without
saving, changing source revisions, reconnecting or replacing entities.

Retained SQL, catalog definitions, SQL reviews, Settings preview and completion/
signature/diagnostic surfaces receive the independent editor palette. App/grid
field controls retain application roles. Live colors never rewrite text, source,
selection, scroll, Undo, grid or running operation/transaction ownership. Narrow
maintained Select APIs forward IDs onto existing ComboBox roots; exact native
UIA/AT-SPI properties remain unobserved. Vendor provenance hashes/notices are
updated; the broad temporary appearance/Settings dead-code allowances are removed.

Each writable change reserves latest full appearance-only preferences before
spawning. Broadcast completion lets UI and close await identical publication
proof. Only latest Published succeeds; Superseded/old success cannot mark newer
values saved. The registered Appearance finalizer retains original store/latest
revision and drains before final SQL snapshot/removal. Both stale errors and
stale successes reflush current revision. Fixed failure/retry/reload controls
preserve originals. Read-only startup and explicitly labeled previews reserve
nothing and do not trap close or silently overwrite corrupt bytes. Disposable
workspaces expose PreviewOnly without a false Reload or persistence claim.

Prepared integration cases cover startup/imported-ID restart, missing IDs,
corrupt/future/duplicate originals, common Settings routing, stale/closed owners,
System/named refresh, ordered saves, Retry/conflict/explicit Reload, original
editor text/selection/scroll/Undo, grid/running ownership, read-only close and
actual latest-close revision/failure drain with unchanged token/scope, latest-error
refusal/retry and the existing stale-success case. Dedicated fixture workflows prepare
real OS notification, target selectors/DPI, restart and close/Cancel observations.
At the Task 26 checkpoint, Task 27 import/removal/library finalization and Task 28
shortcut integration were pending; Task 27 integration is recorded below. The new Shortcut Settings view stays frozen/undeclared for Task 28.

Completed static checks: default/native-smoke all-target check; both Clippy
configurations with warnings denied; root/scoped-vendor formatting; exact vendor
hashes and owned English/whitespace/fixture JSON inspection. Exit codes, durations
and logs are ignored `build/gpui/task26-static-results.json` and `task26-*.log`.
Only existing block 0.1.6 future incompatibility remains. No new vendor unit test
code or Go/Swift changes required separate dependency/shared target checks.
No runtime Rust/Go/Swift/database/UI/credential/clipboard test or probe, native
Windows/Linux build, installed upgrade or acceptance ran. All 171 cells/Task 2
stay open. Frozen baseline/manifests/reference/replay, signing/trust/releases,
Git state operations and the macOS product remain unchanged. See
APPEARANCE_SETTINGS.md for exact final commands and ownership handoff.


## Task 27 normalized theme library and actual Settings workflow

Code-ready on 2026-10-20. `appearance_settings/library.rs` consumes the original
Task 26 LibraryStore/AppearanceStore/data owner and retained SettingsView. One
ThemeLibraryView with its original subscription/preview is mounted alongside
appearance controls. Both named menus and the section use the same actual eight
builtins and committed normalized imports. The ten GPUI source assets and four
original notices/licenses match Swift resources byte-for-byte; no Mac build,
original asset mutation, ignored docs or remote retrieval is required.

Actual native chooser requests capture original Settings/section/request/preference
identity before awaiting. Background parsing reuses existing bounded JSON/JSONC,
TextMate XML/binary and JetBrains/local-include normalization. Original request and
fresh preview token gate publication, commit, Cancel/Escape and retry. Browse/review
reserve nothing and never persist an uncommitted imported selector. Only accepted
explicit commit reserves the original library store synchronously. Recovery is
separate and preserves exact corrupt/future bytes privately before replacement.
Native picker limitations are explicit: no extension-filter or cancellation-handle
API exists; supported suffixes appear in its prompt and actual bytes are validated.
Canceled native futures remain retained until their original callback drains.

Only actual current Imported adds normalized values; original unchanged preference
revision and original live Settings/request gate a separate editor-only selection
save. A later explicit choice cannot be overwritten. Only Removed removes the
catalog entry and resets matching CURRENT selectors, followed by the separate
appearance reservation. Failed/Unchanged/Superseded removal retains selectors;
fixed errors expose safe original-intent retry or explicit Reload. Unverified
publication is never blindly retried. Disposable workspaces use truthful PreviewOnly.

Common close invalidates original uncommitted Settings authority and blocks new
mutations, while retaining all chooser/parse/reload/commit jobs and original data
owner. ThemeLibrary completion includes foreground reconciliation and required
appearance reservation; ThemeLibrary precedes Appearance in normal-close drain.
Latest mutation and preference publication must succeed before SQL snapshot/removal.
Stale success/error rechecks revisions; unchanged read-only fallback reserves no
write and cannot force recovery merely to exit. Existing SQL/file/transaction/
unknown/Cancel/session/helper guards remain authoritative and theme actions start
no database/helper/credential operation. Original editor/grid/preview entities,
source, caret, scroll, Undo and execution state are retained.

New prepared production cases cover real chooser responses, canceled/late picker
and background parse, exact request/preview stale refusal, review without writes,
newer choice during import publication, normalized restart after source deletion,
editor-only selection, remove-before-selector ordering and unrelated newer choices,
failed external-conflict removal, exact corrupt recovery, original native future
close drain, and common-close obsolete failure/latest library/required appearance
completion with original token/sibling scope. Ten target-native workflow descriptions
are in fixtures/theme-library-workspace/cases.json. Existing parser/store/view and
shared Swift/Rust fixtures remain required, unexecuted cases.

Final coherent root static snapshot includes the frozen Task 30 portable test peer
and Task 31 optional product-transport additions without completing those later
production tasks. All exit 0: default all-target check (1.28s), native-smoke check
(1.39s), default Clippy -D warnings (1.64s), native-smoke Clippy -D warnings (2.06s),
and root fmt --check (0.84s). Only existing block 0.1.6 future incompatibility remains.
Exact commands/statuses/logs: build/gpui/task27-static-results.json and task27-*.log.
The source/provenance/fixture/privacy scan also passes. The coordinated Task 31
Swift --build-tests compile-only build includes GPUIThemeParityFixturesTests
(build/gpui/task31-transport-swift/build.log, exit 0, Build complete 17.07s).
No new vendor unit tests, Go or Swift source edits were needed for Task 27 itself.

No runtime Rust/Swift/Go/database/UI/credential/clipboard test/probe, supported
native desktop build/acceptance or installed upgrade ran. Task 2/all 171 native
cells, runtime acceptance and Task 28+ full integration remain open. Frozen
baseline/manifest/reference/replay, owner signing/trust, release metadata/archives
and Git staging/branch/commit/publishing actions were unchanged. Task 27 source is
frozen; exact future commands and Task 28 ownership are in THEME_LIBRARY_SETTINGS.md.


## Task 28 configurable shortcuts and actual common Settings integration

Code-ready on 2026-10-20. `shortcut_settings::State` retains one original
ShortcutStore from ProfileStore::data_owner(), validated preferences, independent
monotonic projection/owner revisions and exact latest reserved publication.
Startup loads before first render. Corrupt/future/conflicting originals stay
read only with defaults active; disposable workspaces explicitly use PreviewOnly.
No SQL/restoration/profile/session/credential DTO changes exist.

The real retained ShortcutSettingsView is declared and mounted beside the
ORIGINAL Appearance and ThemeLibrary controls through the same Settings owner,
subscriptions, modal, preview and focus return. Common Settings > Shortcuts is
enabled. Actual focused Record/Rebind, Clear, Cancel, per-command Restore Default
and Restore All Defaults drive the five existing registry commands. Original
Settings/section/revision/pending epoch/focus checks reject obsolete callbacks;
owner candidates recompute against current preferences. Settings dismissal and
common close synchronously invalidate capture before original modal removal.

Accepted changes reserve the latest full valid value BEFORE dispatch. Broadcast
completion retains exact request/store/reservation for UI and close. Only latest
Published with latest_saved() projects Saved; handled no-change requests do not
orphan their actual in-flight reservation. Fixed failures expose current-value
Retry or explicit Reload; deliberate recovery preserves exact private original
bytes before replacement. Original IO tickets/futures survive Settings dismissal,
block overlapping edits and include foreground reconciliation before close drain.
Unchanged failed startup has no accepted writable mutation and cannot trap close.

The root synchronous native callback preserves Settings/recorder/modal/text-field
precedence and reads actual original focused editor marked text plus native
scoped dead-key/compose evidence. Exact NativeKey/modifiers, no key_char alias,
repeat/AltGr/unknown refusal and original scopes precede the SAME command capture.
Old generic Run/Script defaults are skipped at installation; generic candidate
binding helpers are now test-only. Fixed commands/native editing and completion/
signature popup priorities remain. Native matching, menus and toolbar text/tooltips
share one current preference value and refresh after edit/reset/reload/recovery.
No keycode substitution, global hook, direct backend action or editor replacement
is introduced. Stop/full export/Apply/uncertain/close/session ownership stays in
the existing common gates and immutable command capture.

A registered Shortcuts finalizer drains retained original IO and the actual latest
reserved save before final SQL snapshot/removal. Revision changes rerun stale
successes/errors with original CloseToken/sibling scope. Pending, failed or
Superseded writes refuse retryably. It preserves existing transaction/Stop/
unknown/Cancel behavior and original Appearance/ThemeLibrary finalizers.

Prepared owner cases add startup/clear/reset/restart/exact corrupt recovery,
preview/exhaustion/candidate-only/no-backend, actual superseded/latest publication,
shared Settings subscription/stale owner/retained editor-library-focus,
recorder precedence/marked text/AltGr/field refusal, exact native character-alias/
unknown/close gates, recovery and external reload after Settings dismissal,
and common-close stale-error/latest token/sibling drain. Existing shortcut core,
retained-control/IME/Tab/Escape/blur/epoch/conflict/private-store fixtures remain
required. All cases are UNRUN; compilation does not establish runtime behavior.

Completed static checks, all exit 0 with Rust/Cargo 1.99.1: default all-target
check (1.06s), native-smoke check (1.35s), default Clippy -D warnings (3.48s),
native-smoke Clippy -D warnings (4.75s), fmt --check (0.88s). Exact commands,
exit codes and logs: ignored build/gpui/task28-static-results.json and
task28-final-*.log. Only existing block 0.1.6 future incompatibility remains.
Broad temporary shortcut/view dead-code allowances are removed. No vendor unit
test, Go or Swift edits require separate target compilation. Source/privacy/
fixture/provenance scans and source-freeze hashes are recorded under task28-*.

Task 28 is at FULL SOURCE FREEZE. No runtime Rust/Go/Swift/database/UI/credential/
clipboard test/probe, target desktop build, installed upgrade or native acceptance
ran. Task 2 and all 171 Windows 11/Ubuntu Wayland/X11 cells remain open. Frozen
baseline/manifests/reference/replay, signing/trust/release metadata and the macOS
SwiftUI/AppKit product are unchanged; Mac GPUI remains development only.
Task 29+ production integration remains separate. Exact future commands and
handoff are in SHORTCUTS_CORE.md and SHORTCUT_SETTINGS_VIEW_CORE.md.

## Task 29 production native integration

Production integration is code-ready on 2026-10-20. Actual retained DataTable
root/row/header/cell wrappers consume the AccessKit bridge, original row/ordinal
identities and typed values. Native callbacks revalidate original Workspace,
document/source/result/snapshot/selection/draft/modal ownership before original
focus/scroll/menu/edit paths. Bounded large cells disclose omissions without
erasing other UI or expanding offscreen selection. No accessibility callback
fetches database data or bypasses staged editing/Preview/Apply.

Original SQL, definition, script/changes review, inline and inspector editors
retain live guards; Input captures independent native selection epochs and exact
top-dialog focus containment. Text actions preserve original Undo/IME/password/
readonly behavior and both palettes. Named dialog semantics follow actual popup
bounds with the original trap/FocusHandle. Retained keyboard context menus, Tab,
F2 and staged Delete use existing owners; recorder/protected command/completion/
signature priority remains unchanged. Weak menu/editor owner captures avoid new
retention cycles.

Normal Linux startup attaches the owned GNOME client. TerminalEvidence follows
original operation/disconnect ACK/helper exit/current-finalizer/latest successful
document publication. Only its exact common token/current registration can
publish Ready; bounded unregister continues only original terminal removal, with
no required flush following Ready normally. The retained readiness publisher
survives moving Client into teardown. Cancellation clears only OS association;
Response/Forced/loss create no close or transaction authority. An ignored native
owned-HWND delivery/lifetime harness is prepared for Windows.

Prepared production cases cover native properties/typed exact values, DEFAULT,
large-cell budgets, bounded offscreen selection totals, original focus/details
without backend work, stale source/snapshot/selection/modal actions, Tab and
keyboard-menu focus return. Separate dependency cases cover live owner refusal
and actual source-independent native selection ABA. GNOME cases cover retained
publisher ownership and registration staleness. All are unrun. Exact capabilities,
source author-ID candidates, limits and future commands are in
[NATIVE_INTERACTION.md](NATIVE_INTERACTION.md). Task 2 and all 171 native cells
remain not-run; Mac GPUI remains development only. No Rust/Go/Swift/database/UI/
credential/clipboard runtime test/probe or native acceptance has executed here.

Completed static checks only, Rust/Cargo 1.99.1: all ten commands exited 0
(check 2.14s; feature-check 2.26s; clippy 1.40s; feature-clippy 1.68s; fmt 0.91s; component-unit-check 2.36s; base-unit-check 0.36s; gnome-source-check 1.91s; gnome-source-clippy 0.43s; vendor-fmt 0.33s). Default/native-smoke checks and Clippy use --locked --offline --all-targets; both Clippy configurations deny warnings. Component/base library and unit targets are checked separately; the isolated actual GNOME source harness also passes check/Clippy, without running its private-bus cases. Changed vendor source formatting and exact current local-source hash/provenance audits pass. Only the pre-existing block 0.1.6 future-incompatibility notice remains. Exact commands/statuses/logs are ignored `build/gpui/task29-static-results.json` and `task29-final-*.log`. These are compiler/static completed-run summaries, not runtime tests or native Windows/Linux compilation/observation.

The named-dialog case additionally prepares same-live redraw/original-focus
stability and canceled/reopened generation ABA. Original ActiveDialog allocates
its checked monotonic owner only on open, retaining it through rendering/theme/
focus changes; no wrap/reuse is allowed. Descendant internal native identities
inherit that lifetime, independently of the explicitly published author ID.
Task 32's held real-helper/physical session-death source is included in these
checks; its runtime remains deferred. Task 29 is at full existing-source freeze.


## Task 31 product, build and packaging integration

Code-ready on 2026-10-20. BUILD_INTEGRATION.md describes the exact native wrapper
interface and its deliberately compile-only default; --test/-Test and
--package/-Package explicitly request future verification/packaging operations.
There is no extra CI approval variable or wrapper switch. Only the two existing
GPUI CI job blocks changed; the remaining workflow bytes, including SwiftUI Mac
build/signing, match the retained original byte extraction.

The actual GUI dispatches exact --build-info before graphics, feasibility,
workspace ownership/restoration, stdin, helper or credential code. Mixed metadata
arguments fail with fixed errors. Normal Windows/Linux startup requires a native
release identity, uses DBeer/app.dbeer.DBeer and sibling dbeer-core, and starts an
empty SQL document with no demo profiles/catalog/SQL. Restore stays disconnected,
including absent profile bindings. Actual saved-profile membership and explicit
Profile.demo metadata distinguish fixtures; saved demo-brewery remains real.
The first newly saved or explicit startup connection also receives empty SQL.
Explicit disposable Mac demo/smoke modes retain the development fixtures.

No filesystem or secret migration occurs. Original LOCALAPPDATA/DBeerGPUI and
XDG_CONFIG_HOME/dbeer-gpui defaults, canonical kernel .workspace.lock ownership,
UUIDs, backups, secure-store dev.dbeer.gpui-prototype and account IDs remain.
The common database handshake requires exact v3/gpui-v3-captured-export-v1/
capturedExportV1 identity. Before optional offline LSP startup, bounded metadata
preflight retains and verifies the exact helper file/process; no unknown old
binary is launched just to probe a flag. Optional service failure keeps editing
and ordinary execution policies available. Unmarked verification does no product
preflight and gains no marked-candidate bypass.

Root Cargo uses maintained gpui-component, gpui-base, gpui-pre-linux and new full
gpui-pre patches. Only explicit Windows product-windows-resources selects the
additive windows-manifest-provided-by-host feature; ordinary upstream defaults
remain intact. The validated native release hook links generated RC to the GUI
binary only; the resulting PE must contain exactly one English RT_MANIFEST 1,
original-derived icon group 1 and exact four-WORD version. Actual default/product
Windows Cargo feature graphs pass static inspection. Native SDK/MSVC compile,
resource link and installed identity/DPI/accessibility proof remain pending.

A fresh private paired build generates the canonical identity before both Rust
and Go compilation and rechecks source bytes. Build outputs never substitute
stale helpers or test artifacts. SOURCE-PROVENANCE.json records the exact ordered
source input files, digests and aggregate algorithm corresponding to the embedded
sourceSha256; this is builder provenance, not an independent compiler attestation.
Candidate ZIP/tar publication refuses existing outputs, includes the exact pair,
shared metadata/file checksums, imports/glibc bounds, original resources/themes,
manual update/remove instructions and full locked dependency plus installed
standard-library original notices. Missing original legal material refuses.

Completed static commands on Rust/Cargo 1.99.1 all exit 0: default/native-smoke
--locked --offline --all-targets check (1.719s/2.132s), both Clippy configurations
with -D warnings (1.952s/2.455s), and fmt --check (0.941s). Python AST, Bash and
workflow YAML inspection, original non-GPUI CI byte comparison, isolated build
hook metadata compilation, current maintained-source audits and source-character
inspection also pass. Exact logs/statuses are under ignored build/gpui/task31-static.
The only compiler notice is the pre-existing block 0.1.6 future incompatibility.
Task 30 separately reviews complete standalone dev graphs/locks with all four
maintained mappings; those lock-only updates remain part of the final source
freeze and do not change product Cargo metadata.

Prepared cases cover exact/mixed metadata arguments, strict canonical bytes,
identity mismatches and unmarked no-probe behavior, fresh zero-profile/empty SQL,
explicit real-profile binding, disconnected missing restores, inherited compiler
injection, old helper no-launch, exact resource inventory, original notices,
no-replace candidates and owned per-user integration. They have not run. No
application/helper/--build-info process, package/install, SQL/DB/store/credential,
clipboard or GUI runtime operation executed during integration. PowerShell parser
and native ABI/resource checks are not claimed on Mac. Task 2, Task 32 installed
acceptance and all 171 native cells remain not-run.


## Tasks 30 and 32 final code preparation

Task 30 final runner/assertion/dependency review is source-frozen. Its 24 Rust,
seven owned-DB and focused shared Go stages bind 47 behavior groups and all 57
features without changing the 190-assertion/171-native-cell corpus. Exact separate
base/component/pre-Linux unit graphs use all four maintained patches and bind 698
source/provenance inputs. See PARITY_RUNNER.md; these stages remain unrun.
Task 32 source preparation is likewise frozen: 57 exact-artifact/process/state/
database/fault acceptance tests and native/manual evidence contracts are ready,
with no installed pass claimed. See INSTALLED_ACCEPTANCE.md. Runtime/install/GUI
and Task 2/all 171 native cells remain open.

Additional compile-only evidence from the current frozen Rust input snapshot:
Linux x86_64 all-target check and native-smoke all-target check exit 0 in
18.014s/17.140s, respectively. All four maintained manifests and root test cfg were
compiled with 1,129 byte-stable inputs; exact owned containers were removed.
This ran under x64 emulation on an ARM Docker daemon, without tests, helper,
application, DB, stores or GUI execution. It establishes target typechecking,
not native CPU/runtime or graphical acceptance. Exact summary:
build/gpui/task30-current-linux-final-summary.json; completed record SHA256
0082de93f6961f416170a4b93c2bcc2181fe80b9a4197dac55a347eb89859ad3.


Task 31 final legal/source closure: complete all-feature metadata covers all 850
locked Rust nodes. The product node is excluded from dependency attribution;
769 dependencies preserve archive-provided originals, and 80 exact published
packages use the reviewed original-source/declaration catalog (334 references,
127 unmodified text files). Every catalog entry passes read-only collector
validation against the actual archive checksum, published manifest and Cargo VCS
bytes. Original publisher SPDX declarations and their official pinned standard
terms retain explicit reference chains; no authors, years or grants are inserted.
The unavailable Pathfinder base commit and dirty Tree-sitter publication remain
explicit source facts. All 44 external Go modules preserve original notices and
exact downloaded source/module sums. Compiler cache preparation with private
alternate module files succeeds without changing release go.mod/go.sum; it runs
compiler metadata/cache operations only, never helper or test/application code.
No notice bundle or candidate archive was created. Exact static records:
build/gpui/task31-static/final-legal-closure.json and
build/gpui/task31-legal-source/final-static-audit.json.

Scoped .gitattributes preserves audited source/fixture/resource/legal bytes on
Windows checkouts and retains LF shell entrypoints; it changes no existing file
bytes or Git/system configuration. The original SwiftUI signing/build/release
scripts and icons/version/build files remain byte-identical. The development
wrapper validates target ancestry before creating outputs, respects the selected
ignored target/helper and refuses every partial marked-product environment.
Full final source freeze is recorded in build/gpui/task31-source-freeze.json;
Task 30/32 source receipts and root global execution authorization remain separate.
