#!/usr/bin/env bash
set -euo pipefail

# A real PostgreSQL TLS fixture, also used by the required Linux CI matrix.
# Everything sensitive is generated for this run and removed on exit.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image="${DBEER_TEST_POSTGRES_IMAGE:-postgres:17}"
for dependency in docker openssl go; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'TLS checks require %s.\n' "$dependency" >&2
        exit 1
    fi
done
docker info >/dev/null
umask 077
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/dbeer-tls.XXXXXX")"
container_id=""
cleanup() {
    if [[ -n "$container_id" ]]; then
        docker rm --force "$container_id" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$fixture_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$fixture_root/server"

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj '/CN=DBeer temporary test CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$fixture_root/ca.key" -out "$fixture_root/ca.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -subj '/CN=localhost' -keyout "$fixture_root/server/server.key" \
    -out "$fixture_root/server.csr" >/dev/null 2>&1
cat >"$fixture_root/server.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost
EOF
openssl x509 -req -sha256 -days 1 -in "$fixture_root/server.csr" \
    -CA "$fixture_root/ca.crt" -CAkey "$fixture_root/ca.key" -CAcreateserial \
    -extfile "$fixture_root/server.ext" -out "$fixture_root/server/server.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj '/CN=DBeer unrelated temporary CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$fixture_root/untrusted.key" -out "$fixture_root/untrusted.crt" >/dev/null 2>&1
openssl rand -hex 32 >"$fixture_root/server/password"

printf 'Running real PostgreSQL TLS checks with %s.\n' "$image"
container_id="$(docker run --detach --rm \
    --publish 127.0.0.1::5432 \
    --mount "type=bind,source=$fixture_root/server,target=/fixtures,readonly" \
    --env POSTGRES_USER=dbeer_tls --env POSTGRES_DB=dbeer_tls \
    --env POSTGRES_PASSWORD_FILE=/fixtures/password \
    --entrypoint sh "$image" -ec '
        mkdir /tmp/dbeer-tls
        cp /fixtures/server.crt /fixtures/server.key /tmp/dbeer-tls/
        chown -R postgres:postgres /tmp/dbeer-tls
        chmod 600 /tmp/dbeer-tls/server.key
        exec docker-entrypoint.sh postgres -c ssl=on \
            -c ssl_cert_file=/tmp/dbeer-tls/server.crt \
            -c ssl_key_file=/tmp/dbeer-tls/server.key
    ')"
ready=0
for ((attempt = 0; attempt < 60; attempt++)); do
    if docker exec "$container_id" pg_isready --host 127.0.0.1 --username dbeer_tls --dbname dbeer_tls >/dev/null 2>&1; then
        ready=1
        break
    fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" != true ]]; then
        printf 'TLS PostgreSQL container exited before it was ready.\n' >&2
        exit 1
    fi
    sleep 1
done
if [[ "$ready" != 1 ]]; then
    printf 'TLS PostgreSQL container did not become ready.\n' >&2
    exit 1
fi
port_mapping="$(docker port "$container_id" 5432/tcp)"
export DBEER_TEST_TLS_PORT="${port_mapping##*:}"
export DBEER_TEST_TLS_CA_FILE="$fixture_root/ca.crt"
export DBEER_TEST_TLS_UNTRUSTED_CA_FILE="$fixture_root/untrusted.crt"
export DBEER_TEST_TLS_PASSWORD_FILE="$fixture_root/server/password"
export DBEER_REQUIRE_TLS_TESTS=1
export GOCACHE="${GOCACHE:-$repo_root/build/.cache/go}"
export GOMODCACHE="${GOMODCACHE:-$repo_root/build/.cache/go-mod}"
cd "$repo_root/helper"
go test -race -count=1 -run '^TestPostgresTLS' -v ./internal/postgres
