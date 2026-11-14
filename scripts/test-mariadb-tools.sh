#!/usr/bin/env bash
set -euo pipefail

# Test-only native clients in the owned server's network namespace.
tool="${1:-}"
shift
case "$tool" in mariadb|mariadb-dump|tls-control) ;; *) exit 2 ;; esac
: "${DBEER_TEST_MARIADB_TOOL_DOCKER:?}"
: "${DBEER_TEST_MARIADB_TOOL_ENDPOINT:?}"
: "${DBEER_TEST_MARIADB_TOOL_CONTAINER:?}"
: "${DBEER_TEST_MARIADB_TOOL_PORT:?}"
: "${DBEER_TEST_MARIADB_TOOL_IMAGE:?}"
: "${DBEER_TEST_MARIADB_TOOL_INPUTS:?}"
: "${DBEER_TEST_MARIADB_TOOL_LABEL:?}"
export DOCKER_HOST="$DBEER_TEST_MARIADB_TOOL_ENDPOINT"
docker_executable="$DBEER_TEST_MARIADB_TOOL_DOCKER"
container="$DBEER_TEST_MARIADB_TOOL_CONTAINER"
if [[ "$tool" == tls-control ]]; then
    case "${1:-}" in original|rotated) certificate="$1" ;; *) exit 2 ;; esac
    "$docker_executable" exec "$container" sh -ec '
        case "$1" in original) cert=server ;; rotated) cert=rotated ;; *) exit 2 ;; esac
        cp "/fixtures/$cert.crt" /tmp/dbeer-tls/server.crt
        cp "/fixtures/$cert.key" /tmp/dbeer-tls/server.key
        chown mysql:mysql /tmp/dbeer-tls/server.crt /tmp/dbeer-tls/server.key
        chmod 600 /tmp/dbeer-tls/server.key
        MYSQL_PWD="$(cat /fixtures/root-password)" mariadb --skip-ssl --user=root --execute="FLUSH SSL"
    ' sh "$certificate" >/dev/null 2>&1
    exit
fi
arguments=()
mounts=()
private_files=()
cid_file="$(mktemp "$DBEER_TEST_MARIADB_TOOL_INPUTS/client.XXXXXX")"
rm -f -- "$cid_file"
cleanup() {
    if [[ -s "$cid_file" ]]; then
        "$docker_executable" rm -f "$(cat "$cid_file")" >/dev/null 2>&1 || true
    fi
    rm -f -- "$cid_file"
    if [[ "${#private_files[@]}" -gt 0 ]]; then rm -f -- "${private_files[@]}"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
copy_private() {
    local source="$1" destination target
    if [[ ! -f "$source" || -L "$source" ]]; then exit 2; fi
    destination="$(mktemp "$DBEER_TEST_MARIADB_TOOL_INPUTS/input.XXXXXX")"
    cp -- "$source" "$destination"
    chmod 600 "$destination"
    private_files+=("$destination")
    target="/tmp/dbeer-input-${#private_files[@]}"
    mounts+=(--mount "type=bind,source=$destination,target=$target,readonly")
    copied_private="$target"
}
host_seen=0
port_seen=0
version_only=0
for argument in "$@"; do
    case "$argument" in
        --version) version_only=1; arguments+=("$argument") ;;
        --defaults-file=*) copy_private "${argument#*=}"; arguments+=("--defaults-file=$copied_private") ;;
        --ssl-ca=*) copy_private "${argument#*=}"; arguments+=("--ssl-ca=$copied_private") ;;
        --host=localhost|--host=127.0.0.1) host_seen=1; arguments+=("$argument") ;;
        --host=*|--socket=*|--protocol=SOCKET) exit 2 ;;
        --port=*)
            if [[ "${argument#*=}" != "$DBEER_TEST_MARIADB_TOOL_PORT" ]]; then exit 2; fi
            port_seen=1; arguments+=("--port=3306") ;;
        *) arguments+=("$argument") ;;
    esac
done
if [[ "$version_only" != 1 && ( "$host_seen" != 1 || "$port_seen" != 1 ) ]]; then exit 2; fi
# The current client runs no second database server. SQL/results stay in the
# caller's private artifact; even interrupted client containers are owned.
client_arguments=(run --rm --interactive --cidfile "$cid_file"
    --label "dbeer.mariadb.tools=$DBEER_TEST_MARIADB_TOOL_LABEL"
    --network "container:$container")
if [[ "${#mounts[@]}" -gt 0 ]]; then client_arguments+=("${mounts[@]}"); fi
client_arguments+=(--entrypoint "$tool" "$DBEER_TEST_MARIADB_TOOL_IMAGE" "${arguments[@]}")
"$docker_executable" "${client_arguments[@]}" 2>/dev/null
