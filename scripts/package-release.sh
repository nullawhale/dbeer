#!/usr/bin/env bash
# Build locally with the owner's persistent identity. This never publishes files.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/version.sh"
if [[ "${CI:-}" == true || "${GITHUB_ACTIONS:-}" == true || "${DBEER_CI_SIGNING:-0}" == 1 ]]; then
    printf 'Team releases must be built on the owner Mac with its persistent signing identity. CI packaging is disabled.\n' >&2
    exit 1
fi
release_root="$repo_root/build/releases"
archive_name="DBeer-$dbeer_version-$dbeer_build_number-macos-arm64.zip"
archive="$release_root/$archive_name"
mkdir -p "$release_root"
release_lock="$release_root/.package.lock"
if ! mkdir "$release_lock" 2>/dev/null; then
    printf 'A release is already being packaged.\n' >&2
    exit 1
fi
staging=""
cleanup() {
    if [[ -n "$staging" ]]; then rm -rf "$staging"; fi
    rm -f "$archive.new" "$archive.sha256.new"
    rmdir "$release_lock"
}
trap cleanup EXIT
if [[ -e "$archive" || -e "$archive.sha256" ]]; then
    printf 'Release already exists. Increase BUILD_NUMBER before creating another archive.\n' >&2
    exit 1
fi
CONFIGURATION=release "$repo_root/scripts/build-app.sh"
app="$repo_root/build/DBeer.app"
build_kind="$(/usr/libexec/PlistBuddy -c 'Print :DBeerBuildKind' "$app/Contents/Info.plist")"
signature="$(codesign -d --verbose=4 "$app" 2>&1)"
if [[ "$build_kind" != local || "$signature" == *'DBeer CI Ephemeral Signing'* ]]; then
    printf 'Refusing to package an app with a temporary CI signature.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$app"
staging="$(mktemp -d "$release_root/.stage.XXXXXX")"
ditto "$app" "$staging/DBeer.app"
staged_app="$staging/DBeer.app"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$staged_app/Contents/Info.plist")" != "$dbeer_version" ||
      "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$staged_app/Contents/Info.plist")" != "$dbeer_build_number" ]]; then
    printf 'The app version changed while packaging. Retry with stable VERSION and BUILD_NUMBER.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$staged_app"
cp "$repo_root/CHANGELOG.md" "$staging/CHANGELOG.md"
cp "$repo_root/INSTALL.md" "$staging/INSTALL.md"
cp "$repo_root/LICENSE" "$staging/LICENSE"
ditto -c -k --sequesterRsrc "$staging" "$archive.new"
unzip -tq "$archive.new" >/dev/null
checksum="$(shasum -a 256 "$archive.new")"
printf '%s  %s\n' "${checksum%% *}" "$archive_name" > "$archive.sha256.new"
mv "$archive.new" "$archive"
mv "$archive.sha256.new" "$archive.sha256"
printf 'Created %s\nCreated %s.sha256\n' "$archive" "$archive"
