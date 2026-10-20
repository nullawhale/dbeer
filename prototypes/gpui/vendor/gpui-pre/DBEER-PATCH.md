# Maintained DBeer host manifest selection

Upstream: gpui-pre 0.3.9, Apache-2.0, from
https://static.crates.io/crates/gpui-pre/gpui-pre-0.3.9.crate .
Archive SHA256: `34f61c1cfd36fc9c436af09308c963822ae27a45a84feb21a77ba5c9e051f1c0`.
The source snapshot is Zed revision
`93d745668805029476e6d7fbb19652116fed51de`. All 160 original archive files are
retained. UPSTREAM.sha256 records every original byte digest; LOCAL-CHANGES.json
records each changed file. Preserve the original Apache license and README.

The additive `windows-manifest-provided-by-host` feature changes only build.rs
manifest selection. Upstream `windows-manifest` remains enabled by default and
continues embedding its original resource in ordinary unmarked builds. Cargo
features unify additively, so changing one caller's default-features setting
cannot remove the many other edges enabling that default. When the explicit
host feature is selected, this build script skips its RT_MANIFEST 1 resource.
The application owns the sole generated host manifest, icon and version resource.

Host mode requires native x86_64-pc-windows-msvc release, the exact embedded
DBEER_PRODUCT_BUILD_IDENTITY marker and a generated resource directory whose
BUILD-IDENTITY.json equals that marker plus one newline. Missing prerequisites
fail the build; selecting the feature cannot silently produce a manifestless
product. The application build hook separately validates the full canonical
identity and every generated resource input before compiling/linking its RC.
Neither /MANIFEST:NO nor feature presence alone proves resource exclusivity:
the native build and packager enumerate all manifest names/languages and require
only the exact host resource ID 1 in English (0x0409).

The application candidate driver selects host mode only for its Windows GUI
binary. Ordinary development and isolated unmarked test targets retain upstream
manifest behavior. No GUI resources are injected into dependencies/tests through
global RUSTFLAGS. Original runtime source, API and backend feature defaults stay
intact. Two existing example/test strings represent their original characters
with equivalent Rust Unicode escapes to meet DBeer's source-character policy;
the text and assertions retain the same values.

The root Cargo patch is activated, and the native driver explicitly selects
this feature only for the marked Windows candidate. Compile-only checks do not establish a Windows
resource link, native GUI run, DPI behavior, signing or installed acceptance.
