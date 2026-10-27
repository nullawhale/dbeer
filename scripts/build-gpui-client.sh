#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    printf 'Build DBeer natively on Ubuntu 24.04 x64. Windows uses build-gpui-client.ps1; macOS uses build-app.sh (SwiftUI).\n' >&2
    exit 1
fi
arguments=()
for argument in "$@"; do
    case "$argument" in
        --test|--package) arguments+=("$argument") ;;
        *) printf 'Usage: %s [--test] [--package]\n' "$0" >&2; exit 2 ;;
    esac
done
exec python3 -B "$repo_root/prototypes/gpui/packaging/build.py" --target linux-x86_64-gnu "${arguments[@]}"
