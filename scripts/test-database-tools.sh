#!/usr/bin/env bash
set -euo pipefail

# Real version-matched native utility checks, without installing clients or
# reading saved profiles on the development machine.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
engine="${1:-all}"
if [[ "$engine" != all && "$engine" != postgresql && "$engine" != mysql ]]; then
    printf 'Usage: %s [all|postgresql|mysql]\n' "$0" >&2
    exit 2
fi
for dependency in docker go openssl; do
    command -v "$dependency" >/dev/null || { printf 'Database utility checks require %s.\n' "$dependency" >&2; exit 1; }
done
docker info >/dev/null
architecture="$(docker info --format '{{.Architecture}}')"
case "$architecture" in
    arm64|aarch64) architecture=arm64 ;;
    amd64|x86_64) architecture=amd64 ;;
    *) printf 'Unsupported Docker architecture.\n' >&2; exit 1 ;;
esac
umask 077
mkdir -p "$repo_root/build/database-tools-tests"
fixture_root="$(mktemp -d "$repo_root/build/database-tools-tests/run.XXXXXX")"
container_id=""
cleanup() {
    if [[ -n "$container_id" ]]; then docker rm --force "$container_id" >/dev/null 2>&1 || true; fi
    rm -rf -- "$fixture_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export GOCACHE="${GOCACHE:-$repo_root/build/.cache/go}"
export GOMODCACHE="${GOMODCACHE:-$repo_root/build/.cache/go-mod}"
GOOS=linux GOARCH="$architecture" CGO_ENABLED=0 go -C "$repo_root/helper" test -c \
    -o "$fixture_root/database-tools.test" ./internal/dbtools
chmod 755 "$fixture_root/database-tools.test"
openssl rand -hex 32 >"$fixture_root/password"
openssl rand -hex 32 >"$fixture_root/root-password"

run_postgres() {
    local image="${DBEER_TEST_POSTGRES_IMAGE:-postgres:17}"
    printf 'Running database utility roundtrips with %s.\n' "$image"
    container_id="$(docker run --detach --rm \
        --mount "type=bind,source=$fixture_root,target=/fixtures,readonly" \
        --env POSTGRES_USER=dbeer --env POSTGRES_DB=dbeer \
        --env POSTGRES_PASSWORD_FILE=/fixtures/password "$image")"
    local ready=0
    for ((attempt=0; attempt<90; attempt++)); do
        if docker exec "$container_id" pg_isready --host=127.0.0.1 --username=dbeer --dbname=dbeer >/dev/null 2>&1; then ready=1; break; fi
        if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" != true ]]; then break; fi
        sleep 1
    done
    if [[ "$ready" != 1 ]]; then printf 'PostgreSQL utility fixture did not become ready.\n' >&2; return 1; fi
    local tool_bin
    tool_bin="$(docker exec "$container_id" sh -ec 'dirname "$(command -v pg_dump)"')"
    docker exec --env DBEER_DBTOOLS_TEST_ENGINE=postgresql \
        --env DBEER_DBTOOLS_TEST_PASSWORD_FILE=/fixtures/password \
        --env "DBEER_DBTOOLS_TEST_BIN=$tool_bin" "$container_id" \
        /fixtures/database-tools.test -test.v -test.run '^TestDatabaseToolsRealDumpRestoreRoundTrip$'
    docker rm --force "$container_id" >/dev/null
    container_id=""
}
run_mysql() {
    local image="${DBEER_TEST_MYSQL_IMAGE:-mysql:8.4}"
    printf 'Running database utility roundtrips with %s.\n' "$image"
    container_id="$(docker run --detach --rm \
        --mount "type=bind,source=$fixture_root,target=/fixtures,readonly" \
        --env MYSQL_USER=dbeer --env MYSQL_DATABASE=dbeer \
        --env MYSQL_PASSWORD_FILE=/fixtures/password \
        --env MYSQL_ROOT_PASSWORD_FILE=/fixtures/root-password "$image")"
    local ready=0
    for ((attempt=0; attempt<120; attempt++)); do
        if docker exec "$container_id" sh -ec '
            MYSQL_PWD="$(cat /fixtures/password)" mysql --host=127.0.0.1 --user=dbeer \
                --database=dbeer --silent --skip-column-names --execute="SELECT 1"
        ' >/dev/null 2>&1; then ready=1; break; fi
        if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" != true ]]; then break; fi
        sleep 1
    done
    if [[ "$ready" != 1 ]]; then printf 'MySQL utility fixture did not become ready.\n' >&2; return 1; fi
    local tool_bin
    tool_bin="$(docker exec "$container_id" sh -ec 'dirname "$(command -v mysql)"')"
    docker exec --env DBEER_DBTOOLS_TEST_ENGINE=mysql \
        --env DBEER_DBTOOLS_TEST_PASSWORD_FILE=/fixtures/password \
        --env "DBEER_DBTOOLS_TEST_BIN=$tool_bin" "$container_id" \
        /fixtures/database-tools.test -test.v -test.run '^TestDatabaseToolsRealDumpRestoreRoundTrip$'
    docker rm --force "$container_id" >/dev/null
    container_id=""
}
if [[ "$engine" == all || "$engine" == postgresql ]]; then run_postgres; fi
if [[ "$engine" == all || "$engine" == mysql ]]; then run_mysql; fi
