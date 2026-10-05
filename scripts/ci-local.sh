#!/bin/bash
# Intentionally local only. This repository has no GitHub Actions workflows.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    printf '%s\n' 'Run validation on the local development Mac, not GitHub Actions.' >&2
    exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' 'This validation entry point requires the local macOS build host.' >&2
    exit 1
fi
rustc --version
cargo --version
sw_vers
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace
./scripts/test-native.sh
./scripts/build-app.sh
python3 scripts/test-network-cli.py dist/Mooring.app/Contents/Resources/mooring
printf '%s\n' 'Local validation passed.'
