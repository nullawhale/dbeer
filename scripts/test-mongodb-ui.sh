#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${DBEER_MONGODB_UI_FIXTURE:-0}" != 1 ]]; then
    mode="${1:-plain}"
    [[ "$mode" == plain || "$mode" == tls ]] || { printf 'Use plain or tls.\n' >&2; exit 2; }
    exec "$repo_root/scripts/test-mongodb.sh" --mode "$mode" -- env DBEER_MONGODB_UI_FIXTURE=1 "$0"
fi

[[ -n "${DBEER_TEST_MONGODB_CONTAINER:-}" ]] || { printf 'An isolated MongoDB fixture is required.\n' >&2; exit 1; }
tls_options=()
if [[ "$DBEER_TEST_MONGODB_SSLMODE" == verify-full ]]; then tls_options=(--tls --tlsCAFile /fixture/ca.crt); fi
docker exec --interactive "$DBEER_TEST_MONGODB_CONTAINER" bash -c \
    'exec mongosh --quiet --host localhost --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin "$@"' \
    _ ${tls_options[@]+"${tls_options[@]}"} < "$repo_root/protocol/fixtures/mongodb-ui-seed.js" >/dev/null

export DBEER_TEST_MONGODB_DATABASE=dbeer_mongodb_ui
export DBEER_QA_OUTPUT_DIR="$repo_root/build/mongodb-ui/$DBEER_TEST_MONGODB_SSLMODE"
mkdir -p "$DBEER_QA_OUTPUT_DIR" "$repo_root/build/Contents/Helpers"
# The synchronous native test host uses build/ as its main bundle. Give its
# production views the same default bundled-helper layout as DBeer.app.
helper_link="$repo_root/build/Contents/Helpers/dbeer-core"
created_helper_link=0
if [[ ! -e "$helper_link" && ! -L "$helper_link" ]]; then
    ln -s ../../DBeer.app/Contents/Helpers/dbeer-core "$helper_link"
    created_helper_link=1
fi
cleanup() { if [[ "$created_helper_link" == 1 ]]; then rm -f -- "$helper_link"; fi; }
trap cleanup EXIT
CONFIGURATION=debug "$repo_root/scripts/test.sh" --filter MongoDBUIIntegrationTests --filter MongoDBTests
