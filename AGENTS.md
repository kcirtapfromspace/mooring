# MacLink working rules

- Target Apple silicon (arm64) and macOS 14 or later. Do not build Intel or universal artifacts unless the user changes this requirement.
- Run all CI, tests, builds, signing, and packaging on this local Mac. Do not add GitHub Actions workflows or enable GitHub Actions. GitHub is for source and release assets only.
- Validate a release with `./scripts/ci-local.sh`, then use `./scripts/notarize-release.sh VERSION` with configured Developer ID and Keychain profile environment variables for distributable downloads. `package-release.sh` produces development archives without notarization. Keep downloaded-app and real two-Mac checks distinct from local tests.
- Preserve existing user connections. Never commit application-support data, passwords, pairing secrets, clipboard contents, or captured screens.
- The Apple backend requests modes through native-exported, undocumented URL options. Never equate a launch or exported document with independently verified video negotiation. Real two-Mac switching remains a release test gate.
- The Rust network policy consumes live TCP/RFB target checks in the menu-bar app. These do not measure bandwidth, loss, or video latency. The separate streaming quality policy remains simulated.
- Accessibility may manage only a unique new session window matching the requested endpoint and exported mode. Pause on ambiguity; never close all windows, type credentials, or terminate Screen Sharing to switch modes. Check cancellation before AX mutations.
- Swift/AppKit is a thin native shell; keep policy, validation, persistence, and protocol work in Rust. Use public Apple media APIs through a small, well-defined boundary.
- Keep queues, messages, timeouts, and retry budgets bounded. Input cleanup and stale-frame recovery matter more than an average FPS number.
- Evaluate source licenses before reusing external protocol implementations. No AGPL implementation code has been included in this MIT project.
