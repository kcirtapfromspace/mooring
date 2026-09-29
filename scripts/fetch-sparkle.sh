#!/bin/bash
# Fetches the pinned Sparkle release (MIT, with the notices in its LICENSE) into
# target/vendor and verifies its SHA-256, then prints the directory holding
# Sparkle.framework and Sparkle's signing tools. Later runs use the verified copy.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version=2.10.0
checksum=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
directory="$project_root/target/vendor/sparkle-$version"
if [[ ! -f "$directory/.verified" ]]; then
    mkdir -p "$project_root/target/vendor"
    archive="$(mktemp "$project_root/target/vendor/sparkle.XXXXXX")"
    trap 'rm -f "$archive"' EXIT
    curl -fsSL --retry 3 -o "$archive" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
    if ! printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c - >/dev/null; then
        printf 'Sparkle %s did not match its pinned checksum.\n' "$version" >&2
        exit 1
    fi
    rm -rf "$directory"
    mkdir -p "$directory"
    tar -xf "$archive" -C "$directory"
    touch "$directory/.verified"
fi
printf '%s\n' "$directory"
