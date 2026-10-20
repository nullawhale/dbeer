#!/usr/bin/env bash
set -euo pipefail

# Both disposable servers are removed by their existing runners on every exit.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export DBEER_GPUI_DISPOSABLE_DATABASES=1
exec "$repo_root/scripts/test-postgres.sh" \
    "$repo_root/scripts/test-mysql.sh" \
    "$repo_root/scripts/gpui-prototype.sh" test --locked --features native-smoke -- --test-threads=1
