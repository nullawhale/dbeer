#!/usr/bin/env bash
set -euo pipefail

# SwiftPM 6.1 preserves resource symlinks. Their source-relative targets are
# invalid in the built bundle, so retain the original asset bytes there.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" != 1 || ! -d "$1" ]]; then
    printf 'Usage: %s built-resource-bundle\n' "$0" >&2
    exit 2
fi
resources="$1"
if [[ -d "$resources/Contents" ]]; then resources="$resources/Contents/Resources"; fi
mkdir -p "$resources"
for engine in postgresql mysql cassandra; do
    destination="$resources/$engine-logo.svg"
    if [[ -L "$destination" ]]; then rm -- "$destination"; fi
    if ! cmp -s "$repo_root/assets/$engine-logo.svg" "$destination"; then
        cp "$repo_root/assets/$engine-logo.svg" "$destination"
    fi
done
