# GPUI theme library core and Settings handoff

Task 27 is implementation code-ready on 2026-10-20. Production Settings now
consumes this original parser/assets/store through the retained chooser, normalized
review, explicit import/recovery/removal and common-close participants. See
[production integration and verification](THEME_LIBRARY_SETTINGS.md). Runtime
verification remains deferred after Task 32; Windows/Ubuntu native acceptance,
Task 2 and all 171 native cells remain open. The macOS product stays SwiftUI/AppKit;
Mac GPUI remains development only.

## Source assets and normalized values

`src/theme_library.rs` and its subtree consume the exact
`appearance::{Theme,Scheme,Color,TokenRule,TokenStyle}` types. There is no second
normalized style or SQL persistence DTO. Rule order, sRGB RGBA values and
`font_style: None` versus `Some("")` survive parsing and persistence. Scope
resolution uses the existing `Theme::style`, including dotted parents, parent
chains, comma alternatives, exclusions, specificity and later-source precedence.

`builtin_themes() -> Result<Vec<Theme>, Error>` returns these eight schemes in
order: native-light, native-dark, vscode-light-plus, vscode-dark-plus,
solarized-light, solarized-dark, jetbrains-light and jetbrains-darcula. Ten
embedded source files are necessary because VS Code Plus includes two base
files. JetBrains Light uses the display name from the Swift library override.
Default/Darcula parents are embedded local sources, never loaded from a user's
IDE or arbitrary plugin path.

All ten sources plus four original notices/licenses were copied byte-for-byte
from the actual local Swift EditorThemes resource directory. Their exact mapping
and provenance are recorded in `assets/themes/PROVENANCE.md`, alongside the
unchanged original NOTICE/LICENSE files. These copied notices must accompany
redistributed GPUI artifacts (Task 31). Core compilation/runtime never needs a
Mac build, generated Swift resource bundle, ignored docs or remote asset fetch.
Original Swift sources/resources and frozen parity files were not rewritten.

## Parser and preview APIs

- `preview_import(&Path) -> Result<ImportPreview, Error>` reads a selected local
  source and supported local includes, generates a fresh imported UUID and returns
  normalized values. `ImportPreview::theme()` is read-only. It contains no source
  path or original source bytes. Parsing is suitable for an owned background
  worker; capture the originating Settings request before dispatch.
- `parse_bytes(&[u8], name, id) -> Result<Theme, Error>` parses standalone data;
  its ID must be canonical `imported-<UUID>`. It refuses includes because bytes
  alone provide no filesystem authority.
- JSON/JSONC preserve string contents while stripping comments and accepting
  trailing commas. Explicit workbench/editor colors override legacy TextMate
  global settings. Unscoped rules preserve fonts and global caret/selection/
  gutter colors. Scope lists are split and trimmed like the actual Swift parser.
- XML and binary TextMate plists share the same document normalization. Ordinary
  Apple's public plist DTD is removed before parsing; internal entities, foreign
  DTDs and entity declarations are refused. Exact-pinned plist 1.10.1's streaming
  Reader/Event API bounds depth, events and expanded string bytes before building
  a value tree, including repeated binary plist object references. The feature
  exposing this API is unstable upstream, so the dependency is exact-pinned.
- JetBrains exported `.icls` uses roxmltree 0.21.1 with DTD parsing disabled and no
  external resolver. It maps editor colors, generic/SQL syntax and diagnostics,
  RGB values with dropped leading zeros, RGBA, baseAttributes, Default/Darcula
  parent overlays, bold/italic/underline and explicit TextAttributes font reset.
  Unknown parents fail with a fixed error. Plugins are never loaded or executed.

Limits: 1 MiB per file, 4 MiB aggregate, 16 reads including repeated includes,
include depth below 8, and at most 10,000 normalized colors/rules. JSON parsing
retains serde's nesting bound. XML/plist parsing additionally bounds nesting to
32, plist events to 100,000, expanded string bytes to 4 MiB, XML elements to
100,000 and JetBrains elements below 20,000. Include paths refuse empty/absolute,
parent traversal, remote/drive/URI prefixes, tilde and backslashes, and reject
symlink/reparse components and canonical paths outside the selected root.
Cycles are rejected before re-reading the active file. Nonregular and oversized
sources are refused. Unix source opens use O_NOFOLLOW; Windows uses reparse-point
opens. These checks match the Swift safety intent and deliberately refuse unsafe
references rather than attempting to interpret a plugin package.

## Owned normalized library persistence

Retain exactly one `LibraryStore::new(profile_store.data_owner())` per Workspace
and clone it for workers. It retains the existing `Arc<DataDirectory>` and uses
that owner's mutation mutex; it never acquires a competing storage owner.

- `load() -> Result<Vec<Theme>, Error>` returns built-ins plus normalized imports
  from GPUI-owned `themes.json`. It never reopens the original imported sources.
- `load_or_builtins() -> Result<LoadedLibrary, Error>` returns readable built-ins
  with a fixed error and `recovery_available` after a refused saved library. This
  fallback never makes an unreadable library writable.
- Reserve synchronously before dispatch: `reserve_import(ImportPreview)`,
  `reserve_remove(id)` or explicitly authorized
  `reserve_recovery_import(ImportPreview)` return a `MutationRequest`.
- `MutationRequest::commit()` returns `Imported(Theme)`, `Removed(String)`,
  `Unchanged` or `Superseded`. Clones share reservation order. Commit mutates the
  store's latest successfully loaded normalized library under the same owner;
  it never writes a captured full Workspace/profile/SQL snapshot. A later
  reservation supersedes an older queued worker. Explicit reload invalidates
  all queued pre-recovery requests.
- `Removed` is the only result authorizing
  `Preferences::remove_theme_selection(id)`. Reset matching selectors and reserve
  the separate appearance save only after successful library removal. A failed
  removal retains both the current library and selection.

The v1 file contains only `version` and normalized imported `themes`, capped at
16 MiB and 64 entries. Strict decoding rejects unknown/duplicate fields (including
nested map keys), unsupported versions, duplicate IDs, built-in/reserved selector
IDs, malformed imported UUIDs, invalid style bounds and nonfinite/out-of-range
colors. New normalized bytes pass the same validation before publication.

Reads refuse nonregular/symlink/reparse files. Publication uses create-new private
same-directory files, file sync, original-byte comparisons, latest-reservation
checks and atomic rename without delete-destination fallback. Unix files are
0600 and the existing owned directory is 0700. Windows retains inherited private
per-user directory permissions and refuses deny-sharing/locked replacements.
Temporary cleanup retains the original handle and only removes its matching file
identity, leaving an unrelated replacement untouched. Every worker/prepared file
retains the same data-directory owner until publication and cleanup complete.

Corrupt/future bytes remain untouched by ordinary imports. An explicit recovery
import first writes and syncs a unique private exact-byte
`themes-recovery-<UUID>.json`, syncs the directory, and only then replaces the
library. Existing recovery files are never overwritten. Failed/superseded recovery
may leave that useful exact recovery copy while retaining the original library.
Files that cannot be read safely, including oversized libraries, remain untouched
and cannot use this recovery API; explicit external repair and reload is needed.

External byte changes refuse publication. `PublishedUnverified` means replacement
already occurred but directory durability could not be verified; it invalidates
loaded write state and requires explicit reload. It never claims an unchanged
source or automatically retries an ambiguous publication. All errors are fixed
messages without filesystem paths, source contents, SQL, results or credentials.
Advisory ownership and byte/identity checks do not provide adversarial filesystem
compare-and-swap; native filesystem/ACL/sharing/power-loss behavior still needs
actual Windows/Linux acceptance.

## Required integration

The declared production module uses the exact pinned roxmltree/plist dependencies.
The broad temporary dead-code allowance is removed; only the standalone byte
parser API retains a narrow allowance because production supplies a local path.

Task 26/27 Settings integration must load the library before resolving persisted
selectors, retain the fixed error/recovery state, and use this same library for
both application/editor menus. Start the real native Open picker from Settings,
allow JSON/JSONC/TextMate/binary-plist/ICLS sources, preserve cancel and originating
request ownership, show a normalized preview, and commit only a still-current
import request. Source parsing never changes persistence or selection by itself.
After `Imported`, append/reload normalized values and make the intended explicit
selector choice through the appearance APIs. A preview may render temporary
values without reserving an uncommitted imported selection.

Expose remove only for imported IDs. Publish selection resets after `Removed`,
then persist them through AppearanceStore. A stored missing selector still uses
appearance fallback if a preference save fails; it must not reopen source files.
Show normal retry/reload and separately explicit recovery import controls. Wait
for the latest reserved theme mutation and appearance save before allowing a
successful normal close, preserving existing SQL/file/transaction/Cancel guards.
Do not serialize imported assets or settings into SQL restoration/history DTOs.

Task 26 now loads this original library owner before resolving saved selectors
and displays fixed load failures without rewriting IDs. Application/editor
lifecycle and appearance close publication are integrated. Task 27 now integrates the actual chooser,
import/removal section, ordered terminal reconciliation and latest library/appearance
close finalization. The production contract is in THEME_LIBRARY_SETTINGS.md.

## Verification prepared and remaining

Additive `protocol/fixtures/gpui-theme-parity` contains JSONC, XML and binary
TextMate, JetBrains and local include sources. `cases.json` specifies every
normalized color and ordered rule plus resolved scope styles. The new Rust
consumer and `GPUIThemeParityFixturesTests.swift` independently parse actual
sources and compare to these shared expectations. A parent fixture uses the
same embedded Default/Darcula sources. No frozen baseline/hash/manifest/reference/
replay or existing fixture was replaced.

Prepared Rust cases also cover all eight assets, alpha/font reset, global/explicit
color precedence, include count/depth/aggregate/10,000-rule limits, traversal/
remote/symlink/cycles, DTD/entities/namespaces/attribute cycles, normalized source
removal/restart, current/future/corrupt/duplicate/reserved/invalid libraries,
64-entry limits, exact recovery backups, latest/concurrent/reload reservations,
retained owner, external conflicts, failed replacement, temporary identity cleanup,
private modes and Windows sharing refusal. They are prepared code, not passed
runtime tests or native evidence.

Completed local static checks: rustfmt parsed/formatted only the owned Rust module;
Swift frontend syntax parse of the additive consumer; all 14 copied asset/notice/
license bytes compared to actual local Swift resources; Cyrillic scan and owned
file whitespace inspection. Shared all-target compilation/Clippy results are
recorded separately by the integration writer after source freeze. No Rust/Swift/
Go/DB/UI/credential/clipboard runtime test or probe was executed.

At final integration after remaining implementation, run with completed summaries:

```sh
./scripts/gpui-prototype.sh test --locked -- theme_library:: --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- theme_library:: --test-threads=1
./scripts/test.sh --filter GPUIThemeParityFixturesTests --filter EditorThemeTests --filter JetBrainsEditorThemeTests
```

Then verify actual Settings import/remove/preview/restart, source deletion,
corrupt/future explicit recovery, independent selectors, failed/locked writes,
normal close flushing, native pickers/cancel/focus/IME/Undo/accessibility and
Windows/Ubuntu filesystem permissions on Windows 11 and Ubuntu 24.04 Wayland/X11.
Mac static compilation and prepared cases cannot establish that acceptance.
