# Supplementary Linux vendor unit-target compile proof

This is local **compile-only** evidence from a frozen public vendor snapshot on
2026-10-19. No Rust test binary, application, helper, database, credential service
or desktop session ran. Runtime checks remain deferred until all Task 32 code is
integrated. The macOS product remains SwiftUI/AppKit.

The snapshot predates the later Task 24 Atomic/full-selection vendor edits. This
report does not establish compilation of the current integrated application or
current vendor source. The immutable source manifests identify the actual input.

## Separate completed layers

| Layer | Actual result | Source and dependency scope |
| --- | --- | --- |
| Original platform harness | `cargo check --locked --all-targets`, exit 0 | Actual frozen base/component/pre-linux dependency branches; dependency unit targets were not selected by the harness. |
| First standalone unit attempt | Base lib-test exit 101; later stages not reached | Public parent `prototypes/gpui/README.md` was absent from staging. The existing include path was valid in the checkout; no vendor edit was needed. |
| README staging retry: base | `--all-targets`, exit 0, 14.108 s | Actual `gpui-base/Cargo.toml` standalone graph. Its resolved lock added standalone dev packages; no alternate versions of root-known package names were introduced. |
| README staging retry: component | `--all-targets --features tree-sitter,tree-sitter-sql`, exit 0, 214.262 s | Actual `gpui-component/Cargo.toml` standalone dev graph, including the alternate versions listed below. This is not exact-root graph coverage. |
| README staging retry: pre-linux | `--all-targets`, exit 101, 111.999 s | Actual `gpui-pre-linux/Cargo.toml` lib-test failed because the command omitted the existing `test-support` feature. |
| Bounded pre-linux feature retry | `--locked --offline --all-targets --features test-support`, exit 0, 25.984 s | Same frozen pre-linux source and unchanged resolved lock; existing feature propagates `gpui/test-support`. No source edit or new dependency version was required. |

The original harness proof is
`build/gpui/task30-platform-f7f2d338b35e4cad90b454d5f38a6b6f/completed.json`.
The first failed unit proof remains at
`build/gpui/task30-platform-units-daf34924af2d4f6d80318aa4099be129/completed.json`.
The README staging retry retains its full logs and `stages.json` at
`build/gpui/task30-platform-units-76a091159617488a984a29a47ea00d85/`.
Its original `completed.json` is absent. The new proof directory records that
attempt's actual exit-101 stage, unchanged log hashes and separate cleanup
observation without rewriting or inventing its terminal container exit.

## Bounded pre-linux retry

Proof directory:
`build/gpui/task30-unit-proof-70f2d3b6bb214ec3b6e9fa78189582f0/`.
`completed.json` records actual Cargo and Docker exits, completed Cargo JSON,
source and lock comparisons, exact container identity and cleanup. Full
compiler diagnostics are in `gpui-pre-linux.log`; Cargo artifact events are in
`compiler-events.jsonl`. The actual command was:

```sh
cargo check --locked --offline --all-targets \
  --manifest-path /work/source/prototypes/gpui/vendor/gpui-pre-linux/Cargo.toml \
  --features test-support --message-format=json-render-diagnostics \
  --config 'patch.crates-io.gpui-base.path="/work/source/prototypes/gpui/vendor/gpui-base"' \
  --config 'patch.crates-io.gpui-component.path="/work/source/prototypes/gpui/vendor/gpui-component"' \
  --config 'patch.crates-io.gpui-pre-linux.path="/work/source/prototypes/gpui/vendor/gpui-pre-linux"'
```

The pre-linux Cargo artifact explicitly has `profile.test=true`, target
`gpui_linux`, the actual staged vendor manifest, and `test-support`, default
Wayland and X11 features. `build-finished.success=true`. This confirms the real
lib-test configuration was typechecked; `cargo check` does not link or execute a
test binary. The harmless unused base/component patch warnings remain in the
full log because those crates are absent from this standalone pre-linux graph.

`prior-unit-target-fingerprints.json` separately retains the completed Cargo
`test-lib-gpui_base` and `test-lib-gpui_component` fingerprints and metadata
artifact hashes from the original compile cache. Their modification times fall
within the successful base/component stage windows; component records the exact
tree-sitter features. Those records support the earlier unit-target selection,
without converting the component dev graph into root-lock coverage.

The retry source manifest covers 531 public files, including the public parent
README and resolved standalone locks. Its canonical SHA256 is
`5c4e3b16b07981c6e7dcb99ec2c35ebbd40c76b8051dbfcba1b140c50347bcfb`.
All staged source bytes and the prior frozen snapshot remained unchanged.
The pre-linux lock SHA256 remained
`d9f5ec08342fe40989e9070db87a618173dcea0d42f055550d830f1a347d92aa`;
no alternate root-known versions were present. The current moving Task 24
originals were neither copied nor required to match this older source manifest.

The exact owned image was
`sha256:8a3bf109710797f6b79ffd396e0c100a90ca4c07ca8195fbf13959da960d29df`,
with ownership nonce `0282e61aa8114cdda118b5dbab00e2ac`, Ubuntu 24.04 amd64 and
pinned Rust 1.99.1. The Linux ARM64 Docker daemon emulates x64. The retry used
independent APFS clones of the prior public crates.io registry/compiler cache;
the original cache was not mounted writable. Docker networking was disabled;
there was no image build, package provisioning, download, credential copy,
checkout metadata or private profile staging. CPU quota was 2, Cargo jobs 2,
memory 8 GiB, Cargo deadline 600 seconds and collector deadline 720 seconds.

Retry container ID:
`a222386cc1db71516ae99eddd38fd9d3e44a7251fa2af47993a84dd8ee20ebb7`.
Its nonce label was `app.dbeer.task30-run=70f2d3b6bb214ec3b6e9fa78189582f0`.
The retained Docker process returned exit 0; `--rm` removed the exact container.
A subsequent exact-ID observation found it absent with Docker reachable. No
foreign container or process was stopped. For the earlier missing-watcher run,
only the recorded exact CID was inspected and the exact watcher command was
observed absent; no container exit code was inferred from absence.

## Component standalone dev-graph differences

The successful standalone component check used lock SHA256
`be823d08dd3c7e27d3e95806c4b171d5783c46bfe5e55cbbadcf191a77a6e376`.
Compared with the root pin package/version set, it contains these additional
versions of root-known names:

- `mach2@0.4.3`
- `ndk-sys@0.5.0+25.2.9519653`
- `nom@7.1.3`
- `shlex@1.3.0`
- `windows@0.54.0`
- `windows-core@0.54.0`
- `windows-sys@0.45.0`
- `windows-targets@0.42.2`
- `windows_aarch64_gnullvm@0.42.2`
- `windows_aarch64_msvc@0.42.2`
- `windows_i686_gnu@0.42.2`
- `windows_i686_msvc@0.42.2`
- `windows_x86_64_gnu@0.42.2`
- `windows_x86_64_gnullvm@0.42.2`
- `windows_x86_64_msvc@0.42.2`

`prior-attempt-terminal-observation.json` retains the complete lock comparison
for each standalone crate, including every added standalone dev package. No
versions were forced or manifests changed to create an aggregate pass. The
original root-pinned dependency-harness pass, each standalone unit graph, the
original failures and the passing pre-linux retry remain separate evidence.

## Remaining verification boundary

Current integrated app/vendor compilation and final standalone dependency-unit
build/run collection remain required at final integration. This local proof
covers neither Windows nor a native Ubuntu x64 host, Wayland/X11 desktop UI,
installed acceptance, real secure stores, accessibility, IME, clipboard, file
pickers, mixed DPI, database behavior or helper protocol behavior. It does not
change frozen acceptance cells or complete Task 30 runtime checkboxes.


## Earlier three-graph preparation checkpoint

This section is preparation for the final source, separate from every historical
compile proof above. No current unit binary or helper ran during preparation.
The current root lock has 850 packages; fresh actual standalone base/component/
pre-linux graphs contain 807/709/628. Base adds 39 and omits 82 root pairs, with
no alternate root-known version. Component adds 71 and omits 212; its fifteen
alternate root-known versions are exactly the historical dev versions listed
above. Pre-linux adds none and omits 222. No current graph changes a root-known
source/checksum identity. Complete exact pair lists and full manifest/lock/source
hashes are in verification/dependency-inputs.json; all four maintained patches
are explicit in every standalone command.

Pre-linux's relocated manifest still changes only lib.path, uses actual current
vendor source and test-support, and binds all 29 source hashes in its refreshed
inputs.json. The base/component locks were regenerated from the current root
seed and their LOCAL-CHANGES audits updated by the source owner. Offline workspace
resolution and locked no-deps metadata passed for all three and the separate
platform harness. They establish preparation only, not full metadata, link or
native runtime coverage. Missing public locked dependencies must be provisioned
explicitly before the offline runner, never silently during a test run.

The new gpui-pre source changes host-manifest build behavior and equivalent
Unicode escapes. Its unrelated standalone dev graph required uncached stacksafe;
that failed preparation is retained. The original upstream lock was restored
byte-for-byte, SHA256
579c2d5508ddd398507977abf0d2520509035059eb73511bdf3070f8f0dafc1c.
Actual root dependency artifacts must select the maintained gpui-pre manifest
without the candidate-only host resource feature. Task 31's Windows static
feature inspection and real native PE/resource/installed gates cover its intended
change; unrelated upstream UI tests are outside this focused requirement.


## Current focused disabled-semantics proof (2026-10-20)

The original 698 source rows and three standalone graphs (807/709/628 packages)
remain unchanged. Current focused verification used the existing 850-package root
graph for the maintained Div alternative, with no manifest or lock change and no
active fourth standalone runtime graph. On the Mac development host, the exact
dependency-owned Button unit passed once; the faithful
[root Div integration target](tests/maintained_pre_disabled.rs) also passed once,
with zero failures or ignored cases.

The Div target preserves all three original assertions: unspecified false,
explicit true and explicit false on real AccessKit nodes. Its public
`Element::write_a11y_info` follows Stateful → Div → the same Interactivity writer
used by the original unit. The strict `publicElementUnit` contract binds the full
original source/unit-body hashes, mechanical adaptation, new target/source hash
and exact selector; the source inventory includes the root tests directory.
Actual compiled Kit features/origins and local maintained pre source establish
that no gpui-fast artifact was compiled for this integration. The root lock still
contains an inactive gpui-fast entry.

The original `gpui-pre --lib` own-unit binary was **NOT EXECUTED**: compilation
hit four unrelated upstream cfg(test) errors (one attribute, two missing font
assets and an unresolved import). The authenticated 468-package graph/cache
attempt, command refusals and complete compiler failures remain historical in
`build/gpui/reviews/fix-final-maintained-own-units/`. Its temporary fourth-graph
recipe was superseded by the public-root alternative; unrelated upstream suites
remain outside this focused scope. Exact completed rows/artifacts and the
independent final audit are retained with that packet and the integration-review
supersession. This bounded proof establishes no full matrix, native Windows/Ubuntu
desktop or installed acceptance; all 171 native cells and F57 remain pending.
