#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
require_postgres="${DBEER_REQUIRE_POSTGRES:-0}"
for argument in "$@"; do
    case "$argument" in
        --require-postgres) require_postgres=1 ;;
        *) printf 'Usage: %s [--require-postgres]\n' "$0" >&2; exit 2 ;;
    esac
done
if [[ "$require_postgres" == 1 && -z "${DBEER_TEST_DSN:-}" ]]; then
    printf 'PostgreSQL is required, but DBEER_TEST_DSN is missing. No tests were run.\n' >&2
    exit 1
fi

mkdir -p "$repo_root/build/.cache"
export GOCACHE="$repo_root/build/.cache/go"
export GOMODCACHE="$repo_root/build/.cache/go-mod"
if [[ -n "${DBEER_TEST_DSN:-}" ]]; then
    printf 'Running Go race tests with PostgreSQL integration.\n'
else
    printf 'Running Go race tests; PostgreSQL integration skips without DBEER_TEST_DSN.\n'
fi
cd "$repo_root/helper"
# Integration packages share one database; never run them concurrently or cached.
go test -race -count=1 -p 1 ./...
