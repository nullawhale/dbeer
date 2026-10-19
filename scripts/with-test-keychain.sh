#!/usr/bin/env bash
# Isolate test Keychain data; only disposable hosted CI registers a signing keychain.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'The isolated Keychain requires macOS.\n' >&2
    exit 1
fi
ci_signing=0
if [[ "${1:-}" == --ci-signing ]]; then
    ci_signing=1
    shift
    if [[ "${CI:-}" != true || "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
        printf 'Temporary signing identities require a disposable GitHub-hosted runner.\n' >&2
        exit 1
    fi
fi
if [[ "$#" == 0 ]]; then
    printf 'Usage: %s [--ci-signing] command [arguments...]\n' "$0" >&2
    exit 2
fi

temporary="$(mktemp -d "${TMPDIR:-/tmp}/dbeer-keychain.XXXXXX")"
chmod 700 "$temporary"
keychain="$temporary/tests.keychain-db"
password="$(openssl rand -hex 24)"
ci_search_snapshot=0
ci_original_keychains=()
restore_ci_search_list() {
    [[ "$ci_search_snapshot" == 1 ]] || return 0
    printf 'CI signing: restoring the original runner Keychain search list.\n'
    if [[ "${#ci_original_keychains[@]}" -gt 0 ]]; then
        security list-keychains -d user -s "${ci_original_keychains[@]}" || return 1
    else
        security list-keychains -d user -s || return 1
    fi
    security list-keychains -d user > "$temporary/user-keychains.restored" || return 1
    security default-keychain -d user > "$temporary/default-keychain.restored" || return 1
    if ! cmp -s "$temporary/user-keychains.before" "$temporary/user-keychains.restored" ||
        ! cmp -s "$temporary/default-keychain.before" "$temporary/default-keychain.restored"; then
        printf 'The original CI Keychain search list/default could not be verified.\n' >&2
        return 1
    fi
    ci_search_snapshot=0
}
cleanup() {
    status=$?
    trap - EXIT
    restore_failed=0
    if ! restore_ci_search_list; then
        printf 'Failed to restore the original CI Keychain search list.\n' >&2
        status=1
        restore_failed=1
    fi
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    if [[ "$restore_failed" == 1 ]]; then
        # Retain only preference metadata for diagnosing runner cleanup. Never
        # retain the private key, PKCS#12, temporary Keychain or signed probe.
        for entry in "$temporary"/*; do
            case "$entry" in
                */user-keychains.before|*/default-keychain.before) ;;
                *) rm -rf "$entry" ;;
            esac
        done
        printf 'Original CI Keychain preference snapshots retained at %s.\n' "$temporary" >&2
    else
        rm -rf "$temporary"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "$ci_signing" == 1 ]]; then
    # codesign(1), SIGNING IDENTITIES: a signing identity must be in a keychain
    # on the caller's search list. --keychain narrows lookup, not this setup.
    # This branch never runs for ordinary local tests or self-hosted runners.
    security list-keychains -d user > "$temporary/user-keychains.before"
    security default-keychain -d user > "$temporary/default-keychain.before"
    quoted_path='^[[:space:]]*"([^"[:cntrl:]]+)"[[:space:]]*$'
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        if [[ ! "$entry" =~ $quoted_path ]]; then
            printf 'Cannot safely parse the runner Keychain search list.\n' >&2
            exit 1
        fi
        ci_original_keychains+=("${BASH_REMATCH[1]}")
    done < "$temporary/user-keychains.before"
    ci_search_snapshot=1
fi
printf 'Keychain fixture: creating isolated keychain.\n'
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
# Ordinary local tests address the private path explicitly and never snapshot
# or rewrite user preferences. Only hosted CI registers its signer below.
export DBEER_TEST_KEYCHAIN=1
export DBEER_TEST_KEYCHAIN_PATH="$keychain"
printf 'Keychain fixture: ready.\n'

if [[ "$ci_signing" == 1 ]]; then
    cat > "$temporary/signing.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = DBeer CI Ephemeral Signing
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
    printf 'CI signing: generating temporary certificate.\n'
    openssl req -new -newkey rsa:2048 -x509 -sha256 -nodes -days 2 \
        -config "$temporary/signing.cnf" -keyout "$temporary/signing.key" \
        -out "$temporary/signing.crt" >/dev/null 2>&1
    openssl pkcs12 -export -inkey "$temporary/signing.key" -in "$temporary/signing.crt" \
        -out "$temporary/signing.p12" -password "pass:$password" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
    printf 'CI signing: importing temporary identity.\n'
    security import "$temporary/signing.p12" -k "$keychain" -P "$password" \
        -x -T /usr/bin/codesign >/dev/null
    # Self-signed signatures use a certificate-pinned default designated
    # requirement. Signing validity and Keychain identity do not require a
    # system-trusted anchor (Apple TN2206, Trust and Code Signing). Never alter
    # authorizationdb or user/admin trust settings on a headless runner.
    identity="$(openssl x509 -in "$temporary/signing.crt" -noout -fingerprint -sha1 |
        sed 's/.*=//; s/://g')"
    if [[ ! "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
        printf 'Could not identify the temporary signing certificate.\n' >&2
        exit 1
    fi
    printf 'CI signing: authorizing codesign for the temporary key.\n'
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" \
        "$keychain" >/dev/null
    printf 'CI signing: registering the signing keychain on the disposable runner.\n'
    if [[ "${#ci_original_keychains[@]}" -gt 0 ]]; then
        security list-keychains -d user -s "$keychain" "${ci_original_keychains[@]}"
    else
        security list-keychains -d user -s "$keychain"
    fi
    security default-keychain -d user > "$temporary/default-keychain.registered"
    if ! cmp -s "$temporary/default-keychain.before" "$temporary/default-keychain.registered"; then
        printf 'Registering the CI signing keychain changed the default Keychain.\n' >&2
        exit 1
    fi
    security find-certificate -c 'DBeer CI Ephemeral Signing' -p "$keychain" > "$temporary/imported.crt"
    imported_identity="$(openssl x509 -in "$temporary/imported.crt" -noout -fingerprint -sha1 |
        sed 's/.*=//; s/://g')"
    if [[ "$identity" != "$imported_identity" ]]; then
        printf 'The imported CI signing certificate does not match its SHA-1.\n' >&2
        exit 1
    fi
    security find-identity -p codesigning "$keychain" > "$temporary/identities.txt"
    identity_count="$(awk -v wanted="$identity" '/Valid identities only/ { exit } $2==wanted { count++ } END { print count+0 }' "$temporary/identities.txt")"
    printf 'CI signing: imported certificate SHA-1 matches; scoped matching identities=%s.\n' "$identity_count"
    if [[ "$identity_count" != 1 ]]; then
        printf 'The temporary signing certificate/private-key pair is unavailable.\n' >&2
        exit 1
    fi
    printf 'CI signing: verifying unattended signing without trust changes.\n'
    probe="$temporary/signing-probe"
    # Compile fresh arm64 code. Re-signing a copied Apple platform executable
    # can leave platform/arm64e restrictions or a stale kernel signature cache.
    printf 'int main(void) { return 0; }\n' > "$temporary/signing-probe.c"
    xcrun clang -arch arm64 -mmacosx-version-min=14.0 \
        -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
        "$temporary/signing-probe.c" -o "$probe"
    codesign --force --timestamp=none --keychain "$keychain" --sign "$identity" "$probe"
    codesign --verify --strict "$probe"
    "$probe"
    printf 'tampered' >> "$probe"
    if codesign --verify --strict "$probe" > "$temporary/tamper.log" 2>&1; then
        printf 'The temporary signing verification accepted modified code.\n' >&2
        exit 1
    fi
    rm -f "$probe" "$temporary/tamper.log"
    export DBEER_SIGNING_KEYCHAIN="$keychain"
    export DBEER_SIGNING_IDENTITY="$identity"
    export DBEER_CI_SIGNING=1
    printf 'CI signing: ready.\n'
fi
printf 'Keychain fixture: running requested command.\n'
"$@"
