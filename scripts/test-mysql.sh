#!/usr/bin/env bash
set -euo pipefail

# A disposable MySQL server with its own short-lived CA and random passwords.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image="${DBEER_TEST_MYSQL_IMAGE:-mysql:8.4}"
for dependency in docker openssl go; do
    command -v "$dependency" >/dev/null || { printf 'MySQL checks require %s.\n' "$dependency" >&2; exit 1; }
done
docker info >/dev/null
umask 077
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/dbeer-mysql.XXXXXX")"
container_id=""
cleanup() {
    if [[ -n "$container_id" ]]; then docker rm --force "$container_id" >/dev/null 2>&1 || true; fi
    rm -rf -- "$fixture_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$fixture_root/server"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj '/CN=DBeer temporary MySQL CA' -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$fixture_root/ca.key" -out "$fixture_root/server/ca.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -sha256 -subj '/CN=localhost' \
    -keyout "$fixture_root/server/server.key" -out "$fixture_root/server.csr" >/dev/null 2>&1
cat >"$fixture_root/server.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost
EOF
openssl x509 -req -sha256 -days 1 -in "$fixture_root/server.csr" \
    -CA "$fixture_root/server/ca.crt" -CAkey "$fixture_root/ca.key" -CAcreateserial \
    -extfile "$fixture_root/server.ext" -out "$fixture_root/server/server.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj '/CN=DBeer unrelated MySQL CA' -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$fixture_root/untrusted.key" -out "$fixture_root/untrusted.crt" >/dev/null 2>&1
openssl rand -hex 32 >"$fixture_root/server/password"
openssl rand -hex 32 >"$fixture_root/server/root-password"

printf 'Running real MySQL checks with %s.\n' "$image"
container_id="$(docker run --detach --rm --publish 127.0.0.1::3306 \
    --mount "type=bind,source=$fixture_root/server,target=/fixtures,readonly" \
    --env MYSQL_USER=dbeer --env MYSQL_DATABASE=dbeer \
    --env MYSQL_PASSWORD_FILE=/fixtures/password --env MYSQL_ROOT_PASSWORD_FILE=/fixtures/root-password \
    --entrypoint sh "$image" -ec '
        mkdir /tmp/dbeer-tls
        cp /fixtures/ca.crt /fixtures/server.crt /fixtures/server.key /tmp/dbeer-tls/
        chown -R mysql:mysql /tmp/dbeer-tls
        chmod 600 /tmp/dbeer-tls/server.key
        exec docker-entrypoint.sh mysqld --ssl-ca=/tmp/dbeer-tls/ca.crt \
            --ssl-cert=/tmp/dbeer-tls/server.crt --ssl-key=/tmp/dbeer-tls/server.key --local-infile=OFF \
            --log-bin-trust-function-creators=ON
    ')"
ready=0
for ((attempt = 0; attempt < 120; attempt++)); do
    if docker exec "$container_id" sh -ec '
        MYSQL_PWD="$(cat /fixtures/password)" mysql --host=127.0.0.1 --user=dbeer \
            --database=dbeer --silent --skip-column-names --execute="SELECT 1"
    ' >/dev/null 2>&1; then ready=1; break; fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" != true ]]; then
        printf 'MySQL test container exited before becoming ready.\n' >&2; exit 1
    fi
    sleep 1
done
if [[ "$ready" != 1 ]]; then printf 'MySQL test container did not become ready.\n' >&2; exit 1; fi
port_mapping="$(docker port "$container_id" 3306/tcp)"
export DBEER_TEST_MYSQL_HOST=localhost DBEER_TEST_MYSQL_PORT="${port_mapping##*:}"
export DBEER_TEST_MYSQL_USER=dbeer DBEER_TEST_MYSQL_DATABASE=dbeer
export DBEER_TEST_MYSQL_PASSWORD="$(cat "$fixture_root/server/password")"
export DBEER_TEST_MYSQL_SSLMODE=disable
export DBEER_TEST_MYSQL_CA_FILE="$fixture_root/server/ca.crt"
export DBEER_TEST_MYSQL_UNTRUSTED_CA_FILE="$fixture_root/untrusted.crt"
export DBEER_REQUIRE_MYSQL=1 DBEER_REQUIRE_MYSQL_TLS=1
export GOCACHE="${GOCACHE:-$repo_root/build/.cache/go}"
export GOMODCACHE="${GOMODCACHE:-$repo_root/build/.cache/go-mod}"
if [[ "$#" -gt 0 ]]; then
    "$@"
else
    cd "$repo_root/helper"
    go test -race -count=1 -p 1 ./...
fi
