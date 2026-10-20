# Native paired product builds

The Windows/Linux build wrappers prepare DBeer for native x64 targets. Python
3.11+, the pinned native Rust toolchain including rust-docs, and the official Go
toolchain with its original LICENSE/PATENTS are build prerequisites. CI installs
rust-docs explicitly and checks those original toolchain notice files before
building; a minimal toolchain missing legal material refuses packaging. The
macOS product remains SwiftUI/AppKit with its existing Apple Development identity,
build and release route; build-gpui-app.sh remains a separate Mac development tool.
This integration source does not establish Windows/Wayland/X11 acceptance.

```sh
# Native Ubuntu 24.04 x64, after the complete source tree is frozen.
./scripts/build-gpui-client.sh                 # compile only; no executable launch
./scripts/build-gpui-client.sh --test --package
```

```powershell
# Native Windows x64 Developer PowerShell, Python 3.11+, SDK/MSVC tools on PATH.
./scripts/build-gpui-client.ps1                # compile only; no executable launch
./scripts/build-gpui-client.ps1 -Test -Package
```

The default operation generates one canonical BuildIdentity before either build
and embeds its exact compact sorted ASCII bytes without the file's final LF in
both binaries. Go receives main.productBuildIdentity/main.productVersion/
main.productBuildNumber link values. Rust receives DBEER_PRODUCT_BUILD_IDENTITY.
Version/build come exclusively from the root files. Both tools must report the
actual supported native host; explicit native --target prevents Cargo config
from selecting another target. Cross-target/compiler/linker overrides refuse.
The source digest is rechecked between the two builds and before completion.

Each invocation owns a fresh private build/gpui/product-builds/product-<nonce>/.
Its binaries are target/<native-triple>/release/dbeer-gpui[.exe] and the sibling
dbeer-core[.exe]. BUILD-RESULT.json records identity, compiler versions and exact
binary SHA256. Source, metadata, lock, attributes, embedded fixtures, assets,
wrappers and maintained vendor bytes
are inputs; ignored docs, Git metadata, caches and output trees are excluded.
No stale binary can be substituted from the ordinary development target.
All compiler temporary files and caches stay under build/. Untracked Cargo cache
configuration refuses; relevant checked-in project configuration is source-bound.
Ignored nested build/target/cache/private Git trees never enter the source digest,
while every literal Rust embedded fixture/resource input is covered.

Windows inputs come from the existing native-resources generator. The explicit
host-manifest feature suppresses only gpui-pre's dependency manifest after
checking required identity/resource inputs. The application's native release
build hook validates those exact inputs, compiles RC and links the GUI .res with
cargo:rustc-link-arg-bin. Native PE inspection enumerates the sole manifest and
compares its exact bytes, version and resource-ID-1 icon. Optional helper RC
embedding remains outside this required GUI resource path.

--test/-Test invokes the existing Task 30 runner with --final-integration
--all-headless --self-checks. That runner clears product/compiler injection and
uses its own fresh unmarked helper/peer plus build/gpui/verification-target.
Product marker requirements are never weakened for tests. This explicit test
option prepares future execution; no tests ran while implementing these files.

The CI dependency step runs packaging/prepare-go-cache.py explicitly. It downloads
all public Go module sources with a private alternate go.mod/go.sum, so extra
checksums cannot alter the release inputs. It records exact source/module sums
for every module; the offline verification runner itself never fetches.

--package/-Package collects complete all-feature locked Cargo and Go notice texts, performs
static import/glibc/native resource inspection and bounded early --build-info on
the exact pair, then invokes the hardened no-replace candidate publisher. The
archive includes the identity, full source input digests, pinned original publisher/workspace/standard legal
source provenance, per-file manifest,
native imports, original icons/themes/licenses and update/removal instructions.
Existing candidates and release archives are immutable; use a new source/version
decision rather than replacing files. No signing, trust change or publication is
performed. Native GUI/store/install/update evidence is still required.

The two existing GPUI job blocks in .github/workflows/ci.yml provision tools and
locked caches, run the unmarked proof, build the marked pair and upload the new
unsigned candidate directories. Windows Server CI is headless compile/runtime
proof and never Windows 11 installed acceptance. All non-GPUI job bytes,
including the SwiftUI/macOS job, are preserved by this integration.

gpui-prototype.sh remains for ordinary unmarked development. It respects
CARGO_TARGET_DIR below build/, defaults test outputs to verification-target,
and never overwrites an explicitly selected prebuilt helper. Output ancestry
is checked before creating a directory; partial product identity/resource
environments refuse before the development helper can be rebuilt. Its ordinary default
run/build outputs retain the Mac development bundle's original paths. Marked
product environments must use the native paired wrappers.

The root Cargo patch, explicit product-windows-resources feature, build hook and
product startup are integrated. Ordinary Windows/Linux startup requires the
native release identity, starts with an empty SQL tab and no built-in profiles,
and restores saved or missing profile bindings disconnected. Only explicit Mac
--demo and native-smoke modes enable disposable fixtures. Product helper lookup
uses the binary sibling; its optional offline language service checks the exact
bounded paired metadata before spawning ContentLength transport. A failed
optional service leaves editing and ordinary execution policies available.

Default/native-smoke all-target check, both Clippy configurations with warnings
denied and formatting pass on the Mac development host. Python AST/Bash/YAML
inspection, resource-input review and isolated build-script typechecking are
static evidence only. Packaging, build-info probes and runtime suites remain
deferred until every Task 32 code change and the Task 30 audit are integrated.
PowerShell/native MSVC syntax/link checks require the supported Windows builder
and are not claimed on the Mac host.

The final review moves the last publication-authorizing freeze check inside the
shared packager. It stages retained verified source/legal bytes, validates the
staged legal index and rechecks original source/notice snapshots before the
atomic no-replace rename. A late source change in either direct or paired use
cannot publish a candidate before the build fails; failed preparation releases
only its original claim and unchanged exact stage inventory. Published candidates
and foreign replacements are preserved.

All Task30 producer inputs now also occur in candidate SOURCE-PROVENANCE. The
installed consumer validates current complete candidate provenance and joins each
named verification file's SHA256/size before accepting any completed adapter.
Task30's sourceInventory/sourceInventoryAfter and their algorithm-specific
sourceSha256 fields must all match this reviewed contract. Packaging and Task30
aggregate algorithms remain different; no unrelated hashes are equated. Refresh
pins after the final writer freeze and retain all earlier receipts as historical.
Prepared parser/publication regressions remain unrun; native compilation,
packaging, installed/native/manual acceptance and all 171 cells remain open.
