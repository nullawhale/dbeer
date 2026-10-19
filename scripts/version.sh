#!/usr/bin/env bash
# Shared by build/release scripts; keep release metadata in these two files.
dbeer_version_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dbeer_version="$(cat "$dbeer_version_root/VERSION")"
dbeer_build_number="$(cat "$dbeer_version_root/BUILD_NUMBER")"
if [[ ! "$dbeer_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
   [[ ! "$dbeer_build_number" =~ ^[1-9][0-9]*$ ]]; then
    printf 'VERSION must contain x.y.z; BUILD_NUMBER must contain a positive integer.\n' >&2
    return 1 2>/dev/null || exit 1
fi
