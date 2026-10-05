# Mooring 0.3.0 preview 36 — Mooring throughout

The app, command-line tool, source packages, documentation, and new release downloads now use Mooring throughout. The About window no longer carries a former-name line, and permission instructions, virtual displays, diagnostics, logs, and pairing labels use Mooring.

- New downloads contain `Mooring.app`, the `Mooring` executable, and the `mooring` CLI.
- The GitHub repositories, release titles, and release descriptions use the Mooring brand.
- Existing app updates preserve their installation location. Saved Macs, paired-device keys, preferences, and the established protocol remain compatible.
- Fresh installations store data under `~/Library/Application Support/Mooring`. Existing installations keep their data directory so older running copies share the same store and locks. `MOORING_HOME` selects an explicit directory.

The local Apple silicon validation passed: Rust checks, native media and input, encrypted loopback streaming, packaged CLI, and app build. A separate update test uses the actual previous preview under an isolated identity and verifies the renamed executable and CLI, legacy-feed redirect, relaunch, and refusal of a tampered archive and altered feed. No real credentials or saved connections enter those tests.

Native sessions remain experimental. Downloaded-app behavior, permissions, real two-Mac connections, and Apple mode switching remain separate acceptance checks. Historical signed archives and a few opaque compatibility identifiers remain stable so already installed copies can update safely.
