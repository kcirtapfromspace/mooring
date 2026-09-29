# MacLink

A small native Mac connection app with a Rust core. The product goal is reliable, responsive Mac-to-Mac remote control that chooses sensible quality automatically.

**Current milestone:** working native launcher, saved connections, bounded connection diagnostics, and a simulated adaptive-quality/session core. Connections open Apple Screen Sharing. MacLink does **not yet** render remote video, switch Apple's High Performance mode, or automatically reconnect an Apple session. There is no claim of performance parity with Apple.

## Run

Requires macOS 14 or newer, Xcode Command Line Tools, and Rust 1.89 or newer. Apple High Performance additionally requires compatible Apple silicon Macs at both ends.

```sh
./scripts/build-app.sh
open dist/MacLink.app
```

Add a Mac by hostname or IP, then click **Connect**. **Check Connection** only reads the server's initial RFB greeting; it does not authenticate or demonstrate High Performance support. Use Apple Screen Sharing to authenticate and select the display mode. MacLink never asks for or stores a remote password.

Builds and GitHub preview releases target Apple silicon (arm64) only. The first preview is ad hoc signed and not notarized. The [notarization workflow](docs/NOTARIZATION.md) prepares Developer ID signed, Apple-verified releases when a local notarization Keychain profile is configured. See [testing on another Mac](docs/TESTING.md).

## CLI

```sh
cargo run -p maclink-cli -- doctor
cargo run -p maclink-cli -- add --name 'Studio' --host studio.local
cargo run -p maclink-cli -- list
cargo run -p maclink-cli -- inspect SAVED_ID
cargo run -p maclink-cli -- connect SAVED_ID
cargo run -p maclink-cli -- simulate
```

`simulate` is synthetic telemetry, not a live performance benchmark. Commands return JSON; failures return a nonzero status with a readable error on stderr. Use `--config-dir PATH` before the command, or set `MACLINK_HOME`, for an isolated connection store. The default store is `~/Library/Application Support/MacLink/connections.json`; writes are atomic and serialized across app/CLI processes. Saved files use owner-only permissions.

## Layout

- `crates/maclink-core`: quality policy, a bounded latest-frame mailbox, and reconnect policy. Future streaming backends can consume these; the Apple launcher does not.
- `crates/maclink-platform`: validated Apple Screen Sharing launch URLs and read-only RFB greeting diagnostics.
- `crates/maclink-cli`: JSON command interface and persistent saved Macs.
- `app`: thin native Swift/AppKit shell; Rust handles connection validation, diagnostics, and storage.
- `scripts/probe-codecs.swift`: public VideoToolbox capability probe; no screen capture or transmission.
- `docs/apple-backend.md`: Apple interoperability research and limitations.
- `docs/performance.md`: proposed performance targets and measurement method.
- `docs/roadmap.md`: acceptance gates for the real remote-desktop engine.

## Verify

All CI runs on the local development Mac. GitHub Actions is disabled for this repository, and no Actions workflows are included. Run `./scripts/ci-local.sh` for the complete local check.

```sh
cargo fmt --all -- --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
./scripts/build-app.sh
swift scripts/probe-codecs.swift
```

Network tests use loopback mock RFB servers. No test enables remote sharing, captures the desktop, stores credentials, or connects to a real remote Mac.

The original source in this project is MIT-licensed. External projects cited in the research retain their own licenses; no iShareScreen implementation code is included.
