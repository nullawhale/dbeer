#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="$repo_root/build"
scratch="$build_root/landing-swift"

if [[ "$#" == 0 ]]; then
    # The database and its random password are removed on exit, including failure.
    exec "$repo_root/scripts/test-postgres.sh" "$0" --capture
fi
if [[ "$#" != 1 || "$1" != --capture || -z "${DBEER_TEST_DSN:-}" ]]; then
    printf 'Usage: scripts/capture-screenshots.sh (requires Docker and a built DBeer.app)\n' >&2
    exit 2
fi
if [[ ! -x "$build_root/DBeer.app/Contents/Helpers/dbeer-core" ]]; then
    printf 'Build the app with scripts/build-app.sh before capturing screenshots.\n' >&2
    exit 1
fi

mkdir -p "$build_root/.cache"
export CLANG_MODULE_CACHE_PATH="$build_root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/.cache/swift-modules"
swift_binary="$(xcrun --find swift)"
toolchain="$(cd -- "$(dirname -- "$swift_binary")/.." && pwd)"
developer_root="$(xcode-select -p)"
testing_macros=""
for candidate in "$toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    "$toolchain/lib/swift/host/plugins/libTestingMacros.dylib"; do
    if [[ -f "$candidate" ]]; then testing_macros="$candidate"; break; fi
done
if [[ -z "$testing_macros" ]]; then
    printf 'Swift 6 with Swift Testing macros is required.\n' >&2; exit 1
fi
build_log="$build_root/landing-screenshots-build.log"
if ! "$swift_binary" test --disable-sandbox --disable-xctest --enable-swift-testing \
    --list-tests --cache-path "$build_root/.cache/swiftpm" --package-path "$repo_root/macos" \
    --scratch-path "$scratch" -debug-info-format none \
    -Xswiftc -load-plugin-library -Xswiftc "$testing_macros" >"$build_log" 2>&1; then
    cat "$build_log" >&2; exit 1
fi
swift_bin="$("$swift_binary" build --disable-sandbox --cache-path "$build_root/.cache/swiftpm" \
    --package-path "$repo_root/macos" --scratch-path "$scratch" --show-bin-path)"

# Use the same synchronous AppKit-compatible host as scripts/test.sh.
testing_frameworks=""
for candidate in "$toolchain/../Library/Developer/Frameworks" \
    "$developer_root/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
    "$developer_root/Library/Frameworks" "$toolchain/lib/swift/macosx"; do
    if [[ -d "$candidate/Testing.framework" ]]; then testing_frameworks="$candidate"; break; fi
done
if [[ -z "$testing_frameworks" ]]; then
    printf 'Testing.framework was not found in the active toolchain.\n' >&2; exit 1
fi
link_flags=(-F "$testing_frameworks" -framework Testing -Xlinker -rpath -Xlinker "$testing_frameworks")
for candidate in "$toolchain/../Library/Developer/usr/lib" \
    "$developer_root/Platforms/MacOSX.platform/Developer/usr/lib" \
    "$developer_root/usr/lib" "$toolchain/lib/swift/macosx"; do
    if [[ -f "$candidate/lib_TestingInterop.dylib" ]]; then
        link_flags+=(-L "$candidate" -Xlinker -rpath -Xlinker "$candidate")
    fi
done
# Native AppKit controls resolve NSAccentColorName and high-resolution support
# from Bundle.main. Give the capture host the actual built app's resources and
# metadata so a bare test executable cannot silently use the system accent.
capture_app="$build_root/DBeerScreenshotHost.app"
mkdir -p "$capture_app/Contents/MacOS" "$capture_app/Contents/Resources"
cp "$build_root/DBeer.app/Contents/Info.plist" "$capture_app/Contents/Info.plist"
cp -R "$build_root/DBeer.app/Contents/Resources/." "$capture_app/Contents/Resources/"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable DBeerScreenshotHost' "$capture_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.dbeer.screenshots' "$capture_app/Contents/Info.plist"
host="$capture_app/Contents/MacOS/DBeerScreenshotHost"
"$toolchain/bin/swiftc" -swift-version 6 -parse-as-library -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$build_root/.cache/test-host-modules" \
    "${link_flags[@]}" "$repo_root/scripts/SwiftTestingHost.swift" -o "$host"
export DBEER_TEST_BUNDLE_PATH="$swift_bin/DBeerTests.xctest/Contents/MacOS/DBeerTests"
export PACKAGE_RESOURCE_BUNDLE_PATH="$swift_bin"
export DBEER_CAPTURE_LANDING=1
export DBEER_QA_OUTPUT_DIR="${DBEER_QA_OUTPUT_DIR:-$build_root/qa/landing}"
results="$build_root/landing-screenshots.log"
"$host" --filter LandingScreenshotTests 2>&1 | tee "$results"
if ! grep -Eq 'Test run with 1 test .*passed after' "$results"; then
    printf 'Screenshot capture did not complete successfully.\n' >&2; exit 1
fi
printf 'Five real application screenshots saved in %s\n' "$DBEER_QA_OUTPUT_DIR"
