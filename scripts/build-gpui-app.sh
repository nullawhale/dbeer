#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/version.sh"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    printf 'DBeer GPUI builds require an Apple Silicon Mac.\n' >&2
    exit 1
fi

configuration="${CONFIGURATION:-debug}"
case "$configuration" in
    debug) cargo_profile=debug ;;
    release) cargo_profile=release ;;
    *)
        printf 'CONFIGURATION must be debug or release.\n' >&2
        exit 2
        ;;
esac

signing_keychain="${DBEER_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
signing_identity="${DBEER_SIGNING_IDENTITY:-}"
if [[ "${DBEER_CI_SIGNING:-0}" == 1 ]]; then
    if [[ "${CI:-}" != true || "${GITHUB_ACTIONS:-}" != true ]]; then
        printf 'Temporary CI signing is only allowed in GitHub Actions.\n' >&2
        exit 1
    fi
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

gpui_target_dir="${CARGO_TARGET_DIR:-$repo_root/build/gpui/target}"
export CARGO_TARGET_DIR="$gpui_target_dir"
if [[ "$configuration" == release ]]; then
    "$repo_root/scripts/gpui-prototype.sh" build --locked --release
else
    "$repo_root/scripts/gpui-prototype.sh" build --locked
fi
gpui_target_dir="$(cd -- "$gpui_target_dir" && pwd -P)"
if [[ "$gpui_target_dir" == "$repo_root/build/gpui/target" ]]; then
    default_helper="$repo_root/build/gpui/dbeer-core"
else
    default_helper="$gpui_target_dir/dbeer-core"
fi
helper_source="${DBEER_GPUI_HELPER_PATH:-$default_helper}"

app="$repo_root/build/DBeerGPUI.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$gpui_target_dir/$cargo_profile/dbeer-gpui" "$app/Contents/MacOS/DBeerGPUI"
cp "$helper_source" "$app/Contents/Helpers/dbeer-core"
cp "$repo_root/macos/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DBeerGPUI</string>
    <key>CFBundleIdentifier</key><string>dev.dbeer.gpui-prototype</string>
    <key>CFBundleName</key><string>DBeer GPUI</string>
    <key>CFBundleDisplayName</key><string>DBeer GPUI</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$dbeer_version</string>
    <key>CFBundleVersion</key><string>$dbeer_build_number</string>
    <key>DBeerBuildKind</key><string>prototype</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --timestamp=none --keychain "$signing_keychain" --sign "$signing_identity" \
    --identifier dev.dbeer.gpui-prototype.core "$app/Contents/Helpers/dbeer-core"
codesign --force --timestamp=none --keychain "$signing_keychain" --sign "$signing_identity" "$app"
codesign --verify --deep --strict "$app"
touch "$app"
printf 'Built %s (%s, build %s, prototype, %s)\n' "$app" "$dbeer_version" "$dbeer_build_number" "$configuration"
