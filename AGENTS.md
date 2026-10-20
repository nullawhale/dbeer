# DBeer

DBeer is a native SQL client for macOS 14+ on Apple Silicon, built with
SwiftUI/AppKit and a bundled Go helper. PostgreSQL and MySQL are supported.
Current development targets only the native macOS SwiftUI/AppKit client and
its shared Go helper. Windows/Linux GPUI feature development, paired builds,
protocol compatibility updates and UI acceptance are deferred unless explicitly
requested. The GPUI instructions below are retained for future reference;
they are not required verification for current macOS work. GPUI on Mac is
for development only.

## Repository map

- `macos/Sources/DBeer/`: application state, native UI, persistence and helper client.
- `macos/Tests/DBeerTests/`: Swift Testing suites, including native AppKit tests.
- `macos/AcceptanceTests/`: XCTest UI acceptance for installed application archives.
- `helper/`: Go helper, database adapters and framed protocol transport.
- `prototypes/gpui/`: experimental Rust/GPUI Windows/Linux frontend and checks.
- `protocol/fixtures/`: shared Swift/Go protocol and export fixtures.
- `assets/`: database logo sources; SwiftPM resources link to these files.
- `macos/Resources/`: app icons and accent colors, including checked-in `Assets.car`.
- `scripts/`: supported build, test, screenshot and release entry points.
- `docs/`: ignored local research, plans and verification reports. Keep the
  tracked project self-contained; builds and releases must not depend on it.

## Working conventions

- Keep changes focused and follow the surrounding Swift and Go conventions.
  Use Swift 6 concurrency and respect main-actor isolation for AppKit/SwiftUI.
- Keep database-specific SQL and capabilities in the Go adapters. When changing
  the protocol, update both implementations and the shared fixtures together.
- Preserve independent SQL-tab sessions, transaction state, cancellation,
  streaming backpressure and explicit handling of uncertain commit outcomes.
- Preserve the distinction between SQL NULL, empty strings, text `NULL`, DEFAULT,
  exact numeric strings and binary values in editing, transport and exports.
- Store passwords in the platform credential store: macOS Keychain, Windows
  Credential Manager, or Linux Secret Service. Profile transfer must exclude
  secrets and private keys. Never log credentials, connection strings, SQL text
  or query results.
- Keep restored documents disconnected until the user explicitly connects or
  executes a query. Database edits require the existing preview/apply workflow.
- Match native focus, keyboard navigation, hover behavior and light/dark themes
  when changing controls. Reuse the existing shared control components.
- Keep build products, caches, local databases and test artifacts in ignored
  `build/`. Do not commit signing material or local connection settings.
- Keep user-facing project documentation in English, following `README.md` and
  `INSTALL.md`. Update `CHANGELOG.md` when release behavior changes.
- Do not add Cyrillic characters, including in test fixtures or commit messages.

## Build and verification

- Build the signed app: `./scripts/build-app.sh`.
  Use `CONFIGURATION=debug` for a debug build. Output: `build/DBeer.app`.
- GPUI Windows/Linux paired builds use `./scripts/build-gpui-client.ps1 -Test -Package`
  and `./scripts/build-gpui-client.sh --test --package` on native x64 builders.
  Without options they compile only. Tests use separate unmarked artifacts;
  `build/gpui/candidates/` contains immutable unsigned development candidates.
  Keep the existing macOS CI job on SwiftUI. `./scripts/build-gpui-app.sh` builds
  only the separate Mac development prototype.
- GPUI focused checks: `./scripts/gpui-prototype.sh test --locked`,
  `./scripts/gpui-prototype.sh clippy --locked --all-targets -- -D warnings`,
  and `./scripts/gpui-prototype.sh fmt -- --check`. Use Rust 1.92+ (CI pins
  1.99.1); do not claim Windows/Linux UI coverage from a headless build.
- Default to focused checks for the changed behavior. Run selected native suites
  with `./scripts/test.sh --filter SuiteName` (repeat `--filter` as needed).
  This skips Go tests; theme/UI matrices run only if the filter selects them.
  Do not run the full suite after every small edit. Use it for broad changes,
  final verification of cross-cutting work, or an explicit request.
- Run all Go race and native Swift tests: `./scripts/test.sh --all`. This builds the app
  and isolates test credentials in a temporary Keychain. Use this runner for
  AppKit tests; a plain `swift test` can exit before the suite completes.
- Run helper-only tests: `./scripts/test-go.sh` (also supported on Linux).
- Run isolated database integration: `./scripts/test-postgres.sh`,
  `./scripts/test-mysql.sh` and `./scripts/test-tls.sh` (Docker required).
- Run both databases with the native suite:
  `./scripts/test-postgres.sh ./scripts/test-mysql.sh ./scripts/test.sh --all --require-postgres`.
- Installed-archive acceptance: `./scripts/test-install-update.sh`; this needs
  full Xcode, Docker and the expected release archives. Read
  `macos/AcceptanceTests/README.md` before running it.
- Use the Go version in `helper/go.mod` and Swift 6 with Swift Testing.
  Normal builds need Command Line Tools; full Xcode is only required for
  XCTest UI acceptance and regenerating the accent color catalog.
- After changing icons run `./scripts/build-icon.sh`. After changing accent
  colors run `./scripts/compile-accent-colors.sh` and commit both the source
  catalog and regenerated `Assets.car`.
- Run checks appropriate to the change and report skipped database/UI coverage
  accurately. Do not claim a passing suite without its completed-run summary.

## Release conventions

- `VERSION` and `BUILD_NUMBER` are the shared sources of release metadata.
  Do not renumber existing release archives or overwrite them.
- App and helper builds use the owner's persistent Apple Development identity.
  Do not replace it with ad hoc signing or change system trust settings.
  Temporary signing identities are restricted to disposable hosted CI.
- `./scripts/package-release.sh` creates a local ZIP and SHA256 with
  `CHANGELOG.md` and `INSTALL.md`; it does not publish a release.
