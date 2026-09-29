# MacLink v0.1.0-preview.1

First Apple silicon preview for testing on a second Mac. Requires an Apple silicon Mac (arm64) and macOS 14 or later.

Download **MacLink-v0.1.0-preview.1-macos-arm64.zip**, extract it, and open MacLink.app. Add the other Mac's hostname/IP, check its Screen Sharing service, then connect.

## Included

- Native macOS interface with saved Macs, keyboard shortcuts, and readable connection errors.
- Rust connection validation and atomic storage.
- Bounded RFB greeting diagnostics without signing in.
- Launch of Apple Screen Sharing for the actual remote session.
- Tested experimental Rust quality and reconnect policies for a future streaming backend.

## Current limits

This preview opens Apple Screen Sharing. **Automatic High Performance switching and a custom Rust video engine are not included.** Apple handles sign-in, display mode, and rendering. The app does not store passwords.

The app is signed ad hoc and is **not notarized**. macOS may require approval for a downloaded app. No Intel build is included.

## Validation and downloads

All build, test, signing, and packaging steps ran on the local development Mac. **GitHub Actions is disabled.** GitHub hosts the source and release files only.

- 40 Rust tests passed; formatting and strict Clippy passed.
- Native UI tested using an isolated localhost RFB server.
- Archive architecture and signatures checked locally.
- `SHA256SUMS.txt` verifies the app ZIP.
- `local-validation.txt` records local checks.
- `TESTING.md` explains what to verify on the second Mac.

Live remote performance has not been benchmarked yet. Use Apple's High Performance session as the baseline during this first test.
