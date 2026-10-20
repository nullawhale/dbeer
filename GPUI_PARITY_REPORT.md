# GPUI parity implementation report

Date: 2026-10-20

The Windows/Linux GPUI implementation and its verification/build tooling are
prepared for CI. Focused execution found and corrected product, shared-contract,
fixture and test-runner defects. Full parity, target desktop usability and
installed upgrade acceptance have **not** been established. At the user's
request, finalization stops further broad local testing and submits the current
work in one commit on the existing `v0.2.0` branch for CI build feedback.

## Product boundary and decisions

The macOS product remains the native SwiftUI/AppKit application for macOS 14+
on Apple Silicon, with the bundled Go helper. GPUI targets Windows 11 x64 and
Ubuntu 24.04 x64, with separate Wayland and X11 acceptance. GPUI on macOS is a
development/test host only. Windows Server CI and emulated/headless Linux checks
do not establish supported desktop acceptance.

New profiles use an unspecified environment and `readOnly=false`, matching the
selected Swift behavior. Existing and imported explicit policy values are
preserved. Stable Windows/Linux product identity retains the original GPUI data
owner and credential service/accounts; it does not silently migrate secrets or
connect restored documents.

## Implemented work

| Area | Prepared behavior |
| --- | --- |
| Workspace and profiles | Typed documents, stable IDs and revisions, independent SQL-tab sessions, captured operation ownership, single-instance/data-directory exclusion, profile CRUD, TLS settings, protected persistence, credential-store adapters and portable profile transfer. |
| SQL and local documents | Dialect-aware fragments/scripts, whole-source policy review, ordered statement feedback, Stop and helper-loss reconciliation, native Open/Save/Save As, captured destinations, disconnected restoration, durable drafts and managed history. |
| Catalog and tables | Lazy catalog/search/object actions, adapter-owned SQL, dedicated table documents, server paging/filter/sort, exact typed values, selection/copy, row details and retained grid/editor state. |
| Editing and exports | Typed staged update/insert/delete, immutable Preview, fresh same-session assessment and one-shot Apply, explicit unknown-outcome recovery, loaded-result export and complete Run to File with separate SQL/publication outcomes. |
| Assistance and settings | Owned offline language-service actor, metadata lifecycle, completion/diagnostics/signatures, persistent appearance, theme import/library/recovery and configurable shortcuts with current focus/IME/AltGr authority. |
| Close and native integration | A common close decision graph across running work, files, drafts, edits, exports and settings; retained finalizers; Windows session-end and Linux GNOME adapters; accessibility semantics, focus and keyboard integration. Actual target desktop observation remains open. |
| Build and delivery preparation | Paired GUI/helper identities, native Windows/Linux builders, exact provenance and dependency notices, immutable unsigned development candidates, headless/fault/database runners, desktop probes, installed-acceptance harnesses and CI jobs. |
| Shared compatibility | Coordinated Go/Swift protocol and fixture consumers for identity, transfer, SQL execution, typed exports and Run to File; MySQL exact-numeric browsing and missing-object behavior; bounded transport and typed progress/error validation. |

Safety requirements remain explicit: credentials stay in platform credential
stores and transfer excludes secrets/private keys; restored documents stay
disconnected; database changes retain Preview/Apply; NULL, empty text, literal
`NULL`, DEFAULT, exact numerics and binary values remain distinct. Independent
sessions, bounded streaming/ACK handling, original-helper cancellation and
uncertain commit outcomes remain part of the implementation. Diagnostics must
not contain credentials, connection strings, SQL text or results.

Review corrections also cover captured file/backup publication, private creation
before content, original profile migration authority, corrupt/future-state
preservation, stale callback ownership, latest settings/draft finalization,
ordinary-product Clear Drafts, actual popup/shortcut routing and actor wake
handling. Clear Drafts retains saved SQL files and leaves a fresh empty,
unbound, disconnected document. The dependency guard authenticates a bounded
immutable archive snapshot and its exact source set, avoiding a hash/reopen race.

## Verification actually completed

Results below belong to their recorded source/artifact intervals. They must not
be combined into a passing current full suite. Later focused supersessions in
this report update older dated handoff notes in the implementation tracker.

| Completed evidence | Scope and limitation |
| --- | --- |
| Shared contracts | Go: 27 root tests plus 87 subtests passed. Supported focused Swift runner: 12 tests passed. Earlier bounded Rust backend 15, transfer 3 and identity 14 selections passed in each tested mode. These are selected contract/regression results. |
| Retained UI/operation regressions | Original 33 and routing 7 selections passed, zero ignored, representing 39 unique exact symbols. Independent review completed the original 60-path fix interval and examined all 33 cause/correction mappings. This is macOS-hosted test-platform evidence. |
| Maintained dependency supersession | The actual base Button own unit passed 1/1. The faithful public-root Div integration passed 1/1 using the actual maintained public Element writer and all three original default-false/explicit-true/explicit-false assertions. The original standalone pre library unit was NOT EXECUTED: compilation encountered four upstream test prerequisites. Its failed attempt is preserved. |
| Guard and provenance | 40 focused Python methods passed with zero skips; ten descriptor alias mutations were refused. Ten exact official command recipes authenticated both original registry origins and all 169 source files. Authentication does not mean all compatibility recipes ran. The final six-source supersession review completed without actionable findings. |
| Earlier Python lanes | An earlier focused Python lane had 93 passes and one explicit native-prerequisite skip; 33 packaging checks passed in their separate interval. These older results do not cover the entire current Python inventory. |
| Compiler/static checks | Default/native-smoke all-target checks, both Clippy configurations with warnings denied, and formatting completed five passes over 1,044 stable inputs. The later public integration separately completed four check/Clippy passes plus formatting. Earlier Linux x64 emulation supplied typechecking only. |
| Final orchestration preparation | The reviewed Linux runner passed 15 safe actual-path fake cases. The final collector/public-target gate passed 22 safe in-memory cases, independently replayed, and its final preparation review completed without findings. These checks ran no actual Linux peer, Cargo build, product helper or database. |

The final source preparation reconciled 1,570 source paths, 698 maintained
dependency inputs, three standalone graphs and the root graph. It bound 86
regression selectors, 185 Python declarations and 14 selected maintained stages.
These inventories and source reviews establish preparation and traceability,
not runtime acceptance. The prepared orchestration flags remain
`globalFreeze=false`, `sourceReady=false` and `runtimeReady=false`; a current full
matrix was not started before the user's finalization instruction.

## Incomplete and failed evidence

Tasks 1 and 3-29/31 have baseline or implementation preparation recorded; that
status does not close their native verification obligations. Task 30 is only
partially verified. Task 32 provides installed-acceptance preparation; its actual installed
acceptance remains unrun. Task 2, F57 and all 171 Windows/Wayland/X11 native
acceptance cells remain open.

The initial full root runs on older source failed: default had
355 passed / 18 failed / 1 ignored; native-smoke had
374 passed / 145 failed / 1 ignored. Focused fixes and later passes preserve
those failures as history. **No current full rerun supersedes them.** The original
strict Linux peer startup packet had four passes and one failure, whose cause
remains unexplained. Runner
source corrections and safe fake checks do not replace actual rebuilt Linux
ELF five-case plus three-case startup execution.

The following final scopes remain unrun: the three owned PostgreSQL/MySQL pairs
(16/8.0, 17/8.4 and 18/8.4), their real session observers/helper-loss/TLS/cleanup
matrix, the final full supported macOS native/shared regression, separate
resource-bearing screenshot capture and private measurements, actual private
GNOME-bus protocol execution, and the disposable macOS Keychain opt-in. The
Windows owned-HWND opt-in requires an actual Windows desktop. Original Swift
DB/opt-in skips remain uncovered. Actual Windows/Ubuntu desktop, credential,
clipboard, IME, accessibility and previous/candidate installed upgrade checks
remain unverified.

External Codex CLI review was NOT RUN after automatic approval rejected source
upload/local-state access. No retry or workaround was attempted; independent
local review records supplied the scoped reviews described above.

## CI and packaging status

[Main CI](.github/workflows/ci.yml) runs on push, pull request and manual dispatch,
without a branch filter. Pushing `v0.2.0` therefore requests:

- Linux Go race tests, PostgreSQL 16/17/18 with TLS and MySQL 8.0/8.4 with TLS.
- The existing macOS 15 arm64 SwiftUI/AppKit app build, native tests and isolated
  Keychain checks through the supported CI signing wrapper.
- Ubuntu 24.04 x64 and Windows Server 2022 x64 GPUI verification and paired
  unsigned development-candidate packaging, with build/proof JSON and candidate
  artifacts retained for 14 days.

[Supplemental final parity CI](.github/workflows/gpui-parity.yml) is manual-only
and requires `all_task32_code_ready=true`; it prepares separate native-headless
and owned-database matrix jobs. This finalization does not dispatch that workflow.
Neither workflow publishes a release. The macOS job does not upload a release
archive, and local macOS release packaging explicitly refuses CI: owner releases
continue to use the persistent Apple signing identity on the owner's Mac.
Versions, existing release archives, signing identity and system trust were not
changed for finalization. CI has not yet produced a result for the new commit.

## Repository entry points

The tracked [implementation tracker](prototypes/gpui/IMPLEMENTATION.md),
[parity registry](prototypes/gpui/parity/README.md),
[parity runner contract](prototypes/gpui/PARITY_RUNNER.md),
[build integration](prototypes/gpui/BUILD_INTEGRATION.md) and
[installed acceptance contract](prototypes/gpui/INSTALLED_ACCEPTANCE.md) retain
feature/task details and repeatable commands. Dated entries describe their own
checkpoints; use this report for the finalization status above. Builds and
releases depend on tracked source and fixtures, not ignored local plans,
private evidence, caches or build artifacts. Those local files are excluded from
the commit.
