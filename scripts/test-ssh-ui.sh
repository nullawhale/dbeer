#!/usr/bin/env bash
set -euo pipefail
umask 077
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 || "$#" != 0 ]]; then
    printf 'Usage on an Apple Silicon Mac: %s\n' "$0" >&2
    exit 2
fi
for dependency in docker python3 openssl ssh-keygen; do
    command -v "$dependency" >/dev/null || { printf 'SSH UI acceptance requires %s.\n' "$dependency" >&2; exit 1; }
done
docker info >/dev/null
"$repo_root/macos/AcceptanceTests/run.sh" --build-only
output="$repo_root/build/AcceptanceTests"
developer_directory=/Applications/Xcode.app/Contents/Developer
sdk_path="$(DEVELOPER_DIR="$developer_directory" /usr/bin/xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$output"
chmod 700 "$output"
DEVELOPER_DIR="$developer_directory" /usr/bin/xcrun --sdk macosx swiftc \
    -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path "$output/ssh-credential-cache" \
    "$repo_root/macos/AcceptanceTests/Support/SSHFixtureCredentials.swift" -o "$output/ssh-fixture-credentials"
# Modern Keychain partition ACLs follow the creator's signing team as well as
# the explicit trusted-app list. Match the installed app's exact persistent
# certificate so the signed app can read these synthetic items without a prompt.
certificate_directory="$(mktemp -d "$output/credential-signing.XXXXXX")"
trap 'rm -rf -- "$certificate_directory"' EXIT
codesign --display --extract-certificates="$certificate_directory/cert" "$repo_root/build/DBeer.app" >/dev/null
signing_identity="$(openssl x509 -inform DER -in "$certificate_directory/cert0" -noout -fingerprint -sha1 | awk -F= '{gsub(":", "", $2); print $2}')"
if [[ ! "$signing_identity" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    printf 'Could not identify the signed app persistent certificate.\n' >&2
    exit 1
fi
signing_keychain="${DBEER_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
codesign --force --timestamp=none --keychain "$signing_keychain" --sign "$signing_identity" \
    --identifier dev.dbeer.ssh-fixture-credentials "$output/ssh-fixture-credentials"
codesign --verify --strict "$output/ssh-fixture-credentials"
application_team="$(codesign --display --verbose=4 "$repo_root/build/DBeer.app" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
credential_team="$(codesign --display --verbose=4 "$output/ssh-fixture-credentials" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
if [[ -z "$application_team" || "$application_team" == not\ set || "$credential_team" != "$application_team" ]]; then
    printf 'Credential fixture and signed application must use the same persistent signing team.\n' >&2
    exit 1
fi
python3 "$repo_root/macos/AcceptanceTests/Support/SSHFixture.py" "$repo_root"
