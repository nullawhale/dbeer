#!/usr/bin/env bash
set -euo pipefail

# Only the bastion port is published. Database aliases and discovered Cassandra
# node addresses exist inside this owned, disposable Docker network.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
engines="postgresql mysql cassandra"
if [[ "${1:-}" == --engine ]]; then
    engines="${2:?missing engine}"
    [[ "$engines" == postgresql || "$engines" == mysql || "$engines" == cassandra ]] || exit 2
    shift 2
fi
if [[ "$#" != 0 ]]; then printf 'Usage: %s [--engine postgresql|mysql|cassandra]\n' "$0" >&2; exit 2; fi
for dependency in docker openssl ssh-keygen ssh-agent ssh-add go python3; do
    command -v "$dependency" >/dev/null || { printf 'Required SSH checks need %s; no checks ran.\n' "$dependency" >&2; exit 1; }
done
docker info >/dev/null
umask 077
mkdir -p "$repo_root/build/ssh"
fixture_root="$(mktemp -d "$repo_root/build/ssh/fixture.XXXXXX")"
network_id=""
container_ids=()
agent_pid=""
cleanup() {
    for container_id in ${container_ids[@]+"${container_ids[@]}"}; do docker rm --force "$container_id" >/dev/null 2>&1 || true; done
    if [[ -n "$network_id" ]]; then docker network rm "$network_id" >/dev/null 2>&1 || true; fi
    if [[ -n "$agent_pid" ]]; then kill "$agent_pid" >/dev/null 2>&1 || true; fi
    rm -rf -- "$fixture_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
openssl rand -hex 24 > "$fixture_root/password"
openssl rand -hex 24 > "$fixture_root/passphrase"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_root/id_plain"
# ssh-keygen accepts a passphrase on stdin when no -N argument is supplied.
# Supplying it through a private pipe keeps the value out of process argv.
printf '%s\n%s\n' "$(cat "$fixture_root/passphrase")" "$(cat "$fixture_root/passphrase")" |
    ssh-keygen -q -t ed25519 -f "$fixture_root/id_encrypted" >/dev/null 2>&1
cat "$fixture_root/id_plain.pub" "$fixture_root/id_encrypted.pub" > "$fixture_root/authorized_keys"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_root/ssh_host_ed25519_key"
cat > "$fixture_root/Dockerfile" <<'DOCKER'
FROM alpine:3.22
RUN apk add --no-cache openssh-server && adduser -D -s /bin/sh dbeer
COPY start-sshd /usr/local/bin/start-sshd
ENTRYPOINT ["/bin/sh", "/usr/local/bin/start-sshd"]
DOCKER
cat > "$fixture_root/start-sshd" <<'SSHD'
set -eu
mkdir -p /home/dbeer/.ssh /run/sshd
cp /fixtures/authorized_keys /home/dbeer/.ssh/authorized_keys
chown -R dbeer:dbeer /home/dbeer/.ssh
chmod 700 /home/dbeer/.ssh
chmod 600 /home/dbeer/.ssh/authorized_keys
printf 'dbeer:%s\n' "$(cat /fixtures/password)" | chpasswd
cp /fixtures/ssh_host_ed25519_key /run/sshd/host_key
chmod 600 /run/sshd/host_key
exec /usr/sbin/sshd -D -e -h /run/sshd/host_key -o PasswordAuthentication=yes -o KbdInteractiveAuthentication=no -o AllowTcpForwarding=yes -o PermitRootLogin=no -o PerSourcePenalties=no -o MaxStartups=100
SSHD
image="dbeer-ssh-fixture:local"
docker build --quiet --tag "$image" "$fixture_root" >/dev/null
network_id="$(docker network create "dbeer-ssh-$(basename "$fixture_root")")"
network_subnet="$(docker network inspect --format '{{(index .IPAM.Config 0).Subnet}}' "$network_id")"
node_addresses="$(python3 - "$network_subnet" <<'PY'
import ipaddress,sys
n=ipaddress.ip_network(sys.argv[1]);print(' '.join(str(n.network_address+i) for i in (11,12,13)))
PY
)"
read -r -a cassandra_ips <<< "$node_addresses"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj '/CN=DBeer temporary SSH database CA' \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$fixture_root/ca.key" -out "$fixture_root/ca.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj '/CN=DBeer unrelated SSH database CA' \
    -addext 'basicConstraints=critical,CA:TRUE' -keyout "$fixture_root/wrong-ca.key" -out "$fixture_root/wrong-ca.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -sha256 -subj '/CN=postgres.ssh-fixture.invalid' \
    -keyout "$fixture_root/server.key" -out "$fixture_root/server.csr" >/dev/null 2>&1
cat > "$fixture_root/server.ext" <<CERT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:postgres.ssh-fixture.invalid,DNS:mysql.ssh-fixture.invalid,IP:${cassandra_ips[0]},IP:${cassandra_ips[1]},IP:${cassandra_ips[2]}
CERT
openssl x509 -req -sha256 -days 1 -in "$fixture_root/server.csr" -CA "$fixture_root/ca.crt" -CAkey "$fixture_root/ca.key" \
    -CAcreateserial -extfile "$fixture_root/server.ext" -out "$fixture_root/server.crt" >/dev/null 2>&1
openssl pkcs12 -export -in "$fixture_root/server.crt" -inkey "$fixture_root/server.key" -certfile "$fixture_root/ca.crt" \
    -name dbeer -out "$fixture_root/server.p12" -passout "file:$fixture_root/passphrase" >/dev/null 2>&1
bastion="$(docker run --detach --rm --network "$network_id" --publish 127.0.0.1::22 \
    --mount "type=bind,source=$fixture_root,target=/fixtures,readonly" "$image")"
container_ids+=("$bastion")
port_mapping="$(docker port "$bastion" 22/tcp)"
export DBEER_TEST_SSH_PORT="${port_mapping##*:}"
export DBEER_TEST_SSH_ROOT="$fixture_root" DBEER_REQUIRE_SSH=1 DBEER_REQUIRE_SSH_TLS=1
export DBEER_TEST_SSH_TLS_CA="$fixture_root/ca.crt" DBEER_TEST_SSH_TLS_WRONG_CA="$fixture_root/wrong-ca.crt"
export GOCACHE="$repo_root/build/.cache/go" GOMODCACHE="$repo_root/build/.cache/go-mod"
eval "$(ssh-agent -s)" >/dev/null
agent_pid="$SSH_AGENT_PID"
ssh-add "$fixture_root/id_plain" >/dev/null 2>&1
for engine in $engines; do
    printf 'Running required SSH checks for %s.\n' "$engine"
    case "$engine" in
        postgresql)
            database="$(docker run --detach --rm --network "$network_id" --network-alias postgres.ssh-fixture.invalid --network-alias wrong-tls.ssh-fixture.invalid \
                --mount "type=bind,source=$fixture_root,target=/fixtures,readonly" --env POSTGRES_DB=dbeer --env POSTGRES_USER=dbeer \
                --env POSTGRES_PASSWORD_FILE=/fixtures/password --entrypoint sh "${DBEER_TEST_POSTGRES_IMAGE:-postgres:17}" -ec '
                    mkdir /tmp/dbeer-tls
                    cp /fixtures/server.crt /fixtures/server.key /tmp/dbeer-tls/
                    chown -R postgres:postgres /tmp/dbeer-tls
                    chmod 600 /tmp/dbeer-tls/server.key
                    exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/dbeer-tls/server.crt -c ssl_key_file=/tmp/dbeer-tls/server.key
                ')"
            container_ids+=("$database")
            ready=0
            for ((attempt=0;attempt<90;attempt++)); do if docker exec "$database" pg_isready -U dbeer -d dbeer >/dev/null 2>&1; then ready=1; break; fi; sleep 1; done
            [[ "$ready" == 1 ]] || { printf 'PostgreSQL fixture did not become ready.\n' >&2; exit 1; }
            ;;
        mysql)
            database="$(docker run --detach --rm --network "$network_id" --network-alias mysql.ssh-fixture.invalid --network-alias wrong-tls.ssh-fixture.invalid \
                --mount "type=bind,source=$fixture_root,target=/fixtures,readonly" --env MYSQL_DATABASE=dbeer --env MYSQL_USER=dbeer \
                --env MYSQL_PASSWORD_FILE=/fixtures/password --env MYSQL_ROOT_PASSWORD_FILE=/fixtures/password \
                --entrypoint sh "${DBEER_TEST_MYSQL_IMAGE:-mysql:8.4}" -ec '
                    mkdir /tmp/dbeer-tls
                    cp /fixtures/ca.crt /fixtures/server.crt /fixtures/server.key /tmp/dbeer-tls/
                    chown -R mysql:mysql /tmp/dbeer-tls
                    chmod 600 /tmp/dbeer-tls/server.key
                    exec docker-entrypoint.sh mysqld --ssl-ca=/tmp/dbeer-tls/ca.crt --ssl-cert=/tmp/dbeer-tls/server.crt --ssl-key=/tmp/dbeer-tls/server.key
                ')"
            container_ids+=("$database")
            ready=0
            for ((attempt=0;attempt<120;attempt++)); do if docker exec "$database" sh -ec 'MYSQL_PWD="$(cat /fixtures/password)" mysql -h127.0.0.1 -udbeer -Ddbeer -Nse "SELECT 1"' >/dev/null 2>&1; then ready=1; break; fi; sleep 1; done
            [[ "$ready" == 1 ]] || { printf 'MySQL fixture did not become ready.\n' >&2; exit 1; }
            ;;
        cassandra)
            docker run --rm --entrypoint cat "${DBEER_TEST_CASSANDRA_SSH_IMAGE:-cassandra:5.0}" /etc/cassandra/cassandra.yaml > "$fixture_root/cassandra.base.yaml"
            python3 - "$fixture_root" <<'PY'
import pathlib,re,sys
root=pathlib.Path(sys.argv[1]);config=(root/'cassandra.base.yaml').read_text()
block='''client_encryption_options:
  enabled: true
  optional: true
  keystore: /etc/cassandra/dbeer.p12
  keystore_password: %s
  store_type: PKCS12
  require_client_auth: false

''' % (root/'passphrase').read_text().strip()
config=re.sub(r'(?ms)^client_encryption_options:\n.*?(?=^[a-zA-Z_][a-zA-Z_]*:)',block,config)
(root/'cassandra.yaml').write_text(config)
PY
            cassandra_nodes=()
            seed=""
            for node in 1 2 3; do
                node_id="$(docker run --detach --rm --network "$network_id" --network-alias "cassandra$node" --ip "${cassandra_ips[$((node-1))]}" --memory=1500m \
                    --mount "type=bind,source=$fixture_root,target=/fixtures,readonly" \
                    --env MAX_HEAP_SIZE=512M --env HEAP_NEWSIZE=128M --env CASSANDRA_CLUSTER_NAME=DBeerSSHFixture \
                    --env CASSANDRA_SEEDS="${seed:-cassandra1}" --entrypoint bash "${DBEER_TEST_CASSANDRA_SSH_IMAGE:-cassandra:5.0}" -ec '
                        cp /fixtures/server.p12 /etc/cassandra/dbeer.p12
                        cp /fixtures/cassandra.yaml /etc/cassandra/cassandra.yaml
                        chown cassandra:cassandra /etc/cassandra/dbeer.p12 /etc/cassandra/cassandra.yaml
                        exec docker-entrypoint.sh cassandra -f
                    ')"
                container_ids+=("$node_id"); cassandra_nodes+=("$node_id")
                if [[ "$node" == 1 ]]; then seed="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$node_id")"; fi
                ready=0
                for ((attempt=0;attempt<180;attempt++)); do if docker exec "$node_id" cqlsh -e 'SELECT release_version FROM system.local' >/dev/null 2>&1; then ready=1; break; fi; sleep 1; done
                [[ "$ready" == 1 ]] || { printf 'Cassandra fixture did not become ready.\n' >&2; exit 1; }
            done
            export DBEER_TEST_SSH_CASSANDRA_HOST="$seed"
            ;;
    esac
    export DBEER_TEST_SSH_ENGINE="$engine"
    (cd "$repo_root/helper"; go test -race -count=1 -timeout 6m -run '^TestSSH' ./internal/sshtest ./cmd/dbeer-core)
    case "$engine" in
        cassandra) for node_id in "${cassandra_nodes[@]}"; do docker rm --force "$node_id" >/dev/null; done ;;
        *) docker rm --force "$database" >/dev/null ;;
    esac
done
printf 'Required SSH integration matrix completed: %s.\n' "$engines"
