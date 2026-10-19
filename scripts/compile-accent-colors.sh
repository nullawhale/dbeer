#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
actool="$(xcrun --find actool 2>/dev/null || true)"
if [[ -z "$actool" && -x /Applications/Xcode.app/Contents/Developer/usr/bin/actool ]]; then
    actool=/Applications/Xcode.app/Contents/Developer/usr/bin/actool
fi
if [[ -z "$actool" ]]; then
    printf 'Regenerating the accent color asset requires Xcode and actool. Normal app builds use the checked-in Assets.car.\n' >&2
    exit 1
fi

# Keep the compiled color asset in source control so regular CLT-only builds
# retain native menu accents without requiring the full Xcode installation.
"$actool" --compile "$repo_root/macos/Resources" \
    --platform macosx --minimum-deployment-target 14.0 \
    --target-device mac --accent-color AccentColor \
    --output-format human-readable-text \
    "$repo_root/macos/Resources/AccentColors.xcassets"
