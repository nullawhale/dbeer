# GPUI product identity and packaging core

Task 31 product/build/packaging implementation is code-ready; native acceptance
remains open. BUILD_INTEGRATION.md records the activated startup, exact paired
helper gate, native build hook, wrappers and GPUI-only CI integration. No marked
Windows/Linux GUI artifact was built, started, packaged or installed during
implementation. No runtime Rust/Go/Swift/Python/database/UI/credential/clipboard
test or probe ran. Task 2 and all 171 native acceptance cells remain open. The
macOS product remains SwiftUI/AppKit with its original identity, Apple Development
signing and release scripts. Mac GPUI is development only.

## Chosen identity and distribution

| Item | Frozen choice |
| --- | --- |
| Display name | DBeer |
| Application / Linux desktop / icon ID | app.dbeer.DBeer |
| Desktop filename | app.dbeer.DBeer.desktop |
| Windows GUI/helper | dbeer-gpui.exe / dbeer-core.exe, same directory |
| Ubuntu GUI/helper | dbeer-gpui / dbeer-core, same directory |
| Icon | unchanged macos/Resources/AppIcon.svg and AppIcon.png |
| Metadata sources | root VERSION and BUILD_NUMBER, never Cargo package version |
| Windows distribution | portable unsigned x64 ZIP |
| Ubuntu distribution | native Ubuntu 24.04 x64 tar.gz; optional standard-user desktop integration |
| Update model | verified complete-folder manual update; no updater, MSI/MSIX or AppImage |
| Artifact status | unsigned-development-candidate until target-native installed acceptance |

Keeping the existing executable names also preserves the helper's sibling lookup.
The new display/app identity is independent of the private storage/credential
namespace. Original icon bytes are copied into the package without redesign or a
Mac build dependency. The activated native build hook embeds the Windows GUI
resource and product startup supplies its title/app ID. Native taskbar/Explorer
icon and live UI identity acceptance still require the exact installed binary.
No existing release archive is renamed, renumbered, overwritten, signed or
published. Only the GPUI Windows/Linux build and CI paths consume this contract.

## Compatible identity migration and data ownership

The safest migration is deliberately **no filesystem/credential migration**.
`product_identity::compatible_library_path` matches the actual ProfileStore:

- Windows: absolute LOCALAPPDATA/DBeerGPUI/connections.json; never roaming data.
- Linux: absolute XDG_CONFIG_HOME/dbeer-gpui/connections.json, falling back to
  HOME/.config/dbeer-gpui/connections.json when XDG_CONFIG_HOME is absent/relative.
- Mac development: HOME/Library/Application Support/DBeerGPUI/connections.json,
  separate from the SwiftUI library. This Mac path is not a new product identity.

The secure-store service stays `dev.dbeer.gpui-prototype`, with unchanged saved
profile account IDs. No password read/copy/write, namespace migration or private
key/profile transfer is needed. Missing, stored empty and nonempty passwords keep
the original adapter behavior. Selecting a new display name does not imply moving
OS credentials. Prototype opaque IDs such as `demo-brewery` remain saved IDs;
only explicitly constructed in-memory Profile.demo fixtures identify built-in
fixtures. Opaque stored IDs are resolved by actual saved-profile membership; a
string prefix never turns a saved profile into a fixture. No prefix-based renumbering or conversion exists.

The old supported prototype and product acquire the **same canonical directory
and .workspace.lock through DataDirectory::acquire before any load or mutation**.
ProfileStore, workspace drafts/history, appearance, imported themes and shortcuts
keep the same Arc<DataDirectory>, mutation mutex and owner lifetime. All file
formats, backups, UUIDs, selection and credential accounts stay where they are.
No copy transaction, stale source overwrite, second owner, foreign process kill,
PID/age heuristic or stale lock deletion is introduced. Kernel release handles
normal/crash exit. Simultaneous use of an older prototype predating this lock
cannot be made safe retroactively and is unsupported; close it before updating.

`StartupPolicy::new` permits built-in fixtures only for **explicit disposable Mac
development demo/smoke**. Windows/Linux product startup has no built-in profile,
sample SQL or fallback fixture. Restore is always disconnected; metadata/state
load never starts a helper, connects, executes SQL or touches credentials.
The actual Workspace constructor applies this policy: real profiles remain an
empty vector until loaded or explicitly saved, its first SQL tab is empty and
unbound, and missing saved bindings remain disconnected. Presentation-only
Select connection/Not connected contexts supply no config, session or sample
catalog. Explicit user binding selects an actual saved profile.

## Exact GUI/helper build contract

`src/product_identity.rs` is consumed by actual startup, helper handshake and
offline optional-language-service preflight. It uses existing serde dependencies;
no product test bypass or blanket module dead-code allowance is present.

BuildIdentity is strict/duplicate-rejecting/bounded to 4 KiB:

```json
{"schemaVersion":1,"productId":"app.dbeer.DBeer","version":"0.2.0","buildNumber":"1","target":"linux-x86_64-gnu","protocolVersion":3,"contractRevision":"gpui-v3-captured-export-v1","sourceSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","capabilities":["capturedExportV1"]}
```

This is a synthetic schema fixture, not release metadata. Real version/build
come only from VERSION/BUILD_NUMBER. Targets are windows-x86_64-msvc and
linux-x86_64-gnu. NativeTarget::from_native normalizes Rust x86_64 / Go amd64 and
refuses ARM, musl, Windows GNU and Mac product targets. The source digest covers
ordered exact bytes and relative path lengths for product/helper/protocol source,
vendored patches, assets, Cargo/Go locks, packaging and relevant native scripts.
Ignored docs, .git, local build outputs and caches are not build inputs.

`BuildIdentity::embedded()` reads compile-time DBEER_PRODUCT_BUILD_IDENTITY,
validates schema/semantics, compares include_str VERSION/BUILD_NUMBER and actual
native OS/x64. `BuildInfo::gui_json()` emits exactly
`{"component":"gui","identity":{...}}` and refuses debug/native-smoke builds.
The integrated Go helper counterpart emits component `helper`. Canonical sorted compact
identity JSON generated by package.py must be embedded **unchanged** in both
binaries; the packager checks for those exact bytes before invoking either file.
An old binary is never launched merely to probe an unknown --build-info flag.
The bounded native --build-info process uses null stdin, captured JSON stdout,
discarded stderr and no DBEER_/PG*/MYSQL* environment. No SQL/result/credential
payload is logged. This mode is not a GUI, DB or credential probe.

The following hooks are integrated in Go/Swift/Rust and the native build path:

1. Dispatch an exact --build-info invocation in GUI main before GPUI/feasibility,
   data owner/store/restore, explicit-connect input, helper and credential code.
   Unknown/mixed build-info arguments must fail before startup. Print only JSON
   or a fixed error; never fall through into a workspace when metadata is absent.
2. Add a helper-owned build-metadata variable/package. Embed the same canonical
   JSON via Go link flags and verify runtime.GOOS/GOARCH, shared version/build and
   schema before emitting --build-info. Dispatch before transport/LSP/helper I/O.
   An ordinary Mac development helper may have no product identity.
3. Extend optional v3 hello.ack `buildIdentity` in Go, Swift and Rust plus additive
   shared fixtures. Existing Swift ordinary handshakes remain compatible, but the
   Windows/Linux product GUI calls `require_matching_helper(remote,version,caps)`
   before *any* connect/catalog/assessment/SQL/export operation. Missing identity,
   different version/build/source/target/semantic revision or missing capability
   refuses the helper. Enforce at common BackendClient handshake, not just export.
4. Preserve required `capturedExportV1`. Task 21 confirms it covers captured
   destination fingerprints, exact assessment/grants, ACK-sequenced query.progress
   across display limits and sqlCompleted/sqlNotExecuted/exportPublication error
   semantics. Wire protocol 3 alone is insufficient; no invented second progress
   capability replaces this contract. Swift full-export gates remain intact.
5. Generate the shared identity after source freeze and **before both native
   builds**. Export exact canonical DBEER_PRODUCT_BUILD_IDENTITY for Rust and the
   same Go link value; ensure gpui-prototype.sh/build-gpui-client.* cannot rebuild
   an unmarked helper afterward. Preserve Mac Swift build/signing scripts and
   ordinary development builds. Embed native product icon/title/app ID separately.
6. Change supported Windows/Linux build/CI candidate publication to call the new
   wrappers only after metadata/notice preparation. Existing development archives
   do not satisfy this contract and are refused by the hardened packager.

PRODUCT_TRANSPORT_CORE.md and BUILD_IDENTITY_CONTRACT_CORE.md retain the exact
shared transport/codec contract. No additional capability was introduced.

## Native package preparation

`packaging/package.py` and new scripts/package-gpui-client.sh/.ps1 use Python 3.11+
stdlib only. They never build a foreign target, install dependencies or publish.
The Linux wrapper refuses Mac/non-x64; the engine requires Ubuntu 24.04 x64.
The Windows wrapper requires native Windows x64 and the engine inspects PE32+
AMD64 headers. Overrides CARGO_BUILD_TARGET/GOOS/GOARCH are refused. ELF64 x86-64
headers, exact shared-source identity, distinct regular GUI/helper inputs,
canonical embedded metadata and matching bounded native --build-info responses
are mandatory. Missing or changed metadata refuses before executable launch.

Input trees refuse symlinks/reparse points/nonregular paths, unsafe archive names,
missing/stale/extra notices, and changed input bytes. Static readelf inspection
records exact ELF imports/GLIBC versions and rejects GLIBC newer than 2.39;
Windows dumpbin records actual imported DLLs. It does not execute ldd. Runtime
notes distinguish linked imports from dynamically loaded graphics/portal/store
facilities. RUNTIME.md records exact inspected locked backend archives:
Direct3D11/DXGI plus StructuredBuffer on Windows, wgpu Vulkan|GL on Linux.
Actual GPU/session/service/dependency resolution remains native acceptance.

A private 0700 mkdtemp stage contains only owned files. Ordered tar/ZIP members
have fixed timestamps/UIDs/GIDs/modes and deterministic compression for the same
inputs/Python toolchain. The stage includes binaries, shared metadata, full file
manifest, imports, installation/runtime notes, current changelog, original icons,
all theme sources/licenses and complete collected dependency notices. An
exclusive same-name claim and OS atomic **no-replace** directory rename publish
archive, SHA256 and identity together. Linux uses renameat2(RENAME_NOREPLACE),
Windows rename refuses an existing path; unsupported atomic primitives refuse.
Even an empty existing destination or stale claim is never overwritten/deleted.
Cleanup checks retained private-stage/claim identity and refuses foreign content.
Unix stage privacy is enforced; native Windows inherited ACLs/sharing/durability
and power-loss semantics remain acceptance obligations.

Output layout:

```text
build/gpui/candidates/DBeer-<version>-<build>-<os>-x86_64.candidate/
  DBeer-<version>-<build>-<os>-x86_64.{zip,tar.gz}
  DBeer-<version>-<build>-<os>-x86_64.{zip,tar.gz}.sha256
  BUILD-IDENTITY.json
```

Archive MANIFEST.json is schemaVersion 1 with productId/identity,
status `unsigned-development-candidate` and `files` keyed by safe relative member
path, each with sha256/size/executable. It excludes its own digest. Checksums prove
bytes, not publisher authenticity; Windows policy never changes system trust or
silences security warnings. Existing release metadata/archive numbers stay intact.

Exact future native preparation uses the paired wrappers; default builds compile
only, while the explicit options request the isolated verification and packaging
operations after the global implementation freeze:

```sh
# Ubuntu 24.04 x64; not executed during implementation.
./scripts/build-gpui-client.sh --test --package
```

```powershell
# Native Windows x64 Developer PowerShell; not executed during implementation.
./scripts/build-gpui-client.ps1 -Test -Package
```

The driver owns identity generation, both compiler inputs, resource preparation,
full locked metadata/notices and the exact private pair. The ordinary unmarked
prototype wrapper refuses a marked environment. See BUILD_INTEGRATION.md for the
fresh output layout and compile-only default.

The metadata generator/source digest never reads docs/. Re-running identity or
notices against an existing destination refuses; select an owned fresh path or
review/remove only your exact previous preparation file yourself. Do not delete
prior release outputs to reuse their names.

## Complete licenses and provenance

The notice collector reads complete all-feature Cargo metadata plus private
alternate-module-file go list -m -json all output and
copies original nested LICENSE/NOTICE/COPYING/OFL texts, not guessed license
expressions. The index ties exact current Cargo.lock/go.sum hashes to every
locked Rust package (a conservative multi-target/build/test superset) and all
required Go modules. Missing original text or an unreviewed Go replacement
refuses packaging. The complete 850-package lock graph has been statically
inspected: 769 dependencies contain original texts, and 80 use exact pinned
workspace/declaration provenance with 334 original notice references. The package
itself is excluded. All 44 external Go modules have original texts and exact
source/module checksums. Target-native collection still must run before creating
a candidate; no notice bundle or package was generated during this inspection.

Maintained gpui-pre-linux 0.3.9 Apache license/README retains source archive SHA256
`e28213c3fde6f13e91ba0b74b90cbaadec9373e36a031eda98561d31059870f3`, both Task 16
clipboard and Task 29 keyboard patches. Component/base exact 0.7.3 retain Apache
licenses, source revision, UPSTREAM.sha256, LOCAL-CHANGES.json and DBEER-PATCH.md;
component also retains LICENSE-LUCIDE. Their archive hashes are respectively
`465a363235cd4062ef5f0953fc096fc764ed6f53dfbd9f409f669f93ea3b1ff9` and
`2e9955b6f4b048fd50ca15fc8e225d80bb00ba9ebc8fecdddde5ad26dbef9270`.
Eight themes/ten original sources and four original notice/license texts are
included with PROVENANCE.md. See packaging/notices/NOTICES.md for exact mapping.
Imported user assets, credentials, private keys, SQL/history and profile libraries
never enter a distribution.

## Optional per-user Ubuntu integration

The extracted package includes integrate-linux.py, using the same app/icon/desktop
ID as product_identity and the GNOME session adapter. It writes only the user's
launcher, original SVG and a private exact ownership manifest under XDG_DATA_HOME
or ~/.local/share. It escapes Desktop Entry string/Exec rules, supports spaces,
Unicode and literal percent/quote/dollar/backtick/backslash characters, registers
no file/protocol associations or autostart, and needs no root. Existing entries
refuse install; updates remove owned integration before installing from a new
package folder. Remove preflights device/inode identities and exact digests before deleting only owned
entries and preserves changed/unrelated entries. It never removes binaries,
private app data, passwords or parent directories. Filesystem race resistance is
advisory/nonadversarial; native ACL/sharing and actual launcher behavior still
require supported desktops. No install/remove command was executed here.

## Prepared verification and remaining work

Rust cases cover strict identity fields/version/build/capability/target mismatch,
Rust/Go architecture normalization, exact actual legacy default path, opaque saved
demo-like IDs, no-fixture/disconnected startup policy and real second-process
kernel exclusion/byte preservation using owned fixture processes. Those are
compiled test code once declared, not exact previous/candidate installed evidence.
Python cases cover strict metadata, old-binary no-launch gating, static import
parsing/glibc limits, native target refusal, path/ELF/PE safety, deterministic
ZIP/tar members/modes/checksums, private modes, atomic empty-directory collision,
no-overwrite/stale claims, manifest digests/all assets, owned failure cleanup,
symlinks, legacy-data isolation and per-user desktop quoting/remove/collisions.
fixtures/packaging/cases.json retains the native upgrade/dependency scenarios.

Static checks completed in this core: rustfmt parse/format of owned Rust files,
Bash syntax, AST parsing of three Python modules, fixture JSON parsing, scoped
whitespace inspection. PowerShell is unavailable locally; no PowerShell
parse result or target-native compile/runtime is claimed. The integrated default/native-smoke all-target check and Clippy with warnings
denied plus root formatting also pass; BUILD_INTEGRATION.md and IMPLEMENTATION.md
record this static evidence. These checks do not run the prepared tests, package code or OS stores.

After all Task 32 code, final verification must produce completed summaries:

```sh
./scripts/gpui-prototype.sh test --locked -- product_identity:: --test-threads=1
python3 -m unittest discover -s prototypes/gpui/packaging -p 'test_*.py'
```

Run the equivalent native Windows checks with py -3. Then prepare exact native
archives and complete Task 32 on owned standard-user Windows 11 x64 and Ubuntu
24.04 x64 Wayland/X11: static/runtime dependency resolution, icons/app/desktop IDs,
file picker/keyboard/IME/accessibility/clipboard/Secret Service/Credential Manager,
normal/failed close, exact old/new ownership, UUID/profile/policy/TLS/selection,
credentials including missing/empty, SQL drafts/history/settings/theme/shortcuts,
disconnected restore/zero implicit connect or SQL, corrupt/future preservation,
manual update/rollback and removal without unrelated file/process changes.
The existing Mac SwiftUI build/tests/sign/release route remains an independent
regression gate. Neither prepared test code nor a headless container can accept
native graphical parity or close any of the 171 open native evidence cells.

## Final review publication boundary

The publisher retains each verified source input once and derives both
SOURCE-PROVENANCE and the packaged original resource/document/notice payloads from
those bytes. Collected dependency notices, including the original INDEX.json,
are retained as a complete verified snapshot; the staged legal bundle is checked
against that captured index. A source identity and complete original-notice
snapshot recheck runs inside `package()` immediately before atomic no-replace
publication. Both direct wrappers and the paired builder therefore refuse changed
inputs before any new immutable candidate appears. A caller's later source check
is supplementary and never authorizes deleting a published candidate.

Candidate source provenance also includes every reviewed Task30 producer input
from `verification/source_contract.py`. Installed acceptance joins that exact
named file map to the producer's raw-byte manifest; it does not compare the two
different aggregate digest algorithms. Historical source pins and digest-only
completed summaries cannot establish results for this revised source contract.

Stage cleanup retains the exact identities and types of created files and
directories, checks the complete current inventory, then removes only unchanged
owned entries and empty original directories. Added unknown content, replaced
stage entries/root and foreign replacement claims survive. There is no recursive
stage deletion or cleanup of an already published candidate. Prepared synthetic
actual-package/paired-driver tests cover source/legal/index changes, prior and
foreign preservation, and unchanged provenance/INDEX/MANIFEST/archive byte joins;
they remain unexecuted until final integration authorization.
