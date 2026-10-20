#!/usr/bin/env bash
set -euo pipefail
umask 077
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$repo_root/prototypes/gpui/verification/run.py" "$@"
