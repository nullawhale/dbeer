#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/version.sh"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    printf 'DBeer builds require an Apple Silicon Mac.\n' >&2
    exit 1
fi
for ssh_tool in /usr/bin/ssh /usr/bin/ssh-keyscan; do
    if [[ ! -x "$ssh_tool" ]]; then
        printf 'DBeer SSH support requires the macOS OpenSSH tools.\n' >&2
        exit 1
    fi
done
build_root="$repo_root/build"
app="$build_root/DBeer.app"
configuration="${CONFIGURATION:-release}"
signing_keychain="${DBEER_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
signing_identity="${DBEER_SIGNING_IDENTITY:-}"
build_kind=local
if [[ "${DBEER_CI_SIGNING:-0}" == 1 ]]; then
    if [[ "${CI:-}" != true || "${GITHUB_ACTIONS:-}" != true ]]; then
        printf 'Temporary CI signing is only allowed in GitHub Actions.\n' >&2
        exit 1
    fi
    build_kind=ci
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning "$signing_keychain" |
        awk '/"Apple Development:/ { print $2 }')"
    identity_count="$(printf '%s\n' "$signing_identity" | awk 'NF { count++ } END { print count+0 }')"
    if [[ "$identity_count" != 1 ]]; then
        printf 'Expected one valid Apple Development identity, found %s. Set DBEER_SIGNING_IDENTITY to the certificate SHA-1 shown by security find-identity -v -p codesigning.\n' "$identity_count" >&2
        exit 1
    fi
fi
if [[ -z "$signing_identity" || "$signing_identity" == '-' ]]; then
    printf 'A persistent signing identity is required; ad hoc signing is disabled.\n' >&2
    exit 1
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" "$build_root/.cache"
for icon in AppIcon AppIconDark; do
    cp "$repo_root/macos/Resources/$icon.icns" "$app/Contents/Resources/$icon.icns"
done
for icon in ToolbarIcon ToolbarIconDark; do
    cp "$repo_root/macos/Resources/$icon.svg" "$app/Contents/Resources/$icon.svg"
done
cp "$repo_root/macos/Resources/Assets.car" "$app/Contents/Resources/Assets.car"
cp "$repo_root/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$repo_root/helper/internal/textdiff/LICENSE.revdiff" "$app/Contents/Resources/LICENSE-revdiff.txt"
cp -f "$repo_root/helper/internal/mongodb/licenses/LICENSE.mongo-driver" "$app/Contents/Resources/LICENSE-mongo-driver.txt"
cp -f "$repo_root/helper/internal/mongodb/licenses/THIRD-PARTY-NOTICES.mongo-driver" "$app/Contents/Resources/NOTICE-mongo-driver.txt"
cp "$repo_root/helper/third_party/cassandra-gocql-driver/LICENSE" "$app/Contents/Resources/LICENSE-cassandra-gocql-driver.txt"
cp "$repo_root/helper/third_party/cassandra-gocql-driver/NOTICE" "$app/Contents/Resources/NOTICE-cassandra-gocql-driver.txt"
mkdir -p "$app/Contents/Resources/MCP-Licenses"
cp -f "$repo_root/helper/internal/mcpbridge/licenses/"* "$app/Contents/Resources/MCP-Licenses/"
export GOCACHE="$build_root/.cache/go"
export GOMODCACHE="$build_root/.cache/go-mod"
export CLANG_MODULE_CACHE_PATH="$build_root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/.cache/swift-modules"

(
    cd "$repo_root/helper"
    go build -trimpath -o "$app/Contents/Helpers/dbeer-core" ./cmd/dbeer-core
)
swift build --disable-sandbox --cache-path "$build_root/.cache/swiftpm" \
    --package-path "$repo_root/macos" --scratch-path "$build_root/swift" \
    --configuration "$configuration" -debug-info-format none --product DBeer
swift_bin="$(swift build --disable-sandbox --cache-path "$build_root/.cache/swiftpm" \
    --package-path "$repo_root/macos" --scratch-path "$build_root/swift" \
    --configuration "$configuration" -debug-info-format none --show-bin-path)"
cp "$swift_bin/DBeer" "$app/Contents/MacOS/DBeer"
"$repo_root/scripts/prepare-swift-resources.sh" "$swift_bin/DBeer_DBeer.bundle"
# Replace the generated bundle so an earlier SwiftPM build cannot leave links
# at the copy destination or retain resources from a different bundle layout.
rm -rf -- "$app/Contents/Resources/DBeer_DBeer.bundle"
cp -R "$swift_bin/DBeer_DBeer.bundle" "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DBeer</string>
    <key>CFBundleIdentifier</key><string>dev.dbeer.app</string>
    <key>CFBundleName</key><string>DBeer</string>
    <key>CFBundleDisplayName</key><string>DBeer</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$dbeer_version</string>
    <key>CFBundleVersion</key><string>$dbeer_build_number</string>
    <key>DBeerBuildKind</key><string>$build_kind</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAccentColorName</key><string>AccentColor</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --timestamp=none --keychain "$signing_keychain" --sign "$signing_identity" \
    --identifier dev.dbeer.core "$app/Contents/Helpers/dbeer-core"
# The askpass and crash-watchdog entry points dispatch in this same binary,
# including outside the source checkout; there are no unsigned script helpers.
codesign --verify --strict "$app/Contents/Helpers/dbeer-core"
codesign --force --timestamp=none --keychain "$signing_keychain" --sign "$signing_identity" "$app"
codesign --verify --deep --strict "$app"
# Let Finder notice resource changes when rebuilding an existing app bundle.
touch "$app"
printf 'Built %s (%s, build %s, %s signature)\n' "$app" "$dbeer_version" "$dbeer_build_number" "$build_kind"
