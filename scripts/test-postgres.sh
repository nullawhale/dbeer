#!/usr/bin/env bash
set -euo pipefail

# Run tests against a fresh database, without reading or changing saved profiles.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image="${DBEER_TEST_POSTGRES_IMAGE:-postgres:17}"
docker info >/dev/null
umask 077
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/dbeer-postgres.XXXXXX")"
container_id=""
cleanup() {
    if [[ -n "$container_id" ]]; then docker rm --force "$container_id" >/dev/null 2>&1 || true; fi
    rm -rf -- "$fixture_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
openssl rand -hex 32 >"$fixture_root/password"
printf 'Running real PostgreSQL checks with %s.\n' "$image"
container_id="$(docker run --detach --rm --publish 127.0.0.1::5432 \
    --mount "type=bind,source=$fixture_root,target=/fixtures,readonly" \
    --env POSTGRES_USER=dbeer --env POSTGRES_DB=dbeer \
    --env POSTGRES_PASSWORD_FILE=/fixtures/password "$image")"
ready=0
for ((attempt = 0; attempt < 60; attempt++)); do
    if docker exec "$container_id" pg_isready --host 127.0.0.1 --username dbeer --dbname dbeer >/dev/null 2>&1; then
        ready=1; break
    fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" != true ]]; then
        printf 'PostgreSQL test container exited before becoming ready.\n' >&2; exit 1
    fi
    sleep 1
done
if [[ "$ready" != 1 ]]; then printf 'PostgreSQL test container did not become ready.\n' >&2; exit 1; fi
port_mapping="$(docker port "$container_id" 5432/tcp)"
export DBEER_TEST_DSN="postgresql://dbeer:$(cat "$fixture_root/password")@127.0.0.1:${port_mapping##*:}/dbeer?sslmode=disable"
export DBEER_REQUIRE_POSTGRES=1
if [[ "$#" -gt 0 ]]; then "$@"; else "$repo_root/scripts/test-go.sh" --require-postgres; fi
