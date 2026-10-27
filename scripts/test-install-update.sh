#!/usr/bin/env bash
# Exercise unchanged release archives on the owner Mac, using disposable data.
set -euo pipefail
umask 077
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
    printf 'Usage: %s [--baseline-archive /path/to/DBeer.zip --candidate-app /path/to/DBeer.app]\n' "$0"
}
if [[ "${1:-}" == --help && "$#" == 1 ]]; then usage; exit 0; fi
if [[ "$#" != 0 && ( "$#" != 4 || "$1" != --baseline-archive || "$3" != --candidate-app ) ]]; then
    usage >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    printf 'This acceptance runner requires an Apple Silicon Mac.\n' >&2
    exit 2
fi
if [[ "${CI:-}" == true || "${DBEER_CI_SIGNING:-0}" == 1 ]]; then
    printf 'Installed-archive acceptance requires the owner Mac, not CI.\n' >&2
    exit 1
fi
if [[ "${DBEER_INSTALL_UPDATE_FIXTURES_READY:-0}" != 1 ]]; then
    exec "$repo_root/scripts/test-postgres.sh" "$repo_root/scripts/test-mysql.sh" \
        env DBEER_INSTALL_UPDATE_FIXTURES_READY=1 "$0" "$@"
fi
exec python3 "$repo_root/macos/AcceptanceTests/Support/InstallUpdateFixture.py" "$repo_root" "$@"
