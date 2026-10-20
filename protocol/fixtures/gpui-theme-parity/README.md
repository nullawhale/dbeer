# Shared GPUI and Swift theme parser fixtures

Additive synthetic sources exercise the actual Swift EditorThemeParser and Rust
theme_library parser. cases.json specifies the entire normalized color map and
ordered token rules (hex is only compact expected RGBA notation), plus resolved
scope styles. Both consumers load the source and compare independently against
these expectations. The binary TextMate file is the same dictionary as the XML
fixture, serialized by Python plistlib while preparing fixture assets.

jetbrains-parent.icls additionally exercises the bundled Darcula/Default parent.
Source files contain no real user content and never reference network resources.
The URL-looking JSONC name is literal text. No existing frozen parity resource,
baseline, replay, manifest or hash is replaced by this fixture directory.
