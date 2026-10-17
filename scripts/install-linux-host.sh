#!/bin/sh
# Build on the Linux target and install only the host binary for the current user.
set -eu
if [ "$(uname -s)" != Linux ]; then
    echo 'Run this installer on the Linux/Omarchy target.' >&2
    exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
    echo 'Run as your desktop user, without sudo.' >&2
    exit 1
fi
for tool in cargo cc wf-recorder hyprctl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing dependency: $tool (see docs/LINUX.md)" >&2; exit 1; }
done
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
# Avoid inheriting a nonstandard Cargo target/output directory into installation paths.
unset CARGO_TARGET_DIR CARGO_BUILD_TARGET
cargo test --locked -p mooring-linux-host
cargo build --locked --release -p mooring-linux-host
install -d "$HOME/.local/bin"
install -m 755 target/release/mooring-linux-host "$HOME/.local/bin/mooring-linux-host"
printf '%s\n' "Installed $HOME/.local/bin/mooring-linux-host" 'See docs/LINUX.md to grant input access and start sharing inside Hyprland.'
