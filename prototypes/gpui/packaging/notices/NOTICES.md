# DBeer candidate third-party material

Original DBeer icons are copied unchanged from macos/Resources/AppIcon.svg and
AppIcon.png. Packaging requires no generated Mac bundle or Mac build. No license
for the DBeer application itself is inferred from dependency licenses.

The distribution includes original texts collected from **every** package in the
current Cargo.lock (a conservative superset of the target-linked graph) and Go
module inventory, with locked checksum provenance in notices/dependencies/INDEX.json.
The collector refuses missing original license/notice text, unresolved module
replacements, stale lock provenance, symlinks and unexpected notice files. Actual
native dependency/license collection must complete before producing a candidate.
A bare license expression never substitutes for preserved legal material.
The collector uses all-feature metadata to cover every current locked package,
including unselected optional/test/other-target nodes. Published archives that
omit workspace legal files use the reviewed upstream/INDEX.json catalog: exact
archive, manifest and Cargo VCS hashes bind original upstream texts. The package
retains the entire catalog, original publisher declarations, authors and source
availability proofs. An explicit project link or publisher SPDX declaration may
reference complete authoritative standard terms; those original terms and their
exact reference chain are retained without inserting copyright holders or years.
See upstream/PROVENANCE.md. This records notice/source completeness, not legal
clearance or an independent attestation of a compiled artifact.
The inventory may include build/test/other-target dependencies; inclusion does
not imply those features are enabled. Review any additional source-availability
or attribution obligation before publication; no publication is performed here.

The collector also requires actual installed toolchain runtime texts: Go's
original LICENSE/PATENTS and Rust's COPYRIGHT-library.html plus original sysroot
license files. The index records their actual compiler/runtime versions and exact
file digests under runtime/. No missing toolchain text is replaced by a guessed
license expression or a downloaded unrelated copy. This is a conservative notice
superset and does not assert that every listed compiler component is linked.

Maintained local sources retain the following original licenses/provenance:

| Package | Source archive SHA256 | Original license |
| --- | --- | --- |
| gpui-pre-linux 0.3.9 | e28213c3fde6f13e91ba0b74b90cbaadec9373e36a031eda98561d31059870f3 | Apache-2.0 |
| gpui-pre 0.3.9 | 34f61c1cfd36fc9c436af09308c963822ae27a45a84feb21a77ba5c9e051f1c0 | Apache-2.0 |
| gpui-component 0.7.3 | 465a363235cd4062ef5f0953fc096fc764ed6f53dfbd9f409f669f93ea3b1ff9 | Apache-2.0 |
| gpui-base 0.7.3 | 2e9955b6f4b048fd50ca15fc8e225d80bb00ba9ebc8fecdddde5ad26dbef9270 | Apache-2.0 |

Linux comes from the GPUI snapshot at Zed
93d745668805029476e6d7fbb19652116fed51de; its README records both the maintained
Task 16 Wayland/X11 multi-format clipboard patch and additive Task 29 raw native
keyboard safety evidence patch. Preserve both changes and the original Apache
text. Component/base come from longbridge/gpui-kit revision
67265a36e260ffe03c5aaebdcd8d654dbf892eab, crates/component and crates/base.
Their DBEER-PATCH.md, UPSTREAM.sha256, LOCAL-CHANGES.json and .cargo_vcs_info.json
accompany the licenses. Component's restored test icons additionally retain
LICENSE-LUCIDE from exact gpui-kit-assets 0.7.3. The application also embeds
GPUI Kit default icon assets; the dependency notice collector includes the
original package's icon/font licenses and all nested NOTICE/LICENSE/OFL files.

The gpui-pre archive at the same Zed revision retains all 160 original files and
its Apache license. Its additive host-manifest feature selects the sole product
GUI resource while ordinary development defaults retain upstream embedding.
Two original test/example strings use equivalent Rust Unicode escapes. The
complete original/changed hashes and patch explanation accompany its notices.

Eight selectable themes consume ten unchanged local source assets. All ten are
included under themes/, together with the original four NOTICE/LICENSE files
and PROVENANCE.md. VS Code theme sources retain Microsoft MIT notices; IntelliJ
Default/Darcula scheme sources retain JetBrains Apache-2.0 notices. The DBeer
native sources are original resources. Imported user themes, profiles, SQL,
history, credentials and private keys are never package inputs.

Upstream archives:
[Linux](https://static.crates.io/crates/gpui-pre-linux/gpui-pre-linux-0.3.9.crate),
[component](https://static.crates.io/crates/gpui-component/gpui-component-0.7.3.crate),
[base](https://static.crates.io/crates/gpui-base/gpui-base-0.7.3.crate).
This file supplements the included original texts and patch audits; it does not
replace them or claim that an unsigned, unaccepted candidate is a public release.
