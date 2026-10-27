#!/usr/bin/env bash
set -euo pipefail

# Explicit native UI acceptance against four disposable database servers. The
# native suite seeds its SQL/CQL tables through the production helper; MongoDB
# requires mongosh because the application deliberately exposes no CRUD script.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
umask 077
if [[ "${DBEER_TABLE_BROWSE_UI_FIXTURE:-0}" != 1 ]]; then
    export DBEER_TEST_POSTGRES_IMAGE=postgres:17
    export DBEER_TEST_MYSQL_IMAGE=mysql:8.4
    export DBEER_TEST_MONGODB_IMAGE=mongo:8.0
    exec "$repo_root/scripts/test-postgres.sh" \
        "$repo_root/scripts/test-mysql.sh" \
        "$repo_root/scripts/test-cassandra.sh" --version 5.0 --mode plain -- \
        "$repo_root/scripts/test-mongodb.sh" --mode plain -- \
        env DBEER_TABLE_BROWSE_UI_FIXTURE=1 DBEER_TABLE_BROWSE_UI_QA=1 \
            DBEER_TABLE_BROWSE_UI_DISPOSABLE=1 "$0" "$@"
fi

[[ "${DBEER_TABLE_BROWSE_UI_QA:-0}" == 1 &&
   "${DBEER_TABLE_BROWSE_UI_DISPOSABLE:-0}" == 1 &&
   "${DBEER_REQUIRE_POSTGRES:-0}" == 1 && -n "${DBEER_TEST_DSN:-}" &&
   "${DBEER_REQUIRE_MYSQL:-0}" == 1 && -n "${DBEER_TEST_MYSQL_PORT:-}" &&
   "${DBEER_REQUIRE_CASSANDRA:-0}" == 1 && -n "${DBEER_TEST_CASSANDRA_PORT:-}" &&
   "${DBEER_TEST_CASSANDRA_VERSION:-}" == 5.0 &&
   "${DBEER_TEST_CASSANDRA_SSLMODE:-}" == disable &&
   "${DBEER_REQUIRE_MONGODB:-0}" == 1 && -n "${DBEER_TEST_MONGODB_CONTAINER:-}" &&
   "${DBEER_TEST_MONGODB_SSLMODE:-}" == disable ]] || {
    printf 'Isolated PostgreSQL 17, MySQL 8.4, Cassandra 5.0 and MongoDB 8.0 fixtures are required.\n' >&2
    exit 1
}

docker exec --interactive "$DBEER_TEST_MONGODB_CONTAINER" bash -c \
    'exec mongosh --quiet --host localhost --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' \
    < "$repo_root/protocol/fixtures/table-browse-ui-seed.js" >/dev/null
export DBEER_TEST_MONGODB_DATABASE=dbeer_browse_ui
export DBEER_QA_OUTPUT_DIR="${DBEER_QA_OUTPUT_DIR:-$repo_root/build/table-browse-ui}"
export DBEER_TABLE_BROWSE_UI_HELPER="$repo_root/build/DBeer.app/Contents/Helpers/dbeer-core"
mkdir -p "$DBEER_QA_OUTPUT_DIR" "$repo_root/build/Contents/Helpers"
chmod 700 "$DBEER_QA_OUTPUT_DIR"

# The synchronous native test host uses build/ as its main bundle. Mirror the
# application's helper layout without replacing a pre-existing helper or link.
helper_link="$repo_root/build/Contents/Helpers/dbeer-core"
created_helper_link=0
if [[ ! -e "$helper_link" && ! -L "$helper_link" ]]; then
    ln -s ../../DBeer.app/Contents/Helpers/dbeer-core "$helper_link"
    created_helper_link=1
fi
cleanup() { if [[ "$created_helper_link" == 1 ]]; then rm -f -- "$helper_link"; fi; }
trap cleanup EXIT

native_arguments=(--filter TableBrowseUIIntegrationTests --filter TableBrowseUIBoundaryTests)
if [[ "$#" -gt 0 ]]; then native_arguments=("$@"); fi
CONFIGURATION=debug "$repo_root/scripts/test.sh" "${native_arguments[@]}" \
    2>&1 | tee "$DBEER_QA_OUTPUT_DIR/native.log"
