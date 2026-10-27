#!/usr/bin/env bash
set -euo pipefail

# Disposable Cassandra matrix. Generated configuration, credentials and TLS
# material stay under ignored build/ and are removed even after failed tests.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
versions=(4.1 5.0)
modes=(plain tls)
multi_node=0
udf_enabled=0
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --version) versions=("${2:?missing Cassandra version}"); shift 2 ;;
        --mode) modes=("${2:?missing plain or tls mode}"); shift 2 ;;
        --multi-node) multi_node=1; shift ;;
        --udf) udf_enabled=1; shift ;;
        --) shift; break ;;
        -h|--help)
            printf 'Usage: %s [--version 4.1|5.0] [--mode plain|tls] [--multi-node] [--udf] [-- command ...]\n' "$0"
            exit 0 ;;
        *) break ;;
    esac
done
for version in "${versions[@]}"; do
    [[ "$version" == 4.1 || "$version" == 5.0 ]] || { printf 'Unsupported Cassandra test version.\n' >&2; exit 2; }
done
for mode in "${modes[@]}"; do
    [[ "$mode" == plain || "$mode" == tls ]] || { printf 'Cassandra mode must be plain or tls.\n' >&2; exit 2; }
done
if [[ "$multi_node" == 1 && "$#" -gt 0 ]]; then
    printf 'The multi-node profile runs Go checks inside its isolated Docker network; custom host commands are unsupported.\n' >&2
    exit 2
fi
for dependency in docker openssl go python3; do
    command -v "$dependency" >/dev/null || { printf 'Cassandra checks require %s.\n' "$dependency" >&2; exit 1; }
done
docker info >/dev/null
umask 077
mkdir -p "$repo_root/build/cassandra"
fixture_root="$(mktemp -d "$repo_root/build/cassandra/fixture.XXXXXX")"
container_ids=()
network_id=""
cleanup_fixture() {
    for container_id in ${container_ids[@]+"${container_ids[@]}"}; do docker rm --force "$container_id" >/dev/null 2>&1 || true; done
    container_ids=()
    if [[ -n "$network_id" ]]; then docker network rm "$network_id" >/dev/null 2>&1 || true; network_id=""; fi
}
cleanup() { cleanup_fixture; rm -rf -- "$fixture_root"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_network_checks() {
    docker run --rm --network "$network_id" --memory=1g --cpus=2 \
        --mount "type=bind,source=$repo_root,target=/workspace" --workdir /workspace/helper \
        --env DBEER_TEST_CASSANDRA_HOST=dbeer-node1 --env DBEER_TEST_CASSANDRA_PORT=9042 \
        --env DBEER_TEST_CASSANDRA_DATABASE --env DBEER_TEST_CASSANDRA_DATACENTER \
        --env DBEER_TEST_CASSANDRA_VERSION --env DBEER_REQUIRE_CASSANDRA --env DBEER_TEST_CASSANDRA_UDF \
        --env DBEER_TEST_CASSANDRA_SSLMODE --env DBEER_TEST_CASSANDRA_USER --env DBEER_TEST_CASSANDRA_PASSWORD \
        --env "DBEER_TEST_CASSANDRA_CA_FILE=/workspace/${fixture_root#"$repo_root/"}/ca.crt" \
        --env "DBEER_TEST_CASSANDRA_UNTRUSTED_CA_FILE=/workspace/${fixture_root#"$repo_root/"}/untrusted.crt" \
        --env "DBEER_TEST_CASSANDRA_MULTI_NODE=$1" \
        --env GOCACHE=/workspace/build/.cache/go-cassandra-linux \
        --env GOMODCACHE=/workspace/build/.cache/go-mod \
        golang:1.27.1 go test -json -race -count=1 -p 1 -timeout 8m -run "$2" ./internal/cassandra ./internal/session
}

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj '/CN=DBeer temporary Cassandra CA' \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$fixture_root/ca.key" -out "$fixture_root/ca.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -sha256 -subj '/CN=localhost' \
    -keyout "$fixture_root/server.key" -out "$fixture_root/server.csr" >/dev/null 2>&1
cat > "$fixture_root/server.ext" <<'CERT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,DNS:dbeer-node1,DNS:dbeer-node2,DNS:dbeer-node3,IP:127.0.0.1
CERT
openssl x509 -req -sha256 -days 1 -in "$fixture_root/server.csr" \
    -CA "$fixture_root/ca.crt" -CAkey "$fixture_root/ca.key" -CAcreateserial \
    -extfile "$fixture_root/server.ext" -out "$fixture_root/server.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj '/CN=DBeer unrelated Cassandra CA' \
    -addext 'basicConstraints=critical,CA:TRUE' -keyout "$fixture_root/untrusted.key" \
    -out "$fixture_root/untrusted.crt" >/dev/null 2>&1
openssl rand -hex 24 > "$fixture_root/password"
openssl rand -hex 24 > "$fixture_root/keystore-password"
openssl pkcs12 -export -in "$fixture_root/server.crt" -inkey "$fixture_root/server.key" \
    -certfile "$fixture_root/ca.crt" -name dbeer -out "$fixture_root/server.p12" \
    -passout "file:$fixture_root/keystore-password" >/dev/null 2>&1

for version in "${versions[@]}"; do
    image="${DBEER_TEST_CASSANDRA_IMAGE_PREFIX:-cassandra}:$version"
    docker run --rm --entrypoint cat "$image" /etc/cassandra/cassandra.yaml > "$fixture_root/base.yaml"
    for mode in "${modes[@]}"; do
        cleanup_fixture
        printf 'Running Cassandra %s %s checks%s.\n' "$version" "$mode" "$([[ "$multi_node" == 1 ]] && printf ' with three nodes' || true)"
        python3 - "$fixture_root" "$mode" "$multi_node" "$udf_enabled" <<'PY'
import pathlib, re, sys
root=pathlib.Path(sys.argv[1]); tls=sys.argv[2]=='tls'; multi=sys.argv[3]=='1'
config=(root/'base.yaml').read_text()
# Comparison fixtures verify captured materialized-view predicates and CQL.
config=re.sub(r'^materialized_views_enabled:.*$', 'materialized_views_enabled: true',config,flags=re.M)
if sys.argv[4]=='1':config=re.sub(r'^(enable_user_defined_functions|user_defined_functions_enabled):.*$',r'\1: true',config,flags=re.M)
if tls:
    config=re.sub(r'^authenticator:.*$', 'authenticator: PasswordAuthenticator',config,flags=re.M)
    config=re.sub(r'^authorizer:.*$', 'authorizer: CassandraAuthorizer',config,flags=re.M)
    block='''client_encryption_options:
    enabled: true
    optional: false
    keystore: /etc/cassandra/dbeer.p12
    keystore_password: %s
    store_type: PKCS12
    require_client_auth: false
''' % (root/'keystore-password').read_text().strip()
    config=re.sub(r'^client_encryption_options:\n(?:(?:[ \t].*|\s*|#.*)\n)*',block,config,flags=re.M)
(root/'cassandra.yaml').write_text(config)
rc=''
if tls:
    rc='[authentication]\nusername = cassandra\npassword = cassandra\n[ssl]\ncertfile = /fixtures/ca.crt\nvalidate = true\n'
(root/'cqlshrc').write_text(rc)
password=(root/'password').read_text().strip()
replication="{'class':'NetworkTopologyStrategy','datacenter1':%d}" % (3 if multi else 1)
seed='CREATE KEYSPACE IF NOT EXISTS dbeer WITH replication = %s;\nCREATE KEYSPACE IF NOT EXISTS dbeer_other WITH replication = %s;\n' % (replication,replication)
if multi:seed+="CREATE TABLE IF NOT EXISTS dbeer.live_quorum (id int PRIMARY KEY,value text);\nINSERT INTO dbeer.live_quorum (id,value) VALUES (1,'quorum');\n"
if tls and multi:seed+="ALTER KEYSPACE system_auth WITH replication = %s;\n" % replication
if tls:seed+="CREATE ROLE IF NOT EXISTS dbeer WITH PASSWORD = '%s' AND LOGIN = true AND SUPERUSER = true;\n" % password
(root/'init.cql').write_text(seed)
PY
        node_count=1
        if [[ "$multi_node" == 1 ]]; then
            node_count=3
            network_id="$(docker network create "dbeer-cassandra-$(basename "$fixture_root")-$version-$mode")"
            # Newly discovered peers are addressed by IP, so their real fixture
            # addresses must be covered by verified TLS certificates as well.
            subnet="$(docker network inspect --format '{{(index .IPAM.Config 0).Subnet}}' "$network_id")"
            python3 - "$fixture_root/server.ext" "$subnet" <<'PEERS'
import ipaddress,pathlib,sys
p=pathlib.Path(sys.argv[1]);network=ipaddress.ip_network(sys.argv[2]);s=p.read_text()
s='\n'.join(line for line in s.splitlines() if not line.startswith('subjectAltName='))+'\n'
s+='subjectAltName=DNS:localhost,DNS:dbeer-node1,DNS:dbeer-node2,DNS:dbeer-node3,IP:127.0.0.1,'+','.join('IP:'+str(network.network_address+n) for n in (2,3,4))+'\n'
p.write_text(s)
PEERS
            openssl x509 -req -sha256 -days 1 -in "$fixture_root/server.csr" \
                -CA "$fixture_root/ca.crt" -CAkey "$fixture_root/ca.key" -CAcreateserial \
                -extfile "$fixture_root/server.ext" -out "$fixture_root/server.crt" >/dev/null 2>&1
            openssl pkcs12 -export -in "$fixture_root/server.crt" -inkey "$fixture_root/server.key" \
                -certfile "$fixture_root/ca.crt" -name dbeer -out "$fixture_root/server.p12" \
                -passout "file:$fixture_root/keystore-password" >/dev/null 2>&1
        fi
        for ((node=1; node<=node_count; node++)); do
            network_options=()
            if [[ -n "$network_id" ]]; then network_options=(--network "$network_id" --network-alias "dbeer-node$node"); fi
            seed_options=()
            if [[ "$multi_node" == 1 && "$node" -gt 1 ]]; then seed_options=(--env CASSANDRA_SEEDS=dbeer-node1); fi
            container_id="$(docker run --detach --rm --memory=2300m --cpus=3 \
                --publish 127.0.0.1::9042 ${network_options[@]+"${network_options[@]}"} ${seed_options[@]+"${seed_options[@]}"} \
                --mount "type=bind,source=$fixture_root,target=/fixtures,readonly" \
                --env MAX_HEAP_SIZE=512M --env HEAP_NEWSIZE=100M \
                --env CASSANDRA_CLUSTER_NAME=DBeerIntegration --env CASSANDRA_DC=datacenter1 \
                --env CASSANDRA_ENDPOINT_SNITCH=GossipingPropertyFileSnitch \
                --entrypoint sh "$image" -ec '
                    cp /fixtures/cassandra.yaml /etc/cassandra/cassandra.yaml
                    cp /fixtures/server.p12 /etc/cassandra/dbeer.p12
                    chown cassandra:cassandra /etc/cassandra/cassandra.yaml /etc/cassandra/dbeer.p12
                    chmod 600 /etc/cassandra/cassandra.yaml /etc/cassandra/dbeer.p12
                    exec docker-entrypoint.sh cassandra -f
                ')"
            container_ids+=("$container_id")
            ready=0
            tls_options=()
            if [[ "$mode" == tls ]]; then tls_options=(--ssl); fi
            for ((attempt=0; attempt<180; attempt++)); do
                if docker exec "$container_id" cqlsh 127.0.0.1 9042 --cqlshrc=/fixtures/cqlshrc \
                    ${tls_options[@]+"${tls_options[@]}"} -e 'SELECT release_version FROM system.local' >/dev/null 2>&1; then ready=1; break; fi
                if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true)" != true ]]; then
                    printf 'Cassandra %s node %s exited before readiness.\n' "$version" "$node" >&2; exit 1
                fi
                sleep 2
            done
            if [[ "$ready" != 1 ]]; then printf 'Cassandra %s node %s readiness timed out.\n' "$version" "$node" >&2; exit 1; fi
        done
        docker exec "${container_ids[0]}" cqlsh 127.0.0.1 9042 --cqlshrc=/fixtures/cqlshrc \
            ${tls_options[@]+"${tls_options[@]}"} -f /fixtures/init.cql >/dev/null 2>&1
        port_mapping="$(docker port "${container_ids[0]}" 9042/tcp)"
        export DBEER_TEST_CASSANDRA_HOST=localhost DBEER_TEST_CASSANDRA_PORT="${port_mapping##*:}"
        export DBEER_TEST_CASSANDRA_DATABASE=dbeer DBEER_TEST_CASSANDRA_DATACENTER=datacenter1
        export DBEER_TEST_CASSANDRA_VERSION="$version" DBEER_REQUIRE_CASSANDRA=1
        export DBEER_TEST_CASSANDRA_UDF="$udf_enabled"
        export DBEER_TEST_CASSANDRA_SSLMODE=disable DBEER_TEST_CASSANDRA_USER= DBEER_TEST_CASSANDRA_PASSWORD=
        export DBEER_TEST_CASSANDRA_CA_FILE="$fixture_root/ca.crt"
        export DBEER_TEST_CASSANDRA_UNTRUSTED_CA_FILE="$fixture_root/untrusted.crt"
        if [[ "$mode" == tls ]]; then
            export DBEER_TEST_CASSANDRA_SSLMODE=verify-full DBEER_TEST_CASSANDRA_USER=dbeer
            export DBEER_TEST_CASSANDRA_PASSWORD="$(cat "$fixture_root/password")"
        fi
        export GOCACHE="${GOCACHE:-$repo_root/build/.cache/go}"
        export GOMODCACHE="${GOMODCACHE:-$repo_root/build/.cache/go-mod}"
        run_log="$repo_root/build/cassandra/$version-$mode-$multi_node.jsonl"
        printf 'Test evidence: %s\n' "$run_log"
        if [[ "$multi_node" == 1 ]]; then
            # Run all schema/catalog checks while every replica can agree.
            run_network_checks 0 Cassandra > "$run_log"
            # The subsequent phase changes data only, with an existing RF3 schema.
            docker stop --time 15 "${container_ids[2]}" >/dev/null
            run_network_checks 1 '^TestCassandraLiveReplicaConsistencyFailure$' >> "$run_log"
        elif [[ "$#" -gt 0 ]]; then "$@"
        else
            (cd "$repo_root/helper"; go test -json -race -count=1 -p 1 -timeout 8m -run Cassandra ./internal/cassandra ./internal/session) > "$run_log"
        fi
        if [[ "$#" == 0 ]]; then
            python3 - "$run_log" "$mode" "$multi_node" "$udf_enabled" "$version" <<'EVIDENCE'
import json,pathlib,sys
log=pathlib.Path(sys.argv[1]); events=[json.loads(line) for line in log.read_text().splitlines() if line]
passed={e['Test'] for e in events if e.get('Action')=='pass' and e.get('Test')}
required={'TestCassandraLiveSessionsCQLAndLosslessTypes','TestCassandraLiveBrowsePagingCatalogAndFullExport','TestCassandraLiveBrowsePagingCatalogAndFullExport/csv','TestCassandraLiveBrowsePagingCatalogAndFullExport/json'}
required.update({'TestCassandraLiveAcknowledgedWritesSurviveDeliveryAndExportFailures','TestCassandraLiveUDTFieldsAndWideEmptyResultsStayBounded','TestCassandraLiveSpecialSelectorsAndNativeFunctions','TestCassandraLiveGeneratedNativeFunctionCompletions','TestCassandraLiveConditionalGridEdits','TestCassandraLiveAtomicGridApply'})
required.add('TestCassandraLiveClusterNodes')
required.add('TestCassandraLiveSchemaAndDataComparisonTypes')
required.add('TestCassandraLiveExpandedNativeLanguageFunctions')
required.add('TestCassandraLiveEditorColumnTypes')
if sys.argv[5].startswith('5'):
    for name in ['math','collections','masking','vectors','selectors','snake_case_aliases']:
        required.add('TestCassandraLiveExpandedNativeLanguageFunctions/cassandra5/'+name)
for name in 'COUNT SUM AVG MIN MAX TOKEN TTL WRITETIME UUID NOW CURRENTTIMESTAMP CURRENTDATE CURRENTTIME CURRENTTIMEUUID TODATE TOTIMESTAMP TOUNIXTIMESTAMP MINTIMEUUID MAXTIMEUUID CAST TOJSON'.split():required.add('TestCassandraLiveGeneratedNativeFunctionCompletions/'+name)
if sys.argv[2]=='tls':required.add('TestCassandraLiveTLSAndAuthenticationFailures')
if sys.argv[2]=='plain':required.add('TestCassandraLiveLostWriteAcknowledgementIsUnknownAndNotRepeated')
if sys.argv[3]=='1':required.add('TestCassandraLiveReplicaConsistencyFailure')
if sys.argv[4]=='1':required.update({'TestCassandraLiveUserFunctionShadowingIsNotReadOnly','TestCassandraLiveRoutineCompletionDeclarations'})
missing=required-passed
for event in events:
    if event.get('Action')=='pass' and not event.get('Test'):
        print('PASS %s (%.3fs)' % (event['Package'],event.get('Elapsed',0)))
for name in sorted(required):print(('PASS ' if name in passed else 'MISSING ')+name)
print('Completed %d Go tests/subtests; required live scenarios %d/%d.' % (len(passed),len(required)-len(missing),len(required)))
if missing:raise SystemExit('Required Cassandra live tests did not execute successfully; inspect '+str(log))
EVIDENCE
        fi
        printf 'Completed Cassandra %s %s checks.\n' "$version" "$mode"
    done
done
