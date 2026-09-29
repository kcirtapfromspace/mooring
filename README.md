# MacLink

A small native Mac connection app with a Rust core. The product goal is reliable, responsive Mac-to-Mac remote control that chooses sensible quality automatically.

**Current milestone:** a menu-bar utility with saved Macs, live target-network checks, conservative mode selection, and an experimental Apple Screen Sharing session controller. It can request Standard or High Performance, enter full screen, and reconnect a uniquely identified session after a sustained policy change. Apple supplies authentication and video. Its mode URL options are undocumented; actual negotiation, full screen, and switching still need two-Mac validation. There is no claim of performance parity or measured video bandwidth.

## Run

Requires macOS 14 or newer, Xcode Command Line Tools, and Rust 1.89 or newer. Apple High Performance additionally requires compatible Apple silicon Macs at both ends.

```sh
./scripts/build-app.sh
open dist/MacLink.app
```

MacLink lives behind a display icon in the macOS menu bar. Add a Mac, then open **Settings** to enable automation, check and mark the current home path, confirm High Performance support, and optionally enable login launch. Grant MacLink Accessibility access there for session tracking and full screen. **Mode Preference** and **Pause Automation** are available directly in the menu. MacLink never asks for or stores a remote password.

Builds and GitHub preview releases target Apple silicon (arm64) only. Download the [menu-bar automation preview](https://github.com/kcirtapfromspace/maclink/releases/tag/v0.2.0-preview.1). Distribution uses Developer ID signing, Apple notarization, and a stapled ticket checked after extracting the final ZIP. Local development builds remain ad hoc by default. See [testing instructions](docs/TESTING.md), [automation behavior](docs/AUTOMATION.md), and the [notarization workflow](docs/NOTARIZATION.md).

## CLI

```sh
cargo run -p maclink-cli -- doctor
cargo run -p maclink-cli -- add --name 'Studio' --host studio.local
cargo run -p maclink-cli -- list
cargo run -p maclink-cli -- inspect SAVED_ID
cargo run -p maclink-cli -- connect SAVED_ID
cargo run -p maclink-cli -- connect-mode SAVED_ID standard
cargo run -p maclink-cli -- network-probe SAVED_ID
cargo run -p maclink-cli -- simulate
```

`simulate` is synthetic telemetry, not a live performance benchmark. Commands return JSON; failures return a nonzero status with a readable error on stderr. Use `--config-dir PATH` before the command, or set `MACLINK_HOME`, for an isolated connection store. The default store is `~/Library/Application Support/MacLink/connections.json`; writes are atomic and serialized across app/CLI processes. Saved files use owner-only permissions.

## Layout

- `crates/maclink-core`: live target-network mode policy plus the separate simulated streaming quality/mailbox/reconnect foundation.
- `crates/maclink-platform`: validated Apple Screen Sharing launch URLs and read-only RFB greeting diagnostics.
- `crates/maclink-cli`: JSON command interface and persistent saved Macs.
- `app`: native menu, settings, network-change notifications and bounded Accessibility session supervision; Rust handles mode policy, connection validation, diagnostics, and saved Macs.
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
