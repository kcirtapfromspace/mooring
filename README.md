# MacLink

A small native Mac connection app with a Rust core. The product goal is reliable, responsive Mac-to-Mac remote control that chooses sensible quality automatically.

**Current milestone:** enter a Mac's address and connect. Auto mode, full screen and reconnection on learned networks are the defaults. MacLink can request Standard or High Performance and supervise a uniquely identified Apple Screen Sharing session. Apple supplies authentication and video. Its mode URL options are undocumented; actual negotiation, full screen, and switching still need two-Mac validation. There is no claim of performance parity or measured video bandwidth.

**Experimental:** a direct native session. **Share This Mac** captures the main display with ScreenCaptureKit and hardware H.264; **Connect with MacLink** pairs with a copied code and views or controls it over an encrypted, authenticated LAN connection. Sharing can start automatically and continues without its window. A dropped viewer reconnects on its own, and the clipboard is shared both ways while connected. Trackpad pinch, rotate and smart zoom reach the remote Mac. With Accessibility on the viewing Mac, ⌘-Tab and other system shortcuts go to the remote Mac. Early two-Mac testing is in progress. Live telemetry and tuning (`maclink telemetry`, `maclink tune`) are described in [TELEMETRY.md](docs/TELEMETRY.md). MacLink updates itself in place from [maclink-releases](https://github.com/kcirtapfromspace/maclink-releases) when no session is connected. See the [release notes](docs/release-notes-v0.3.0-preview.11.md) for limits.

## Run

Requires macOS 14 or newer, Xcode Command Line Tools, and Rust 1.89 or newer. Apple High Performance additionally requires compatible Apple silicon Macs at both ends.

```sh
./scripts/build-app.sh
open dist/MacLink.app
```

MacLink lives behind a display icon in the macOS menu bar. Choose **Add Mac**, enter its hostname or IP, and click **Add & Connect**. On the first connection, **Enable & Connect** opens macOS Accessibility settings; once you grant access, the connection continues automatically. You can also connect without automation. Sign in through Apple Screen Sharing if prompted. MacLink never asks for or stores a remote password.

No home-network marking or capability checkbox is required to start. Auto starts with Standard and learns a direct network after an explicitly opened, identified session and sustained healthy checks. It may then make a bounded High Performance trial without claiming that support or bandwidth has been verified. Settings contains optional display, login and connection preferences; **Advanced** contains home overrides and detailed tuning. Previously configured preferences are preserved.

Builds and GitHub preview releases target Apple silicon (arm64) only. Download the [native session preview](https://github.com/kcirtapfromspace/maclink/releases/tag/v0.3.0-preview.3). Distribution uses Developer ID signing, Apple notarization, and a stapled ticket checked after extracting the final ZIP. Local development builds remain ad hoc by default. See [testing instructions](docs/TESTING.md), [automation behavior](docs/AUTOMATION.md), and the [notarization workflow](docs/NOTARIZATION.md).

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
cargo run -p maclink-cli -- telemetry --count 5
cargo run -p maclink-cli -- tune --bitrate-mbps 15
```

`simulate` is synthetic telemetry, not a live performance benchmark. Commands return JSON; failures return a nonzero status with a readable error on stderr. Use `--config-dir PATH` before the command, or set `MACLINK_HOME`, for an isolated connection store. The default store is `~/Library/Application Support/MacLink/connections.json`; writes are atomic and serialized across app/CLI processes. Saved files use owner-only permissions.

## Layout

- `crates/maclink-core`: live target-network mode policy plus the separate simulated streaming quality/mailbox/reconnect foundation.
- `crates/maclink-platform`: validated Apple Screen Sharing launch URLs and read-only RFB greeting diagnostics.
- `crates/maclink-cli`: JSON command interface and persistent saved Macs.
- `crates/maclink-session`: experimental native session (static library): encrypted transport, typed wire formats and validation, per-role policy, host input state, pairing codes and saved peers. See its [README](crates/maclink-session/README.md).
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
