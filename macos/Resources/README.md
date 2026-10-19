`AccentColors.xcassets` defines the amber accent used by system menus and controls in light and dark appearances. Its values match `AppPalette.accent`.

The compiled `Assets.car` is checked into the repository so normal application builds work with Command Line Tools without full Xcode.

After changing colors, rebuild the catalog with `./scripts/compile-accent-colors.sh` (requires Xcode's `actool`) and commit the updated `Assets.car` together with the source catalog.
