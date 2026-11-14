#!/usr/bin/env bash
set -euo pipefail

# A disposable MariaDB server with private credentials and an explicit test CA.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
image="${DBEER_TEST_MARIADB_IMAGE:-mariadb:11.4}"
for dependency in docker openssl go; do
    command -v "$dependency" >/dev/null || { printf 'MariaDB checks require %s.\n' "$dependency" >&2; exit 1; }
done
docker info >/dev/null
umask 077
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/dbeer-mariadb.XXXXXX")"
container_id=""
tool_label="${fixture_root##*/}"
tool_image="${DBEER_TEST_MARIADB_TOOLS_IMAGE:-mariadb:11.4}"
cleanup() {
    while IFS= read -r client_id; do
        if [[ -n "$client_id" ]]; then docker rm --force "$client_id" >/dev/null 2>&1 || true; fi
    done < <(docker ps --all --quiet --filter "label=dbeer.mariadb.tools=$tool_label")
    if [[ -n "$container_id" ]]; then docker rm --force "$container_id" >/dev/null 2>&1 || true; fi
    rm -rf -- "$fixture_root"
    if [[ -n "${DBEER_TEST_MARIADB_CLEANUP_RECEIPT:-}" ]]; then
        local container_removed=true directory_removed=true clients_removed=true
        if [[ -n "$container_id" ]] && docker inspect "$container_id" >/dev/null 2>&1; then container_removed=false; fi
        if [[ -e "$fixture_root" ]]; then directory_removed=false; fi
        if [[ -n "$(docker ps --all --quiet --filter "label=dbeer.mariadb.tools=$tool_label")" ]]; then clients_removed=false; fi
        printf '{"ownedContainerRemoved":%s,"credentialDirectoryRemoved":%s,"ownedUtilityContainersRemoved":%s}\n' "$container_removed" "$directory_removed" "$clients_removed" >"$DBEER_TEST_MARIADB_CLEANUP_RECEIPT"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$fixture_root/server"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj '/CN=DBeer temporary MariaDB CA' -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$fixture_root/ca.key" -out "$fixture_root/server/ca.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -sha256 -subj '/CN=localhost' \
    -keyout "$fixture_root/server/server.key" -out "$fixture_root/server.csr" >/dev/null 2>&1
cat >"$fixture_root/server.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost
EXT
openssl x509 -req -sha256 -days 1 -in "$fixture_root/server.csr" \
    -CA "$fixture_root/server/ca.crt" -CAkey "$fixture_root/ca.key" -CAcreateserial \
    -extfile "$fixture_root/server.ext" -out "$fixture_root/server/server.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj '/CN=DBeer unrelated MariaDB CA' -addext 'basicConstraints=critical,CA:TRUE' \
    -keyout "$fixture_root/untrusted.key" -out "$fixture_root/untrusted.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -sha256 -subj '/CN=localhost' \
    -keyout "$fixture_root/server/rotated.key" -out "$fixture_root/rotated.csr" >/dev/null 2>&1
openssl x509 -req -sha256 -days 1 -in "$fixture_root/rotated.csr" \
    -CA "$fixture_root/server/ca.crt" -CAkey "$fixture_root/ca.key" -CAcreateserial \
    -extfile "$fixture_root/server.ext" -out "$fixture_root/server/rotated.crt" >/dev/null 2>&1
openssl rand -hex 32 >"$fixture_root/server/password"
openssl rand -hex 32 >"$fixture_root/server/root-password"
tls_mode="${DBEER_TEST_MARIADB_TLS:-1}"
case "$tls_mode" in 0|1) ;; *) printf 'Invalid MariaDB TLS fixture mode.\n' >&2; exit 1 ;; esac
performance_schema="${DBEER_TEST_MARIADB_PERFORMANCE_SCHEMA:-0}"
case "$performance_schema" in 0|1) ;; *) printf 'Invalid MariaDB performance-schema fixture mode.\n' >&2; exit 1 ;; esac
root_host=localhost
if [[ "${DBEER_TEST_MARIADB_ADMIN:-0}" == 1 ]]; then root_host="%"; fi
printf 'Running real MariaDB checks with %s.\n' "$image"
container_id="$(docker run --detach --rm --publish 127.0.0.1::3306 \
    --mount "type=bind,source=$fixture_root/server,target=/fixtures,readonly" \
    --env DBEER_FIXTURE_TLS="$tls_mode" \
    --env DBEER_FIXTURE_PERFORMANCE_SCHEMA="$performance_schema" \
    --env MARIADB_USER=dbeer --env MARIADB_DATABASE=dbeer --env MARIADB_ROOT_HOST="$root_host" \
    --env MARIADB_PASSWORD_FILE=/fixtures/password --env MARIADB_ROOT_PASSWORD_FILE=/fixtures/root-password \
    --entrypoint sh "$image" -ec '
        mkdir /tmp/dbeer-tls
        cp /fixtures/ca.crt /fixtures/server.crt /fixtures/server.key /tmp/dbeer-tls/
        chown -R mysql:mysql /tmp/dbeer-tls
        chmod 600 /tmp/dbeer-tls/server.key
        if [ "${DBEER_FIXTURE_PERFORMANCE_SCHEMA:-0}" = 1 ]; then set -- --performance-schema=ON; fi
        if [ "${DBEER_FIXTURE_TLS:-1}" = 0 ]; then
            set -- "$@" --skip-ssl
        else
            set -- "$@" --ssl-ca=/tmp/dbeer-tls/ca.crt --ssl-cert=/tmp/dbeer-tls/server.crt --ssl-key=/tmp/dbeer-tls/server.key
        fi
        exec docker-entrypoint.sh mariadbd --local-infile=OFF --log-bin-trust-function-creators=ON "$@"
    ')"
ready=0
for ((attempt = 0; attempt < 120; attempt++)); do
    if docker exec "$container_id" sh -ec '
        MYSQL_PWD="$(cat /fixtures/password)" mariadb --skip-ssl --host=127.0.0.1 --user=dbeer \
            --database=dbeer --silent --skip-column-names --execute="SELECT 1"
    ' >/dev/null 2>&1; then ready=1; break; fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" != true ]]; then
        printf 'MariaDB test container exited before becoming ready.\n' >&2; exit 1
    fi
    sleep 1
done
if [[ "$ready" != 1 ]]; then printf 'MariaDB test container did not become ready.\n' >&2; exit 1; fi
docker exec "$container_id" mariadbd --version
docker run --rm --label "dbeer.mariadb.tools=$tool_label" --entrypoint mariadb "$tool_image" --version
if [[ -n "${DBEER_TEST_MARIADB_IMAGE_RECEIPT:-}" ]]; then
    image_id="$(docker inspect --format '{{.Image}}' "$container_id")"
    tool_image_id="$(docker image inspect --format '{{.Id}}' "$tool_image")"
    printf '{"imageID":"%s","toolImageID":"%s"}\n' "$image_id" "$tool_image_id" >"$DBEER_TEST_MARIADB_IMAGE_RECEIPT"
fi
port_mapping="$(docker port "$container_id" 3306/tcp)"
export DBEER_TEST_MARIADB_HOST=localhost DBEER_TEST_MARIADB_PORT="${port_mapping##*:}"
export DBEER_TEST_MARIADB_USER=dbeer DBEER_TEST_MARIADB_DATABASE=dbeer
export DBEER_TEST_MARIADB_PASSWORD="$(cat "$fixture_root/server/password")"
if [[ "${DBEER_TEST_MARIADB_ADMIN:-0}" == 1 ]]; then
    export DBEER_TEST_MARIADB_ADMIN_USER=root
    export DBEER_TEST_MARIADB_ADMIN_PASSWORD="$(cat "$fixture_root/server/root-password")"
fi
export DBEER_TEST_MARIADB_SSLMODE=disable
export DBEER_TEST_MARIADB_CA_FILE="$fixture_root/server/ca.crt"
export DBEER_TEST_MARIADB_UNTRUSTED_CA_FILE="$fixture_root/untrusted.crt"
export DBEER_REQUIRE_MARIADB=1 DBEER_REQUIRE_MARIADB_TLS="$tls_mode"
# Compatible real clients are provided only to tests, without host installation.
docker_executable="$(command -v docker)"
docker_endpoint="${DOCKER_HOST:-$(docker context inspect --format '{{(index .Endpoints "docker").Host}}')}"
mkdir "$fixture_root/tools" "$fixture_root/tool-inputs"
{
    printf 'export DBEER_TEST_MARIADB_TOOL_DOCKER=%q\n' "$docker_executable"
    printf 'export DBEER_TEST_MARIADB_TOOL_ENDPOINT=%q\n' "$docker_endpoint"
    printf 'export DBEER_TEST_MARIADB_TOOL_CONTAINER=%q\n' "$container_id"
    printf 'export DBEER_TEST_MARIADB_TOOL_PORT=%q\n' "$DBEER_TEST_MARIADB_PORT"
    printf 'export DBEER_TEST_MARIADB_TOOL_IMAGE=%q\n' "$tool_image"
    printf 'export DBEER_TEST_MARIADB_TOOL_INPUTS=%q\n' "$fixture_root/tool-inputs"
    printf 'export DBEER_TEST_MARIADB_TOOL_LABEL=%q\n' "$tool_label"
} >"$fixture_root/tools.env"
for tool in mariadb mariadb-dump tls-control; do
    {
        printf '#!/usr/bin/env bash\nset -euo pipefail\n'
        printf 'source %q\n' "$fixture_root/tools.env"
        printf 'exec %q %q "$@"\n' "$repo_root/scripts/test-mariadb-tools.sh" "$tool"
    } >"$fixture_root/tools/$tool"
    chmod 700 "$fixture_root/tools/$tool"
done
printf 'Using native MariaDB tools from %s.\n' "$tool_image"
export DBEER_TEST_MARIADB_TOOLS_DIR="$fixture_root/tools"
export DBEER_TEST_MARIADB_TLS_CONTROL="$fixture_root/tools/tls-control"
export DBEER_TEST_MARIADB_PASSWORD_FILE="$fixture_root/server/password"

export GOCACHE="${GOCACHE:-$repo_root/build/.cache/go}"
export GOMODCACHE="${GOMODCACHE:-$repo_root/build/.cache/go-mod}"
if [[ "$#" -gt 0 ]]; then
    "$@"
else
    cd "$repo_root/helper"
    go test -race -count=1 -p 1 ./...
fi
