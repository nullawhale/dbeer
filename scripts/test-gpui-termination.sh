#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'The native Dock termination checks require macOS.\n' >&2
    exit 1
fi

# The existing runners own and remove both isolated database servers.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${DBEER_GPUI_DISPOSABLE_DATABASES:-}" != 1 ]]; then
    export DBEER_GPUI_DISPOSABLE_DATABASES=1
    exec "$repo_root/scripts/test-postgres.sh" \
        "$repo_root/scripts/test-mysql.sh" "$0"
fi

export DBEER_GPUI_HELPER_PATH="$repo_root/build/gpui/dbeer-core"
"$repo_root/scripts/gpui-prototype.sh" build --locked --features native-smoke
exec "$repo_root/build/gpui/target/debug/dbeer-gpui" --termination-smoke-suite
