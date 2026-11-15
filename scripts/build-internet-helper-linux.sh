#!/bin/bash
# Cross-compile on the local Apple-silicon Mac, including Jetson Ubuntu 18.04.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
[[ "$(uname -s)" = Darwin && "$(uname -m)" = arm64 ]] || { printf '%s\n' 'Build on the local Apple-silicon Mac.' >&2; exit 1; }
export DEVELOPER_DIR="$(python3 scripts/native-targets.py setting developerDir)"
python3 scripts/native-targets.py toolchain
# These local tool directories are optional; compatible tools may be on PATH.
export PATH="$project_root/target/tools/zig-aarch64-macos-0.14.1:$project_root/target/tools/cargo-zigbuild/bin:$PATH"
[[ "$(zig version)" = 0.14.1 ]] || { printf '%s\n' 'Requires Zig 0.14.1.' >&2; exit 1; }
[[ "$(cargo-zigbuild --version)" = 'cargo-zigbuild 0.24.1' ]] || { printf '%s\n' 'Requires cargo-zigbuild 0.24.1.' >&2; exit 1; }
rustup target list --installed | /usr/bin/grep -Fqx aarch64-unknown-linux-gnu || {
    printf '%s\n' 'Install the Rust target: rustup target add aarch64-unknown-linux-gnu' >&2; exit 1;
}
cargo zigbuild --locked --release -p mooring-connectivity --bin mooring-link --target aarch64-unknown-linux-gnu.2.27
output="$project_root/dist/mooring-link-linux-arm64"
mkdir -p "$output"
cp target/aarch64-unknown-linux-gnu/release/mooring-link "$output/mooring-link"
cp LICENSE "$output/LICENSE"
python3 scripts/collect-licenses.py --target aarch64-unknown-linux-gnu --output "$output/THIRD-PARTY-NOTICES.txt"
cp docs/INTERNET-CONNECTIVITY.md "$output/README.md"
(cd "$output" && shasum -a 256 mooring-link > mooring-link.sha256)
printf 'Built %s (arm64, glibc 2.27 or later)\n' "$output"
