# Prepared final verification runner

This is source-ready runner integration for Task 30. Execute only after all
remaining production code through Task 32 is integrated. No runtime test,
helper/DB/GUI/credential/clipboard probe or CI dispatch ran for this change.
Task 2, Task 30 Run boxes and all 171 frozen native cells remain not-run.

## Exact build and environment contract

`scripts/test-gpui-parity.sh` / `.ps1` invoke `verification/run.py` unchanged.
Execution requires `--final-integration` and an explicit scope. Native Rust/DB
scopes require actual Windows/Linux x64 and 64-bit Python; Linux is Ubuntu
24.04. Containers and Windows ARM emulation are refused for this proof layer.
Hosted Windows Server is recorded as headless and never Windows 11 acceptance.
Mac `--swift` uses the existing signed SwiftUI/AppKit `scripts/test.sh --all`;
Mac GPUI is still only a development frontend.

The runner clears inherited `DBEER_*`, production PostgreSQL/MySQL/DSN/password
settings, dynamic-loader/Python injection and compiler/link injection settings.
It rejects inherited cross-target GOOS/GOARCH/CARGO_BUILD_TARGET. Test data,
config/cache/temp/fixtures and helper output are isolated under a fresh private
`build/gpui/task30-runs/<nonce>/`. Actual session authorization is retained;
production profiles are never copied. Windows directories are created with an
explicit current-token owner and protected inheritable one-user DACL. Their
owner/DACL and all evidence files are checked; POSIX paths require current UID,
0700 directories and 0600 files. Exact inode/native identity and hashes are
rechecked before use and completion. No recursive fixture cleanup is used.

Tests are explicitly **unmarked development artifacts**. The environment omits
`DBEER_PRODUCT_BUILD_IDENTITY`; Go builds have no product `-X` link values.
Go's helper is `<run>/bin/dbeer-core[.exe]`. Rust test outputs use only
`build/gpui/verification-target`, separate from Task 31 marked product outputs.
The peer uses `build/gpui/task30-fault-target`. Cargo caches are
`build/gpui/cargo`; Go caches are `build/.cache/go` / `go-mod`. The runner pins
already-installed Rust 1.99.1, disables toolchain auto-install, uses offline
Cargo, Go module proxy/checksum off and local Go toolchain selection. Missing
toolchains/dependencies/images remain prerequisites; the runner never downloads,
provisions, changes trust or signs. Manual CI explicitly provisions packages,
toolchain/dependency caches and declared local DB images before this offline gate.

Task 31 must compile BOTH candidate GUI/helper with the same canonical identity
in its separate output tree. There is no production runtime bypass, weakened
handshake or fabricated matching identity for these test peers. Tests exercising
the real marked gate construct exact identities through the existing test seams.

## Completed evidence and critical test map

At final integration, `--all-headless --self-checks` runs root default and
native-smoke tests, actual separate base/component dependency lib-test targets,
Linux's private fake GNOME bus and the prepared Python safety/conformance cases.
It does not infer dependency unit coverage from root `--all-targets`.
`--stage <matrix-id>` is an exact focused selector; unknown/empty filters fail.

`fault-plan.json` lists the exact eleven `preview::tests::fault_helper::*` and
two `run_to_file::tests::*` names. Each must pass exactly once in default and
native-smoke, with expected/observed count 13. Additional required assertions
cover current mapped transport/persistence/close/export/Unicode behavior,
Windows deny-sharing, real DB observers/TLS, base editor Atomic/Undo/selection,
component editor/accessibility and private GNOME protocol cases. All assertions
refer to actual source symbols; their existence is not runtime evidence.

Each Cargo build needs exactly one successful terminal and exact native
executable metadata/hash. Each Rust run needs a nonempty completed summary
whose pass/fail/ignored counts match actual unique assertion rows. Missing or
ignored critical assertions fail. Go retains only structural JSON package/root
test events and requires completed passes for every source package with tests;
arbitrary Output/subtest labels are suppressed. Swift's supported full runner
must additionally produce its nonempty Swift Testing completion. Python safety
suites require counted assertion rows, a nonzero `Ran` summary and final `OK`.
Zero-test, truncated/incomplete, failed, timeout and missing-artifact runs cannot
pass. No raw child/compiler diagnostics, SQL, results, credentials or DSNs are
stored. Proof records are new atomic publications and never overwrite history.

`verification/dependency-inputs.json` binds 698 actual maintained vendor,
provenance, manifest, lock and parent README inputs to the final Task 29/31
source. Every standalone command explicitly applies all four local patches:
`gpui-pre`, `gpui-base`, `gpui-component` and `gpui-pre-linux`. Cargo artifact
records must identify the actual expected local manifests and omit both
`product-windows-resources` and `windows-manifest-provided-by-host`. Declared
UPSTREAM/LOCAL-CHANGES digests are verified against actual bytes before building.

The reviewed current root graph has 850 packages. Base has 807 (39 additions,
82 omissions, no new versions of root-known names); component has 709 (71
additions, 212 omissions, the same fifteen previously documented standalone dev
versions); relocated pre-linux has 628 (no additions, 222 omissions, no version
drift). No graph changes a root-known source/checksum. Every added/omitted pair
and exact full lock hash is retained in the review. The component differences
remain a distinct dev graph and are never described as root-lock execution.

Base/component current standalone locks were seeded from the frozen root lock,
resolved offline with all four patches, and handed to the production owner for
exact provenance updates. Pre-linux changes only `lib.path` in a new reviewed
verification manifest; all 29 actual source hashes and both manifests/locks are
bound by `pre-linux-unit/inputs.json`. Offline workspace update and locked
no-deps test-support metadata completed for these three graphs and the separate
platform harness. These are metadata results, not compiled or executed tests.
Complete public locked dependencies must be explicitly provisioned before offline
unit builds; the manual workflow does so before invoking this runner.

A gpui-pre standalone dev-only attempt required uncached `stacksafe`. Its failed
preparation remains in ignored build output. The product owner's explicit scope
keeps the original upstream gpui-pre lock unchanged and verifies its actual
maintained build behavior through root dependency artifacts plus native Windows
host-resource checks. Unrelated upstream UI tests are not added merely because
the source is now vendored. All changed base editor/selection, component
editor/input/dialog/accessibility/compatibility and pre-linux keyboard/format
unit targets are separate required stages. Existing narrow focused stage IDs
remain available; `--all-headless` selects the complete meaningful set.

Historical Linux emulated compile reports and failed attempts remain immutable
and accurately scoped in `LINUX_UNIT_PROOF.md`. `prepare_platform.py` now stages
all four current maintained source trees and the public parent README, which the
actual base lib-test includes. Its current platform-harness lock uses all four
patches. A container/emulated result cannot enter this runner's native-host layer.

## Database ownership and final integration obligations

`--database-pair 16 8.0`, `17 8.4` and `18 8.4` select only allowed local images.
`OwnedDatabases.run_pair` retains its API and copies the controlled peer/hash/root
settings into each DB stage. Setup/cleanup failures fail the run; failed
ownership/source/cleanup proof invalidates prior passed stage claims. Cleanup
uses retained exact child handles and exact nonce/CID/image/private-file records;
no process-name/PID-only kill, foreign container, prune or foreign-file removal
exists. A lost COMMIT peer response only proves unknown client state: actual
server effects still need the separate physical observer fault case.

Task 32 alone calls `setup_acceptance_effects(record)`. It takes the original
exact record returned by the same owner's `create`, after `setup`; it accepts no
SQL/path argument. It installs fixed source-hashed SQL through owned password-file
stdin, validates original CID/image/nonces/port/private identity, and returns
`{engine, sourceSha256, fixedCorpusInstalled:true}`. Installing/installed or
failed-unknown state is journaled; failures refuse replay. The runner does not
call this acceptance-only effects installer or supply its password/DSN producer
to installed GUI acceptance.

The final source join preserves all 25 original behavior groups and adds 22,
with explicit mandatory assertion-to-stage bindings for all 57 frozen features.
The original 57 features, 190 native assertions, 171 cells and baseline/manifests
are checked against exact immutable byte hashes. Per-run behavior evidence must
find each actual unique passed assertion in its declared completed stage; missing,
ignored or nonapplicable assertions cannot become covered behavior. Native/F57
acceptance remains false in every automated ledger.

Task 28 registry/store/recorder/retained Settings/latest-close and Task 29 native
wrapper/source-independent selection/dialog ABA/GNOME publisher/private-bus
assertions are mandatory by actual source symbol. The ignored owned-HWND stage
is separate from `--all-headless` and requires an actual interactive Windows 11
x64 station; Windows Server cannot supply it. Exact native author IDs, text
ranges and screen-reader observation remain Task 32 native requirements.

The database pair executes seven exact Rust stages: live helper, fresh Apply,
full export, Workspace cancellation/transaction routing, TLS, isolated catalog
service and connected offline signature metadata. The live stage requires both
`postgres_real_helper_death_awaits_original_exit_and_physical_session_loss` and
`mysql_real_helper_death_awaits_original_exit_and_physical_session_loss`. They
retain the original private helper/native identity/hash, observe the actual
physical operation, await that retained child's exit and original session loss,
and require the independent observer to remain alive without reconnect.

Before the same pair's cleanup, `shared-go-owned-db-race` runs the supported
`bash ./scripts/test-go.sh --require-postgres` with controlled `GOFLAGS=-json`.
All ten exact adapter COMMIT-ACK, type, readonly, cancellation and deadlock test
rows must pass once without skipping, in completed package summaries. The
thirteen fake-peer orchestration assertions, original-real-helper death,
Go adapter injected ACK loss and Task 32 installed opaque SQL/Apply ACK-loss
relay are separate proof boundaries. None substitutes for another. F57 also needs
the reviewed pinned Task 32 target-native installed evidence join. Real GUI, native
ACL/file locks/secure stores, keyboard/IME/clipboard/accessibility/pickers/DPI,
Wayland/X11 and clean install/update evidence remain separate requirements.

Prepared safety cases cover missing/mismatched summaries, ignored assertions,
zero filters, duplicate JSON, output redaction/bounds, Go package/Swift partial
completion, missing peer hash, unmarked environment separation, retained-child
cleanup and foreign CID/file replacement preservation. They remain unexecuted.

Current final static evidence is recorded separately under
`build/gpui/task30-final-static-results.json`; it includes AST/JSON/source-stage/
provenance/input verification and supported shell/workflow syntax checks.
Fresh dependency preparation records are under
`build/gpui/task30-final-dependency-review-*/`. Earlier
`task30-runner-static-results.json` and `task30-current-pre-linux-lock-*` remain
historical preparation records. PowerShell is unavailable
on this host; parser/native checks remain unrun. No unit, app, peer, database,
Go/Swift/Rust/Python runtime suite or desktop probe was executed.

## Final review source and coverage contract

The current producer uses `verification/source_contract.py` for one reviewed
cross-platform raw-byte inventory, `task30-reviewed-source-v1`. Every platform
inventories all native branches, helper, protocol, Swift regression source,
resources, fixtures, verification/acceptance/package code, locks and supported
scripts. Paths use repository-relative POSIX spelling and deterministic ordering.
Generated/cache/private trees and symlink wrappers are excluded; original assets
are included. There is no host-dependent omission or line-ending normalization;
checkouts must retain the exact reviewed input bytes. `sourceInventory` and
`sourceInventoryAfter` retain the complete named SHA256/size map and algorithm;
`sourceSha256` and `sourceSha256After` are that manifest's ordered
`sha256(pathUtf8,NUL,fileSha256Bytes)` digest. Old digest-only completed summaries
cannot satisfy the current installed proof join.

The candidate source inventory includes every producer input. Installed
acceptance first validates the complete candidate provenance against current
reviewed source, then joins each verification input's path/hash/size. Packaging's
length-prefixed raw-byte digest and Task30's file-hash digest are distinct and are
never compared with each other. Every Rust, DB-version and Mac completed adapter
requires the same candidate-bound expected inventory before its existing
completed-row, cleanup, skip and native-host checks. All source/input pins must
be refreshed only after the coordinated final writer freeze; historical receipts
remain unchanged and cannot establish execution of changed code.

Mac `--swift` is the narrower SwiftUI/AppKit plus shared non-database regression
layer. It still runs the supported `./scripts/test.sh --all`, in the cleaned
owned environment. `macos_coverage.py` contains a literal reviewed list of 62 Go
root tests reaching absent database/TLS-fixture guards. Only those exact roots
may appear in `proof.ignored`; `proof.coverage.uncoveredDatabaseRoots` and the
stage's `conditionalSkips` retain them explicitly. Unknown/new Go roots and every
Swift skip fail this scope and the installed consumer, even if passed flags are
supplied. The receipt explicitly requires the separate completed DB/TLS layers
and establishes no Windows/Linux native coverage. No skip is silently dropped.

The required full-export DB observer test uses `fault_test_support::FileFixture`
under `DBEER_GPUI_TEST_ROOT`, never a global export directory. It retains original
parent/root handles through asynchronous work, reserves only absent named outputs,
and retains exact output identities/hashes after successful export and oracle
validation. Its cleanup validates the original directories, complete captured
file inventory and bytes; it removes only those files followed by the empty
original directory. Unknown entries, same-byte foreign file replacements and
regular-directory replacements are preserved. Windows held handles deny delete
sharing during work. Any refusal fails the required test, so the collector cannot
publish a completed passing DB stage for failed filesystem cleanup.

Prepared review regressions use synthetic parser/package inputs and the real
serializer/collector/cleanup paths. They cover changed packaged source/legal/index
inputs, paired-driver refusal before candidate visibility, consistent archive
provenance/manifests, stale stable summaries after production/helper/fixture edits,
Mac reviewed/unknown/Swift skips, native-host retention and export cleanup
ownership. They are unrun until final runtime authorization. F57's missing
manual/native/physical joins remain Pending; all 171 native cells remain not-run.
