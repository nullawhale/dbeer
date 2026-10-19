#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="$repo_root/build"
usage() {
    cat <<'USAGE'
Usage: scripts/test.sh --filter pattern [--filter pattern ...] [--require-postgres]
       scripts/test.sh --all [--require-postgres]

  --filter pattern    Run matching native Swift tests only (regular expression).
  --all               Explicitly run the full Go race and native Swift suites.
  --require-postgres  Fail if DBEER_TEST_DSN is missing.

Examples:
  ./scripts/test.sh --filter SQLScriptParserTests
  ./scripts/test.sh --filter 'SQLEditorTests/executionHighlight'
  ./scripts/test.sh --all

No tests run without an explicit scope. Theme checks run when selected or with --all.
USAGE
}
original_arguments=("$@")
run_all=0
swift_filters=()
require_postgres="${DBEER_REQUIRE_POSTGRES:-0}"
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --all) run_all=1; shift ;;
        --filter)
            if [[ "$#" -lt 2 || -z "$2" || "$2" == --* ]]; then
                printf '%s\n' '--filter requires a nonempty pattern.' >&2
                exit 2
            fi
            swift_filters+=(--filter "$2")
            shift 2
            ;;
        --require-postgres) require_postgres=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if [[ "$run_all" == 0 && "${#swift_filters[@]}" == 0 ]]; then
    usage >&2
    exit 2
fi
if [[ "$run_all" == 1 && "${#swift_filters[@]}" -gt 0 ]]; then
    printf '%s\n' 'Choose either --all or --filter, not both.' >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    printf 'Native DBeer tests require an Apple Silicon Mac; use scripts/test-go.sh on Linux.\n' >&2
    exit 1
fi
if [[ "$require_postgres" == 1 ]]; then
    export DBEER_REQUIRE_POSTGRES=1
    if [[ -z "${DBEER_TEST_DSN:-}" ]]; then
        printf 'PostgreSQL is required, but DBEER_TEST_DSN is missing. No tests were run.\n' >&2
        exit 1
    fi
fi
if [[ -z "${DBEER_TEST_KEYCHAIN_PATH:-}" ]]; then
    exec "$repo_root/scripts/with-test-keychain.sh" "$0" "${original_arguments[@]}"
fi

mkdir -p "$build_root/.cache"
export GOCACHE="$build_root/.cache/go"
export GOMODCACHE="$build_root/.cache/go-mod"
export CLANG_MODULE_CACHE_PATH="$build_root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/.cache/swift-modules"

swift_binary="$(xcrun --find swift)"
swift_toolchain="$(cd -- "$(dirname -- "$swift_binary")/.." && pwd)"
testing_macros=""
for candidate in \
    "$swift_toolchain/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    "$swift_toolchain/lib/swift/host/plugins/libTestingMacros.dylib"; do
    if [[ -f "$candidate" ]]; then
        testing_macros="$candidate"
        break
    fi
done
if [[ -z "$testing_macros" ]]; then
    printf 'Swift Testing macros were not found in the active toolchain. Use Swift 6 Command Line Tools or Xcode with Swift Testing.\n' >&2
    exit 1
fi

# The real-process lifecycle test needs the bundled helper.
"$repo_root/scripts/build-app.sh"

if [[ "$run_all" == 1 ]]; then
    printf 'Running full Go race and native Swift suites (--all).\n'
    "$repo_root/scripts/test-go.sh"
else
    printf 'Running selected native Swift tests; Go suite is skipped.\n'
fi

# Discover/build without running AppKit in SwiftPM's async-main test host.
# Swift's CFMainExecutor may exit(0) after AppKit stops the main run loop
# (https://github.com/swiftlang/swift/issues/91716), leaving tests unfinished.
swift_build_log="$build_root/swift-test-build.log"
if ! "$swift_binary" test --disable-sandbox --disable-xctest --enable-swift-testing \
    --list-tests --cache-path "$build_root/.cache/swiftpm" \
    --package-path "$repo_root/macos" --scratch-path "$build_root/swift" \
    -debug-info-format none \
    -Xswiftc -load-plugin-library -Xswiftc "$testing_macros" >"$swift_build_log" 2>&1; then
    cat "$swift_build_log" >&2
    exit 1
fi
swift_bin="$("$swift_binary" build --disable-sandbox --cache-path "$build_root/.cache/swiftpm" \
    --package-path "$repo_root/macos" --scratch-path "$build_root/swift" --show-bin-path)"
test_bundle=""
bundle_count=0
for candidate in "$swift_bin"/*.xctest/Contents/MacOS/*; do
    if [[ -f "$candidate" && -x "$candidate" ]]; then
        test_bundle="$candidate"
        bundle_count=$((bundle_count + 1))
    fi
done
if [[ "$bundle_count" != 1 ]]; then
    printf 'Expected exactly one native test bundle in %s.\n' "$swift_bin" >&2
    exit 1
fi

# Locate the active toolchain's runtime for both CLT and full Xcode layouts.
developer_root="$(xcode-select -p)"
testing_frameworks=""
for candidate in \
    "$swift_toolchain/../Library/Developer/Frameworks" \
    "$developer_root/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
    "$developer_root/Library/Frameworks" \
    "$swift_toolchain/lib/swift/macosx"; do
    if [[ -d "$candidate/Testing.framework" ]]; then testing_frameworks="$candidate"; break; fi
done
if [[ -z "$testing_frameworks" ]]; then
    printf 'The active Swift toolchain does not contain Testing.framework.\n' >&2
    exit 1
fi
host_link_flags=(-F "$testing_frameworks" -framework Testing -Xlinker -rpath -Xlinker "$testing_frameworks")
for candidate in \
    "$swift_toolchain/../Library/Developer/usr/lib" \
    "$developer_root/Platforms/MacOSX.platform/Developer/usr/lib" \
    "$developer_root/usr/lib" \
    "$swift_toolchain/lib/swift/macosx"; do
    if [[ -f "$candidate/lib_TestingInterop.dylib" ]]; then
        host_link_flags+=(-L "$candidate" -Xlinker -rpath -Xlinker "$candidate")
    fi
done
# AppKit/SwiftUI choose their control implementation from the executable's
# linked SDK. Match the app, so native popup geometry is tested in the UI that
# users actually run rather than only the current SDK's newer control style.
app_sdk="$(xcrun vtool -show-build "$build_root/DBeer.app/Contents/MacOS/DBeer" | awk '$1 == "sdk" { print $2; exit }')"
host_link_flags+=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$app_sdk")
native_host="$build_root/dbeer-testing-host"
"$swift_toolchain/bin/swiftc" -swift-version 6 -parse-as-library \
    -target arm64-apple-macosx14.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$build_root/.cache/test-host-modules" \
    "${host_link_flags[@]}" "$repo_root/scripts/SwiftTestingHost.swift" -o "$native_host"
export DBEER_TEST_BUNDLE_PATH="$test_bundle"
export PACKAGE_RESOURCE_BUNDLE_PATH="$swift_bin"

swift_results="$(mktemp "$build_root/.swift-results.XXXXXX")"
trap 'rm -f "$swift_results"' EXIT
if [[ "$run_all" == 1 ]]; then
    "$native_host" 2>&1 | tee "$swift_results"
else
    "$native_host" "${swift_filters[@]}" 2>&1 | tee "$swift_results"
fi
# Exit status alone must never turn an incomplete test run into a green CI job.
if ! grep -Eq 'Test run with [1-9][0-9]* tests? .*passed after' "$swift_results"; then
    printf 'Swift Testing did not report a completed nonempty run. Check the filter and test output.\n' >&2
    exit 1
fi
