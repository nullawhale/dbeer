# Bundled editor theme sources

These files are byte-for-byte copies of the actual local Swift source resources
in macos/Sources/DBeer/Resources/EditorThemes as inspected on 2026-10-19.
GPUI embeds its own copies and never requires a Mac build, Bundle.module, ignored
docs, network retrieval or the Swift resource output at build/run time. Swift's
original resources and build remain unchanged.

| Normalized ID | Source | Included source / parent |
| --- | --- | --- |
| native-light | dbeer-light.json | Original DBeer resource |
| native-dark | dbeer-dark.json | Original DBeer resource |
| vscode-light-plus | light_plus.json | light_vs.json |
| vscode-dark-plus | dark_plus.json | dark_vs.json |
| solarized-light | solarized-light-color-theme.json | None |
| solarized-dark | solarized-dark-color-theme.json | None |
| jetbrains-light | jetbrains-default.icls | Default; display title JetBrains Light |
| jetbrains-darcula | jetbrains-darcula.icls | Default from jetbrains-default.icls |

Eight selectable schemes require ten source assets, including the two VS Code
include files. JetBrains Default/Darcula parents used for imports resolve to
these same embedded sources, never to arbitrary filesystem or network resources.

NOTICE.txt and LICENSE-vscode.txt retain the upstream Microsoft MIT attribution
and pinned source revision. NOTICE-jetbrains.txt and LICENSE-jetbrains.txt retain
the JetBrains attribution, pinned source revision and Apache 2.0 license. These
four copied notice/license files must accompany redistributed GPUI artifacts.
No upstream attribution is inferred from a downloaded replacement.
