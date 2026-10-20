# Installed acceptance integration

Task 32 remains OPEN. The engine integration below is source code, not native
acceptance. No unit test, helper/application, database, native service, credential
store, GUI, clipboard, archive install/package or external stand ran during this
integration. All 171 frozen Windows 11 x64 / Ubuntu 24.04 x64 Wayland / X11 cells
remain not-run. The macOS product remains SwiftUI/AppKit; GPUI Mac is development
only. Actual trusted prior/candidate artifacts and all three native stands are
absent. No prior artifact was fabricated or relabeled.

## Entry points and source validation

The supported wrappers remain `scripts/test-gpui-install-update.sh` and `.ps1`.
`prepare --request <absolute private request>` creates additive private not-run
records and `required-plan.json`; it never stages or launches an artifact.
`run --request ... --owned-disposable-desktop` requires actual trusted archives,
independently observed native contracts and a reviewed complete schema-2 plan.
A focused `--scenario Fxx` retains other cells not-run, but the reviewed plan must
still account explicitly for all 57 scenarios and all 190 assertions.

Read-only source validation is safe before runtime authorization:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 prototypes/gpui/acceptance/recipes/validate.py
bash -n scripts/test-gpui-install-update.sh
```

The validator imports only pure recipe/schema modules; it AST-parses and compiles
all acceptance Python sources and the authorized owned-database source in memory.
It parses strict JSON, checks exact frozen mappings, pinned source bytes, fixed
expectations, recognized operations, and full explicit pending coverage. It runs
no test or native/application adapter. PowerShell/GI runtime validation still
requires its real target.

## Concrete plan and assertion authority

`acceptance/plan.py` exposes `required_plan(catalog)`, `validate_action`,
`validate_scenario` and `validate_plan`. Executable plans are schemaVersion 2,
with exact top-level fields `schemaVersion`, `selectorIntegrationReviewed`,
`desktop`, `preparation`, `normalClose`, `scenarios`. Unknown operations/fields,
zero actions, missing assertions/requirements, unsupported or missing engine
families, clicks credited as assertions and incomplete scenarios refuse before
launch. Every assertion action declares its exact frozen `assertion` and
`requirement`. Both engines are explicit for DB scenarios. `SUPPORTS` narrows
which concrete operations can contribute to each requirement; it does not turn
partial checks into a complete reviewed procedure.

`recipes/required-plan.pending.json` lists every required assertion/requirement/
engine tuple as an executable `capability-required` refusal. It is explicitly
unreviewed and not an execution plan. Replace gates only after implementing and
reviewing the exact independent outcome in `coverage.json`; changing flags cannot
produce native observations. `manual-required` and `capability-required` always
raise Pending and never credit an assertion. The source contract deliberately
has no manual-pass switch. Full procedure review remains mandatory: a matching
operation category does not prove that its expected value covers the whole
frozen assertion.

Preparation checks run against the real previous artifact and do not pre-credit
candidate assertions. Candidate scenarios start with empty assertion/proof sets.
Final cleanup/lifecycle failure invalidates all earlier passed-scenario records.
F57 always remains pending until the missing native/fault/manual adapters and
complete matrix join exist.

## Consumed fixed inputs and independent oracles

`Workflow.input` accepts existing `synthetic.*`, exact-owned `connection.*`,
`corpus.*` and explicitly staged `fixture.source.<key>` references. Corpus keys
are fixed Unicode/CRLF input, NULL marker, enumerated per-engine query strings
and typed text assignments. Native payloads remain bounded and pipe-only.
`stage-input` chooses only a key in `recipes/source-inputs.json`. Each source has
a fixed repository-relative path, size, SHA256 and enumerated staging filename;
it is copied exclusively into the private input directory and its original
file/directory identities and bytes are rechecked before chooser use. A request
cannot supply SQL or an arbitrary source path. Original staged files are retained.

`assert-observer-oracle` compares full independent columns AND typed rows through
`recipes/oracle.py`. `snapshot` covers declared values/composite/effects/Apply/
receipts shapes; `effect-once` requires the exact fixed effect case count one;
`script-receipts` requires exact ordered receipts including original seed rows.
Missing rows, zero/duplicate execution or changed metadata refuse. Explicit
`assert-observer-rows` now requires nonempty expected columns and rows; it never
copies actual columns into expected data. Equality uses canonical JSON so boolean
ordinals cannot equal integer ordinals accidentally.

`export-check` accepts only `oracle: loaded-json|loaded-csv|complete-json|
complete-csv`, engine, enumerated original output path and assertion. Expected
size/hash/typed rows/metadata/counts come from independent source serialization,
not request hashes or app output. Complete export also checks physical server
count. PostgreSQL has 1,205 rows; MySQL has 1,005. MySQL full exports use the fixed
`ORDER BY CASE WHEN id<=5 THEN id ELSE exact_value+6 END`; unordered tail IDs are
never invented. NULL/empty/text NULL, exact numeric scale, duplicate columns,
Base64 binary, embedded CRLF and collision-free CSV NULL markers remain distinct.
The MySQL effect routine's terminal OK set has no accepted exact-byte oracle;
read-only export expectations cannot substitute for that separate routine.

Every independent observer verifies actual server version against its owned
configured family and retains only its version hash, family and exact image ID
in DB evidence. It uses a separate matching packaged helper/physical session;
no application transaction is borrowed. Scalar count polling rejects missing,
NULL, nondecimal or malformed counts. Fixed effects queries require completed
owned setup before use.

## UUID, state and credentials

`capture-profile-set` captures the isolated pre-Save membership.
`capture-profile-id` requires that capture, exact engine and fixed synthetic
name input. Discovery requires exactly one new matching canonical nonzero UUID,
retains existing opaque migrated IDs, rejects duplicate/lost original IDs and
never treats vector offsets as identity. Policy/credential references accept
only `capture.<key>`, current library membership, original UI creation receipts
and the current capture epoch. Capture keys cannot be rebound.

`assert-profile-policy` requires all four independently expected policy/TLS
fields; CA references resolve only to the exact owned public CA fixture.
`assert-state-expected` compares populated independent counts, captured profile
order/selection, exact ordered fixed document source hashes, original profile
bindings and explicit history preference. `assert-settings-expected` now compares
full independent appearance, shortcut and
normalized imported-library DTOs. Committed imported UUID discovery and actual
common-Close/restart checks are described below. Rendered palettes and exact
native latest-save/reload behavior still requires observed original controls;
an internal held-save/reservation trace is not an extra frozen assertion.
`capture-state`/equality require populated profiles/documents/history/settings;
empty defaults cannot satisfy upgrade assertions. Source-only DTOs reject live
session/result/credential fields. These checks cannot prove native caret/Undo,
full history semantics or original typed grid ownership.

`credential-arm-ui-write` requires the original true absence reservation.
`credential-arm-ui-update`/`credential-arm-ui-delete` require a confirmed owned
current hash and no unresolved intent; the current OS entry is verified before
journaling prior/attempted hashes. `credential-verify` consumes explicit
`outcome: written|deleted|kept|rolled-back`, rechecks the exact terminal hash and
updates ownership only after a match. Empty and absent remain separate. A foreign
collision or replacement is preserved. No password control value is read.

Cleanup is permitted only after every retained GUI child completed actual common
Close successfully, with no forced termination; every entry's exact expected
hash is rechecked in the bounded native worker immediately before removal.
Unresolved intents refuse cleanup. Recovery now requires the complete journal
chain and successful common Close records for every exact retained GUI creation.
It never trusts a PID-only/manual shutdown claim or reattaches to a process.
An interrupted update can conditionally remove only a prior confirmed or attempted
owned hash; unknown hashes remain untouched. Native stores have no atomic
compare-and-delete guarantee against concurrent adversarial writers.

## Lifetime and file receipts

`normal-close` runs the reviewed real common Close sequence and waits for the
retained exact child to exit with status zero. `restart` requires that outcome,
launches only the exact pinned artifact in the same isolated canonical root,
creates a fresh Driver/window binding, independently compares populated persisted
state and checks both servers for zero product connections. Only preserved
UI-created IDs renew into the new epoch; old native target bindings never do.
Zero connection counts do not prove zero transient read-only SQL. Assertions
requiring no DB work need an independent query-delta witness. Fixed ordered
receipt arrays already establish skipped fixed writes without internal traces.

`file-capture` retains the exact handle, parent/device/inode and hash for an
enumerated isolated persisted file. `file-assert-same` refuses changed bytes or
foreign replacements, including same-byte new inodes. `file-backup-check` compares
a distinct enumerated backup with the original retained bytes. Fixed legacy and
exact new recovery-backup discovery are supported.
Separate Windows deny-sharing barriers and fixed fresh corrupt/future subfixtures
are implemented below. No operation writes arbitrary requested paths, adopts a
foreign replacement or treats a read receipt as a publication-fault barrier.

## Fixed effects setup and remaining native joins

The authorized shared-source extension is
`verification/owned_databases.py: OwnedDatabases.setup_acceptance_effects(record)`.
The only argument is that owner's original exact receipt object returned by
`create` after frozen corpus `setup`. The method checks captured CID/engine/
version/image/name/nonce/loopback endpoint, both actual Docker labels/running
state, original private directory and password-file identities/hashes, and fixed
bounded source digests. PostgreSQL setup is transactional; MySQL DDL failure may
be partial. Journal state is `installing` then `installed` or `failed-unknown`.
Every repeat refuses, including failed/ambiguous attempts. A fresh owned corpus
lifetime is required instead of DROP/reset/adoption. No SQL/path/image argument
or additional privileges are accepted. Existing synthetic MySQL grants cover the
reserved namespace. `DatabasePair.setup_effects(engine)` and `effects-setup`
consume the API; setup stdout/stderr is discarded.

`proof_join.py` validates actual completed Task30 version/TLS DB summaries:
nonempty executed tests, successful status/exit, stable source, correct native
OS/x64 outside containers, every required DB stage and exact fixture cleanup.
Optional request `completedProofs` contains only pinned `{kind,path,sha256}`
descriptors. Missing versions, skipped/zero cases or failed cleanup refuse.
Native Rust/fault and supported Mac completed-summary adapters are now present.
The final cross-stand installed/manual/physical aggregate adapter remains pending;
individual real SQL/Apply ACK-loss machinery cannot itself close that aggregate.
One installed pair, fake helper tests and a headless build cannot close F57.

Remaining exact work includes all observed previous/candidate UIA/AT-SPI role,
name, hierarchy, action and stable native-ID contracts; source ElementId is no
native ID. Current native foreground/original-window checks remain before every
mutation. Fresh destructive subfixtures, Windows locking, native text/semantic readers,
physical session deltas, full Settings DTOs and owned SQL/Apply ACK-loss relays are
implemented as described below. Original installed helper OS receipts, complete
query-delta witnesses for zero read-only work, MySQL transaction/temp-state witnesses, precise
connect/preview/export faults and safe
locked-store/failure rollback adapters remain implementation gaps. Actual
package/runtime/remove observations,
keyboard/IME/clipboard/choosers/Narrator/Orca/focus/DPI/OS appearance observations,
all version/TLS/fault summaries and actual macOS SwiftUI/AppKit regressions.
No global input/clipboard/logout or broad process/file cleanup exists.

## Final guarded procedures

`persistence-case` first completes the main workspace's actual common Close,
then seeds one of ten fixed corrupt/future connections/workspace/appearance/
themes/shortcuts cases in a fresh private nonce root. No main UUID or credential
is copied. Nested actions can access only Settings/recovery and the fixed theme
chooser; DB/credential operations and other native selectors refuse. The broken
file is held before launch. The subfixture must complete common Close, after
which the original main workspace restarts and compares its populated state.
Failures retain the private fixture and invalidate acceptance.

`file-backup-discover` accepts exactly one new source-named backup in the retained
original parent. Its distinct native identity and exact original bytes are
checked; pre-existing same-byte files cannot qualify. `file-block-replacement`,
`file-check-barrier` and `file-release-barrier` use a separate original Windows
handle denying write/delete sharing. Ordinary receipts explicitly allow delete
sharing so they do not accidentally block legitimate recovery. This lock is not
an ambiguous-publication simulation. Foreign replacements remain untouched.

`native-text-select`/`native-text-assert` require fixed independent input, UTF-16
start/end, observed nonsecret native ID and original binding pin. UIA locates
provider-defined Character endpoints by measured UTF-16 prefixes; AT-SPI maps
Unicode character offsets to UTF-16. Split surrogates, changed source, unsupported
endpoints and replaced bindings refuse. `native-semantic-assert` compares fixed
name/description hashes, enabled/focused/readonly/selected and realized grid
row/column/span/count fields. Windows selectors explicitly choose the observed
`descriptionProperty: helpText|fullDescription`; empty aliases are not evidence.
AT-SPI positions require VISIBLE/SHOWING. These reads do not prove keyboard/Undo,
IME, text-run geometry, scrolling or complete native typed-edit workflows.

`capture-theme-set`/`capture-imported-theme` discover one new canonical imported
UUID and compare every original import plus the independent fixed `shared-32`
normalized RGBA/scopes/styles, including explicit empty font style. The fixed
appearance/shortcut/library expectations cover import, newer unrelated editor
choice, removal/defaults and explicit unbind. `settings-close-restart` checks
complete selected DTOs after actual common Close and fresh restart.
`capture-recovered-theme` works only inside its actual fresh corrupt/future
library case and requires the exact backup before discovery. Actual latest-save/
reload controls and rendered palettes need native observations. Complete-file
equality does not establish rendering; internal reservation instrumentation is
not an additional frozen assertion.

`capture-physical-sessions`/`assert-physical-sessions` retain the exact server/image
and compare bounded independently chosen add/remove deltas. PostgreSQL includes
backend creation and exact idle/open/failed transaction state. MySQL PROCESSLIST
has no creation time or transaction owner; neither is inferred from Sleep/TIME.
Repeated/concurrent old/new launches now require both independent servers empty
before/after and the exact same canonical owner environment. These observations
cannot prove the absence of a transient read-only execution. A safe independent
query-delta witness remains necessary only for assertions requiring no DB work;
missing internal instrumentation is not itself a behavior parity gap.

### Real SQL and Apply COMMIT acknowledgement loss

`relay-start` creates a leased IPv4 loopback listener with one accepted connection
by default. `relay.<capture>.host|port` supplies only its original endpoint; host
is localhost so real end-to-end TLS/hostname verification remains intact. The
upstream comes only from the original OwnedDatabases receipt. CID, image, nonce,
running labels, loopback mapping and fixed transactional effects digest are
rechecked. The original producer creates a private CA and signs serverAuth/SAN
DNS:localhost certificates for both engines; PostgreSQL starts with ssl=on and
MySQL uses the exact owned CA/server certificate/key. The consumer requires the
producer's exact ca.crt/server.crt/server.ext/untrusted.crt file identities/hashes,
fixed extensions and bounded read-only openssl hostname verification before
exposing the CA. A real native verify-full connection is still mandatory. There
is no requested target, SQL/TLS parser, payload log or production failure flag. All buffers/time are bounded; full buffers apply backpressure.

`relay-lost-commit-ack` requires zero current-case effect with only original verified prior fixed cases,
one original physical session,
original idle/open-transaction native guards and an editor containing exactly
`COMMIT;`. The same lock guarding every reverse send acknowledges a complete
reverse hold before exactly one native Run. A separate direct helper/fresh
idle autocommit query must observe fixed sql-commit effect1 before only the held
sockets are dropped. Then the original native Unknown/retry-disabled state,
physical session loss and unchanged effect1 must be observed. Nothing retries
while unknown. This does not prove helper process death.

Apply preserves the original live catalog connection. `relay-pin-catalog` binds
that first lease only after explicit native Connect, one physical product
session, genuine UI-created profile capture and exact localhost/relay-port/
verify-full/owned-CA metadata. `relay-prepare-apply` checks the original catalog
and invokes the actual fresh Purpose::Apply preparation through its native
control, explicitly admitting exactly one second connection. A fresh native
review/dialog binding and exactly one new physical session must follow. A third
connection, old review pin, profile/epoch change or lost catalog invalidates it.
No settings/disconnect/stale-target bypass is used.

`relay-lost-apply-ack` rechecks that original review, enabled Confirm Apply and
exact fixed baseline rows/effects. Previously verified distinct fixed cases retain
count1 internally; the current case starts at zero and can never replay. It gates only the second lease, holding each
reverse chunk under the send lock. After a fresh independent effect0 snapshot,
only that exact earlier chunk may be released once. Once effect1 and exact fixed
row1 label `applied`/generated length7 are visible with row2 unchanged, the current
chunk and all later bytes stay held and only that lease is dropped. Original
Unknown/retry-disabled, unchanged effect1/rows and the surviving original catalog
physical session are mandatory. Maximum 512 chunks/60 seconds/64 KiB buffers are
bounds, not success conditions.

The proof relies on actual transactional trigger/effect tables, a fresh direct
autocommit MVCC observer, and sequential helper statement replies before COMMIT.
Those exact PostgreSQL/MySQL source bytes are explicitly reviewed and pinned.
The trusted exact archive must contain matching SOURCE-PROVENANCE per-file pins
and complete paired source aggregate, recomputed through the packager's pure
source inventory. Missing/changed provenance keeps Apply pending; it is trusted
builder provenance rather than a cryptographic compiler attestation. Any chunk
already containing a COMMIT reply necessarily follows visible committed effect1;
it cannot be released based on a fresh effect0 observation. TLS coalescing does
not change this ordering. Actual two-lease native role/admission evidence remains
required; source code cannot set nativeObserved/review flags.

Separate prepared Rust tests
`postgres_real_helper_death_awaits_original_exit_and_physical_session_loss` and
`mysql_real_helper_death_awaits_original_exit_and_physical_session_loss` retain the
runner's exact real Go helper file identity/hash and original BackendClient Child.
After independent physical sleep they retire/reap that child, require actual exit,
Unknown/dead-session refusal, original server-session loss and preserved observer.
A 0755 non-secret binary is allowed only inside its 0700 private owner parent and
cannot be group/other writable; Windows keeps its protected owner ACL. These
native headless tests are distinct from installed GUI helper ownership and do not
supply COMMIT/rollback evidence. They remain unexecuted.

### Completed joins and remaining gates

`task30-native-rust` validates both actual native Rust modes with all thirteen
exact portable faults once per mode, source stability, unique actual test rows,
matching nonzero terminal counts, no truncation and native OS/x64 outside a
container. DB joins require all seven declared Rust DB/TLS stages, their exact
critical tests including both original-helper death tests, the supported
same-owned-pair Go race stage with all ten exact non-skipped assertions, actual
completed package rows, every required DB version and owned cleanup. Passed flags
without those terminal rows refuse.
Mac joins require actual supported `./scripts/test.sh --all`, completed shared Go
rows and nonzero Swift Testing. Zero/partial/duplicate/skipped runs refuse.
The final installed/manual cross-stand aggregate remains absent and always
pending, even if these narrower producers pass.

Additional implementation remains for exact installed helper OS receipts,
independent zero-query witnesses where required, full MySQL physical
transaction/temp state, precise connect/preview/export fault phases and
the final trusted manual/native aggregate.
A real credential entry has no safe per-entry lock adapter here; locking the
user's collection/global store is prohibited. Such faults require an explicitly
isolated real native store/session stand. Explicit startup writes also need a
pre-owned credential account before the app-generated UUID's first secret write;
that reservation boundary is not supplied by a guessed UUID or fake store.
Exact frozen behavior governs acceptance. Native result identities plus fixed
ordered receipts establish script order/skips; internal request/statement/LSP
instrumentation is not an additional parity requirement.
The concrete outstanding boundaries include F09-S01-A01/A03 and
F10-S01-A01/A03 (original per-tab MySQL transaction/temp/service witnesses),
F40-S01-A01/A02/A03 (exact owned LSP lifecycle/environment/fault observations),
F51-S01-A02 (isolated native store failure), F53-S01-A01/A02/A03/A04
(installed original-helper receipt and phase-specific fault observations), and
F52-S01-A03/F57-S01-A01/A02/A03 (trusted final native/manual completed joins).
F18 skipped fixed writes and F47/F48 preference/import persistence do not acquire
extra internal instrumentation requirements. All other native assertions still
need their exact observed controls/actions and independent expected outcomes.

Native observations are separately required for both exact artifact selector
contracts, original two-lease Preview/Apply admission, native locks/recovery/store
errors, keyboard/IME/AltGr/clipboard/choosers/Narrator/Orca/focus/DPI/OS appearance,
clean install/remove/update and all 171 cells. Trusted prior/candidate artifacts,
Windows 11 x64 and Ubuntu 24.04 x64 Wayland/X11 stands remain absent. No runtime
suite, helper, GUI, DB, credential/clipboard action, package or install ran here.

## Deferred tests

Prepared tests in `test_core.py`, `test_integration.py`, `test_extended.py` and `recipes/test_recipes.py`
cover meaningful metadata/type/count/NULL/binary/export mutations, UUID discovery/
stale epochs, missing-engine/requirement/zero-action coverage, conditional
credential write/rollback/keep/empty/delete/foreign replacement, recovery chains,
retained-child Close/restart, script receipts, copied DB receipt/replay refusal,
same-byte foreign file replacement and missing completed proof. They have not run.
After all Task32 code is integrated and the parent enables runtime checks:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s prototypes/gpui/acceptance -p 'test_*.py'
```

Native installed runs still require genuine trusted artifacts and owned native
stands. Static checks and prepared tests close no Task32 checkbox or native cell.

Native API references: [UIA TextPattern selection](https://learn.microsoft.com/en-us/dotnet/api/system.windows.automation.textpattern.getselection), [AT-SPI Text selection](https://docs.gtk.org/atspi2/method.Text.set_selection.html), [AT-SPI realized cell spans](https://docs.gtk.org/atspi2/method.TableCell.get_row_column_span.html).

## Final review completed-source and Mac-skip join

`Artifact.require_verification_source()` first performs the existing full exact
candidate/current-source validation, then requires every file in the actual
Task30 producer's `task30-reviewed-source-v1` inventory to appear with the same
SHA256 and size in SOURCE-PROVENANCE. All platform branches and shared Mac
regression inputs use one deterministic raw-byte map on every host. This is an
explicit per-file join between two distinct reviewed aggregate algorithms.

The completed adapters now require an explicit `expected_source` argument:
`task30_summary(value, desktop, expected_source)`,
`task30_rust_summary(value, desktop, expected_source)` and
`macos_summary(value, expected_source)`. `MatrixJoin(descriptors, desktop,
expected_source)` receives it from the running candidate artifact, checks the
current reviewed map again and passes that same value into each adapter.
Summaries must retain matching before/after complete `sourceInventory` records
as well as matching sourceSha256 fields. Stale but internally stable results,
mixed Rust/DB-version/Mac revisions, missing inventories and old digest-only
proofs refuse. Existing terminal-row, skip, cleanup and real native-host checks
remain mandatory. A descriptor hash pins evidence bytes, not tested source.

Mac's supported full SwiftUI/AppKit runner is a narrower shared non-database
layer. Only the 62 literal reviewed absent-fixture Go DB/TLS roots in
`verification/macos_coverage.py` may be skipped, with the exact roots retained in
proof.coverage.uncoveredDatabaseRoots and stage.conditionalSkips. Unknown/new
shared roots or any Swift skip refuse. The returned scope explicitly requires
separate completed native DB/TLS layers and establishes no Windows/Linux native
coverage. Both producer and consumer enforce this same policy.

Synthetic actual-format collector/adapter parser fixtures and stale-source tests
are prepared, not execution evidence. F57 still ends Pending for its missing
manual/native/physical joins. Task 2, Task 32 and all 171 native cells remain
not-run; no source-contract fix grants native or installed acceptance.
