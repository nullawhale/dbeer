#!/usr/bin/env bash
set -euo pipefail

# Explicit native UI acceptance using fresh PostgreSQL/MySQL fixtures only.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${DBEER_R22_UI_FIXTURE:-0}" != 1 ]]; then
    exec "$repo_root/scripts/test-postgres.sh" "$repo_root/scripts/test-mysql.sh" \
        env DBEER_R22_UI_FIXTURE=1 DBEER_R22_UI_QA=1 DBEER_R22_UI_DISPOSABLE=1 "$0"
fi
[[ "${DBEER_R22_UI_QA:-0}" == 1 && "${DBEER_R22_UI_DISPOSABLE:-0}" == 1 &&
   -n "${DBEER_TEST_DSN:-}" && -n "${DBEER_TEST_MYSQL_PORT:-}" ]] || {
    printf 'Isolated PostgreSQL and MySQL fixtures are required.\n' >&2; exit 1;
}
export DBEER_QA_OUTPUT_DIR="${DBEER_QA_OUTPUT_DIR:-$repo_root/build/r22-ui}"
mkdir -p "$DBEER_QA_OUTPUT_DIR" "$repo_root/build/Contents/Helpers"
helper_link="$repo_root/build/Contents/Helpers/dbeer-core"
created_helper_link=0
if [[ ! -e "$helper_link" && ! -L "$helper_link" ]]; then
    ln -s ../../DBeer.app/Contents/Helpers/dbeer-core "$helper_link"
    created_helper_link=1
fi
cleanup() { if [[ "$created_helper_link" == 1 ]]; then rm -f -- "$helper_link"; fi; }
trap cleanup EXIT
CONFIGURATION=debug "$repo_root/scripts/test.sh" --filter SQLResultSourceUIIntegrationTests --filter SQLResultSourceTests --filter ResultGridRowNumberTests
