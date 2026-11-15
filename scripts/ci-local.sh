#!/bin/bash
# Intentionally local only. This repository has no GitHub Actions workflows.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
# Select the reviewed Xcode per process; never change the Mac's global selection.
export DEVELOPER_DIR="$(python3 scripts/native-targets.py setting developerDir)"
if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    printf '%s\n' 'Run validation on the local development Mac, not GitHub Actions.' >&2
    exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' 'This validation entry point requires the local macOS build host.' >&2
    exit 1
fi
python3 scripts/native-targets.py check
python3 scripts/native-targets.py toolchain
rustc --version
cargo --version
sw_vers
cargo fmt --all -- --check
python3 scripts/test-license-supplements.py
cargo clippy --locked --workspace --all-targets --all-features -- -D warnings
cargo test --locked --workspace --all-features
./scripts/test-native.sh
./scripts/build-app.sh
python3 scripts/test-ssh-cli.py dist/Mooring.app/Contents/Resources/mooring
printf '%s\n' 'Local validation passed.'
