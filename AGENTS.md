# MacLink working rules

- Target Apple silicon (arm64) and macOS 14 or later. Do not build Intel or universal artifacts unless the user changes this requirement.
- Run all CI, tests, builds, signing, and packaging on this local Mac. Do not add GitHub Actions workflows or enable GitHub Actions. GitHub is for source and release assets only.
- Validate a release with `./scripts/ci-local.sh`, then `./scripts/package-release.sh VERSION`. Keep downloaded-app and real two-Mac checks distinct from local tests.
- Preserve existing user connections. Never commit application-support data, passwords, pairing secrets, clipboard contents, or captured screens.
- The current Apple backend launches Screen Sharing; it cannot claim automatic High Performance mode selection. Show actual supported behavior in the UI.
- `maclink-core` policies and simulations are not wired into Apple sessions. Do not present simulated metrics as measured performance.
- Swift/AppKit is a thin native shell; keep policy, validation, persistence, and protocol work in Rust. Use public Apple media APIs through a small, well-defined boundary.
- Keep queues, messages, timeouts, and retry budgets bounded. Input cleanup and stale-frame recovery matter more than an average FPS number.
- Evaluate source licenses before reusing external protocol implementations. No AGPL implementation code has been included in this MIT project.
