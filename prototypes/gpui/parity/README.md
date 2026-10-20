# Frozen GPUI parity baseline v1

This directory is the durable Task 1 specification for Windows 11 x64 and
Ubuntu 24.04 x64, including Wayland and X11. The macOS product remains
SwiftUI/AppKit. Mac GPUI builds are development checks only.

`baseline.json` pins the source, signed app, test evidence and provenance.
`source-manifest.json` pins every relevant source byte and symlink target.
`registry.json` contains all **F01–F57** rows, an owner role, implementation
references, exact test IDs and independent Windows/Wayland/X11 results.
`scenarios.json` gives each row concrete actions, expected observations,
synthetic fixtures and executable existing Swift reference checks. Exact test
methods and commands are stored once in `reference-tests.json`; fixture groups
are stored once in `fixture-sets.json`. Existing
suite coverage is explicitly narrower than the complete operator procedure.
`references.json` retains R1–R15 without depending on ignored research docs.

All native result cells initially say `not-run`; all implementation rows stay
open. A passing inventory validator or reference suite never accepts a native
feature. Frozen schema v1 rejects native pass/equivalence statuses entirely;
native acceptance requires a future versioned structured evidence contract.
Task 2 adds the exact-executable/PID native driver; later tasks bind
the concrete operator procedures to its actions. Screen-reader, real secure
store, file/clipboard/IME and installed-upgrade checks require actual target
desktops. Existing Swift suites are behavioral oracles, not portable AppKit
implementations to translate mechanically.

Run these commands from the repository root with Python 3.9+:

```sh
python3 prototypes/gpui/parity/check.py validate
python3 prototypes/gpui/parity/check.py verify-source
python3 prototypes/gpui/parity/check.py verify-artifacts
python3 prototypes/gpui/parity/test_check.py
python3 prototypes/gpui/parity/check.py show F44
python3 prototypes/gpui/parity/check.py reference --feature F16 --feature F38 --print-only
python3 prototypes/gpui/parity/check.py reference --feature F16 --feature F38
```

`reference` batches the selected existing Swift suites through the supported
native runner and requires its completed nonempty run summary. It retains
scope, skips, command and output under `build/gpui-parity/reference-runs/`.
Some mapped suites have database prerequisites or guarded cases; report those
skips explicitly. This command does not execute the entire operator procedure
and never writes a pass into the registry. `verify-source` deliberately fails
after implementation changes a frozen source file; use the replay to run the
original oracle. `validate` checks the portable specification independently.

The new golden cases and measurements have focused executable checks:

```sh
DBEER_PARITY_MEASUREMENTS="$PWD/build/gpui-parity/reference-measurements.json" \
  ./scripts/test.sh --filter ParityBaselineTests --filter SQLScriptParserTests \
  --filter ResultExportTests --filter SQLLanguageServiceTests --filter SQLLSPCodecTests
(cd helper && GOCACHE="$PWD/../build/.cache/go" \
  GOMODCACHE="$PWD/../build/.cache/go-mod" \
  go test -race ./internal/sqllsp ./internal/sqlcomplete)
```

The Swift runner builds/signs the app using the owner's persistent identity
and isolates credentials in a disposable test Keychain. Preserve any current
`build/DBeer.app` before using it if that artifact matters. Measurement is
opt-in; otherwise its test is explicitly skipped. The shared signature cases
in `protocol/fixtures/signature-help.json` run through both the Go LSP adapter
and the Swift bundled-LSP client, including Unicode UTF-16 label spans.
No DB connection or personal library is needed for these new fixture checks.

Validate setup syntax/data on one locally available image per engine with:

```sh
python3 prototypes/gpui/parity/verify-db-fixtures.py
```

The verifier requires local `postgres:17` and `mysql:8.4` images (override with
`--postgres-image`/`--mysql-image`). It never downloads images, exposes ports or
uses an existing database. It creates/removes only its two owned containers,
uses random temporary credentials, suppresses SQL/results, and retains a
completed summary under ignored build/. This validates fixture setup and
row-count/exact-numeric assertions; it does not establish full integration,
TLS or coverage of the other supported server versions.

`fixtures/postgresql.sql` and `fixtures/mysql.sql` are executable setup scripts
for an **owned disposable server** using `psql -v ON_ERROR_STOP=1 -f ...` or
`mysql --default-character-set=utf8mb4 < ...`. Supply connection settings via
the existing isolated DB runners, never command-line credentials. PostgreSQL
supports 16/17/18; MySQL supports 8.0/8.4. Setup creates the reserved
`dbeer_parity_v1` namespace and fails if it exists. It never drops or replaces
an existing namespace. Dispose of the owned server/container after the run.
The scripts cover display overflow, exact numeric/binary/NULL/default data,
composite/no PK, generated columns, views, routines, FK and trigger metadata;
MySQL additionally has a nontransactional table and multiple result sets.
Actual DB/TLS integration is not established by fixture parsing or inventory
validation. `failure-cases.json` defines the required faults and links the
existing isolated TLS runner; test keys/certificates stay in ignored build/.

Decision **D01** applies only to future **new** GPUI profiles: environment
`unspecified`, `readOnly=false`, TLS `verify-full`, matching frozen SwiftUI.
The prototype still creates `development`/`readOnly=true` today. Tasks 5–7
implement the new-profile decision while preserving every existing/imported
explicit policy and version-specific legacy migration rule. This baseline
task changes no user's profile or permissions.

`responsiveness.json` records measured reference values, exact input/sample
methodology and provisional budgets derived from those measurements. The
reference uses the debug production module in a real native AppKit test host;
the separately frozen signed app is release configuration. CPU and synchronous
grid layout/redraw measurements include assertions and omit compositor fences,
OS input delivery and network time. They are not end-to-end input latency.
Frame pacing, cold launch, actual editor input and target-platform calibration
remain explicitly unmeasured; their proposed thresholds must be validated in
Tasks 2/29/30 rather than reported as observed reference results.

The local source replay and signed app copies live under
`build/gpui-parity/baseline-v1/` with hashes retained here. Replay into a new
empty owned directory with `tar -xzf /absolute/path/to/source-replay-with-fixtures.tar.gz`;
never overlay a working checkout. The archive includes all source files listed
by the source manifest, including relevant untracked prototype/test/script
files and resource symlinks plus their assets, and the deterministic
`parity/fixtures` inputs required by the tests. It excludes `.git`, ignored
`docs/`, build products, credentials, databases and registry metadata (avoiding
recursive self-hashing). The tracked working diff is retained separately;
untracked source is in the replay, not in that diff. Build the replay with
`./scripts/build-app.sh` using Swift 6, the Go version in helper/go.mod and
the owner's signing identity. Compare source/resource hashes and behavior;
signed executable bytes need not be reproducible across toolchains/signatures.

Keep baseline v1 and its local evidence immutable. New reference features need
an explicit versioned change record mapping added/changed capabilities,
source/app hashes and scenarios. Current implementation status may advance
only with revision, exact artifact, engine/desktop/session, fixture/test IDs,
per-scenario output, completed-run summary and documented skips. Local historical
release ZIPs and a preexisting signed app have separate recorded provenance;
matching a version number alone proves neither publication nor source identity.
