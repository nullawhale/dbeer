#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    printf 'Package the DBeer Ubuntu x64 client natively on Linux. The macOS product uses build-app.sh.\n' >&2
    exit 1
fi
exec python3 -B "$repo_root/prototypes/gpui/packaging/package.py" package --target linux-x86_64-gnu "$@"
