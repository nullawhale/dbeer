#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in /usr/bin/ssh /usr/bin/ssh-keygen /usr/sbin/sshd /usr/bin/nc; do
    [[ -x "$tool" ]] || { printf 'Required OpenSSH route fixture tool is unavailable: %s\n' "$tool" >&2; exit 1; }
done
mkdir -p "$repo_root/build/r29/tmp" "$repo_root/build/.cache/go"
export TMPDIR="$repo_root/build/r29/tmp"
export GOCACHE="$repo_root/build/.cache/go" GOMODCACHE="$repo_root/build/.cache/go-mod"
export DBEER_TEST_SSH_CONFIG=1
cd "$repo_root/helper"
go test -race -count=1 -timeout 2m -run '^TestSSHConfiguration' ./internal/sshtunnel
