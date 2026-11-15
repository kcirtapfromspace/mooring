#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
# Select the reviewed Xcode per process; never change the Mac's global selection.
export DEVELOPER_DIR="$(python3 scripts/native-targets.py setting developerDir)"
python3 scripts/native-targets.py toolchain
python3 scripts/native-targets.py check
mkdir -p target
rust_target="$(python3 scripts/native-targets.py setting rustTarget)"
macos_floor="$(python3 scripts/native-targets.py setting macOS)"
swift_target="$(python3 scripts/native-targets.py setting swiftTarget)"
cargo_args=(--locked --release -p mooring-session -p mooring-cli --target "$rust_target")
if [[ "${MOORING_EXPERIMENTAL_INTERNET:-1}" = 1 ]]; then cargo_args+=(--features mooring-session/internet); fi
MACOSX_DEPLOYMENT_TARGET="$macos_floor" cargo build "${cargo_args[@]}"
clang -fobjc-arc -O2 -Wall -Werror -isysroot "$(xcrun --show-sdk-path)" -target "$swift_target" \
    -c app/NativeVirtualDisplay.m -o target/NativeVirtualDisplay.o
