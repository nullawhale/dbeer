#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
local_toolchain="$repo_root/build/gpui/toolchain"
if command -v cargo >/dev/null 2>&1; then
    cargo_bin="$(command -v cargo)"
elif [[ -x "$local_toolchain/cargo/bin/cargo" ]]; then
    cargo_bin="$local_toolchain/cargo/bin/cargo"
    export RUSTUP_HOME="$local_toolchain/rustup"
    export PATH="$local_toolchain/cargo/bin:$PATH"
else
    printf 'Rust 1.92+ is required. Install it from https://rustup.rs, then rerun this script.\n' >&2
    exit 1
fi

export CARGO_HOME="${CARGO_HOME:-$repo_root/build/gpui/cargo}"
command="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi
# Product candidates use the paired native driver. Never let a development
# wrapper replace their helper or reuse their marked test artifacts.
if [[ -n "${DBEER_PRODUCT_BUILD_IDENTITY:-}" || -n "${DBEER_PRODUCT_NATIVE_RESOURCES:-}" ||
      -n "${DBEER_PRODUCT_IDENTITY_FILE:-}" || -n "${DBEER_PRODUCT_BUILD_PYTHON:-}" ]]; then
    printf 'Use build-gpui-client.sh/.ps1 for marked native product builds.\n' >&2
    exit 2
fi
if [[ "$command" == test ]]; then
    default_target="$repo_root/build/gpui/verification-target"
else
    default_target="$repo_root/build/gpui/target"
fi
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$default_target}"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) export CARGO_TARGET_DIR="$(cygpath -u "$CARGO_TARGET_DIR")" ;;
esac
# Validate before mkdir so an invalid output selection creates nothing elsewhere.
case "$CARGO_TARGET_DIR" in
    /*) target_candidate="$CARGO_TARGET_DIR" ;;
    *) target_candidate="$PWD/$CARGO_TARGET_DIR" ;;
esac
case "$target_candidate" in
    "$repo_root"/build/*) ;;
    *) printf 'GPUI build outputs must remain under the repository build/ directory.\n' >&2; exit 2 ;;
esac
case "/$target_candidate/" in
    */../*) printf 'GPUI output paths cannot contain parent traversal.\n' >&2; exit 2 ;;
esac
target_ancestor="$target_candidate"
while [[ ! -d "$target_ancestor" ]]; do
    if [[ -e "$target_ancestor" || -L "$target_ancestor" ]]; then
        printf 'GPUI output ancestry must contain directories.\n' >&2; exit 2
    fi
    target_ancestor="$(dirname -- "$target_ancestor")"
done
target_ancestor="$(cd -- "$target_ancestor" && pwd -P)"
case "$target_ancestor" in
    "$repo_root"|"$repo_root"/build|"$repo_root"/build/*) ;;
    *) printf 'GPUI output ancestry resolves outside build/.\n' >&2; exit 2 ;;
esac
mkdir -p "$CARGO_TARGET_DIR"
export CARGO_TARGET_DIR="$(cd -- "$CARGO_TARGET_DIR" && pwd -P)"
case "$CARGO_TARGET_DIR" in
    "$repo_root"/build/*) ;;
    *) printf 'GPUI build outputs must remain under the repository build/ directory.\n' >&2; exit 2 ;;
esac
helper_name=dbeer-core
case "$(uname -s)" in
    Darwin) export MACOSX_DEPLOYMENT_TARGET=15.0 ;;
    MINGW*|MSYS*|CYGWIN*) helper_name=dbeer-core.exe ;;
esac
if [[ "$CARGO_TARGET_DIR" == "$repo_root/build/gpui/target" ]]; then
    default_helper="$repo_root/build/gpui/$helper_name"
else
    default_helper="$CARGO_TARGET_DIR/$helper_name"
fi
case "$command" in
    run|build|test)
        export GOCACHE="$repo_root/build/.cache/go"
        export GOMODCACHE="$repo_root/build/.cache/go-mod"
        mkdir -p "$repo_root/build/gpui" "$repo_root/build/.cache"
        if [[ -n "${DBEER_GPUI_HELPER_PATH:-}" ]]; then
            if [[ ! -f "$DBEER_GPUI_HELPER_PATH" || ! -x "$DBEER_GPUI_HELPER_PATH" ]]; then
                printf 'The explicitly selected GPUI helper must already be an executable regular file.\n' >&2
                exit 2
            fi
        else
            export DBEER_GPUI_HELPER_PATH="$default_helper"
            (
                cd "$repo_root/helper"
                go build -trimpath -o "$DBEER_GPUI_HELPER_PATH" ./cmd/dbeer-core
            )
        fi
        exec "$cargo_bin" "$command" --manifest-path "$repo_root/prototypes/gpui/Cargo.toml" "$@"
        ;;
    check|clippy)
        exec "$cargo_bin" "$command" --manifest-path "$repo_root/prototypes/gpui/Cargo.toml" "$@"
        ;;
    fmt)
        exec "$cargo_bin" fmt --manifest-path "$repo_root/prototypes/gpui/Cargo.toml" "$@"
        ;;
    *)
        printf 'Usage: %s [run|build|check|test|clippy|fmt] [cargo options]\n' "$0" >&2
        exit 2
        ;;
esac
