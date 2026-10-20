# Published Rust dependency notice sources

`INDEX.json` supplies notices for the 80 packages whose exact published crate
archives omit a collector-recognized license filename. The catalog binds each
package to its root `Cargo.lock` archive checksum, the original normalized
published `Cargo.toml` bytes, and the original `.cargo_vcs_info.json` hash when
present. Each text file is copied without edits; its content hash forms its
storage directory. `NOTICE-*` filenames label preserved complete original
files without changing their contents.

Every record retains the publisher's exact manifest, including its authors and
license declaration. Project legal files are retained from the recorded upstream
commit where available. All six declared standard license identifiers are also
supplied from the official SPDX license-list-data repository at commit
`31ba1a50e5397e00a304dbadc76531740e89ee48`. The corresponding original SPDX
metadata is retained under `proofs/`. Standard text placeholders are unchanged;
no author, copyright year, or grant has been inserted.

The `declaredBy` reference chain links each standard text to the exact preserved
publisher manifest and its unchanged license expression. The
[Cargo manifest reference](https://doc.rust-lang.org/cargo/reference/manifest.html#the-license-and-license-file-fields)
explains that this field identifies the package's license using SPDX expressions,
that `OR` offers a choice, and that the earlier slash separator is deprecated.
The [SPDX License List](https://spdx.org/licenses/) provides the standard identifier
and text mapping. The catalog preserves all declared alternatives. Project
notices and standard terms have separate provenance and are never presented as
an invented project-specific license file.

The seven crates without Cargo VCS metadata were matched to immutable upstream
release tags. Their package names and versions were checked in the upstream
manifests, and every other packaged file was byte-compared with that release
source. The original manifests, archive hashes, and per-file comparisons are
recorded in `proofs/*-release-source-review.json`. The GNU support crates version
`0.4.0` match the winapi-rs parent release tag `0.3.6`, commit
`4ac6c90e4ab92850c78b6103137290fe4ab9d273`: all 1,389 i686 files and 1,418 x86_64
files match. The later parent tag `0.3.9` was rejected because its sources differ.

Two upstream details remain explicit in the provenance:

- `tree-sitter-sequel` was published from a dirty tree. Its original metadata
  remains `dirty: true`; the published archive and declaration are authoritative
  for the package, while upstream commit files identify its base revision.
- `pathfinder_geometry` records commit
  `a5e98fac00f433fe2ff4b2135383d82491b8bfc5`, which was unavailable from the original
  repository during retrieval. The catalog retains that original value and uses
  the checksum-verified published archive's declaration and attribution for its
  standard terms. It does not claim to have retrieved that commit.

The two zune crates without a repository field identify zune-image through their
published homepage. Their original VCS commit and workspace path are preserved,
and the catalog records this derivation rather than inventing a publisher field.

This catalog records source and notice completeness. It does not attest a built
binary, an installed package, or native runtime acceptance. Network retrieval and
all archive comparisons were static; no dependency code or product was run.
