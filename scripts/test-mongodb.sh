#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${DBEER_TEST_MONGODB_MODE:-all}"
if [[ "${1:-}" == --mode ]]; then mode="${2:?missing plain or tls}"; shift 2; fi
[[ "$mode" == all || "$mode" == plain || "$mode" == tls || "$mode" == replica ]] || { printf 'Use --mode plain|tls|replica|all.\n' >&2; exit 2; }
if [[ "${1:-}" == -- ]]; then shift; fi
for dependency in docker openssl go python3; do command -v "$dependency" >/dev/null; done
docker info >/dev/null
umask 077
mkdir -p "$repo_root/build/mongodb" "$repo_root/build/.cache"
fixture_root="$(mktemp -d "$repo_root/build/mongodb/fixture.XXXXXX")"
container_id=""
cleanup_container() { if [[ -n "$container_id" ]]; then docker rm --force "$container_id" >/dev/null 2>&1 || true; container_id=""; fi; }
cleanup() { cleanup_container; rm -rf -- "$fixture_root"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj '/CN=DBeer temporary MongoDB CA' \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$fixture_root/ca.key" -out "$fixture_root/ca.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -sha256 -subj '/CN=localhost' \
    -keyout "$fixture_root/server.key" -out "$fixture_root/server.csr" >/dev/null 2>&1
cat > "$fixture_root/server.ext" <<'CERT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost
CERT
openssl x509 -req -sha256 -days 1 -in "$fixture_root/server.csr" -CA "$fixture_root/ca.crt" \
    -CAkey "$fixture_root/ca.key" -CAcreateserial -extfile "$fixture_root/server.ext" -out "$fixture_root/server.crt" >/dev/null 2>&1
cat "$fixture_root/server.crt" "$fixture_root/server.key" > "$fixture_root/server.pem"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj '/CN=Unrelated MongoDB CA' \
    -keyout "$fixture_root/untrusted.key" -out "$fixture_root/untrusted.crt" >/dev/null 2>&1
openssl rand -hex 24 > "$fixture_root/password"
python3 - "$fixture_root" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
(root/'mongo.env').write_text('MONGO_INITDB_ROOT_USERNAME=dbeer\nMONGO_INITDB_ROOT_PASSWORD='+ (root/'password').read_text().strip()+'\n')
PY
# Only disposable fixture files are made readable inside the test container.
chmod 755 "$fixture_root"
chmod 644 "$fixture_root/server.pem" "$fixture_root/ca.crt"

export GOCACHE="$repo_root/build/.cache/go"
export GOMODCACHE="$repo_root/build/.cache/go-mod"
export DBEER_REQUIRE_MONGODB=1
export DBEER_TEST_MONGODB_HOST=localhost
export DBEER_TEST_MONGODB_USER=dbeer
export DBEER_TEST_MONGODB_PASSWORD="$(cat "$fixture_root/password")"
export DBEER_TEST_MONGODB_CA="$fixture_root/ca.crt"
export DBEER_TEST_MONGODB_UNTRUSTED_CA="$fixture_root/untrusted.crt"

for current_mode in plain tls replica; do
    [[ "$mode" == all || "$mode" == "$current_mode" ]] || continue
    cleanup_container
    args=(--bind_ip_all --setParameter enableTestCommands=1)
    tls_shell=()
    auth_args=(--env-file "$fixture_root/mongo.env")
    export DBEER_TEST_MONGODB_REPLICA_SET=""
    export DBEER_TEST_MONGODB_USER=dbeer
    export DBEER_TEST_MONGODB_PASSWORD="$(cat "$fixture_root/password")"
    export DBEER_TEST_MONGODB_SSLMODE=disable
    if [[ "$current_mode" == tls ]]; then
        args+=(--tlsMode requireTLS --tlsCertificateKeyFile /fixture/server.pem --tlsCAFile /fixture/ca.crt --tlsAllowConnectionsWithoutCertificates)
        tls_shell=(--tls --tlsCAFile /fixture/ca.crt)
        export DBEER_TEST_MONGODB_SSLMODE=verify-full
    fi
    if [[ "$current_mode" == replica ]]; then
        args+=(--replSet dbeer-fixture)
        auth_args=()
        export DBEER_TEST_MONGODB_USER=""
        export DBEER_TEST_MONGODB_PASSWORD=""
        export DBEER_TEST_MONGODB_REPLICA_SET=dbeer-fixture
    fi
    printf 'Running MongoDB 8.0 %s integration checks.\n' "$current_mode"
    container_id="$(docker run --detach --rm --memory=1g --cpus=2 --publish 127.0.0.1::27017 \
        ${auth_args[@]+"${auth_args[@]}"} --mount "type=bind,source=$fixture_root,target=/fixture,readonly" \
        "${DBEER_TEST_MONGODB_IMAGE:-mongo:8.0}" "${args[@]}")"
    export DBEER_TEST_MONGODB_PORT="$(docker port "$container_id" 27017/tcp | head -1 | sed 's/.*://')"
    export DBEER_TEST_MONGODB_CONTAINER="$container_id"
    ready=0
    if [[ "$current_mode" == replica ]]; then
        for ((attempt=0;attempt<60;attempt++)); do
            if docker exec "$container_id" mongosh --quiet --eval 'try { rs.initiate({_id:"dbeer-fixture",members:[{_id:0,host:"localhost:27017"}]}) } catch (e) { if (e.codeName !== "AlreadyInitialized") { quit(1) } }' >/dev/null 2>&1; then break; fi
            sleep 1
        done
    fi
    for ((attempt=0;attempt<90;attempt++)); do
        if [[ "$current_mode" == replica ]]; then
            if docker exec "$container_id" mongosh --quiet --eval 'quit(db.hello().isWritablePrimary?0:1)' >/dev/null 2>&1; then ready=1; break; fi
            sleep 1
            continue
        fi
        if docker exec "$container_id" bash -c 'exec mongosh --quiet --host localhost --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin "$@" --eval "quit(db.adminCommand({ping:1}).ok?0:1)"' _ ${tls_shell[@]+"${tls_shell[@]}"} >/dev/null 2>&1; then ready=1; break; fi
        sleep 1
    done
    [[ "$ready" == 1 ]] || { printf 'MongoDB fixture did not become ready.\n' >&2; exit 1; }
    if [[ "$#" -gt 0 ]]; then "$@"; else (cd "$repo_root/helper"; go test -race -count=1 -timeout 3m ./internal/mongodb ./internal/session -run MongoDB); fi
done
