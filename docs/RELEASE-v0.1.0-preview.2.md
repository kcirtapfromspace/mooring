# MacLink v0.1.0-preview.2

Fixes the "Apple could not verify MacLink.app" warning from the first preview by distributing a Developer ID signed and Apple-notarized app.

**Apple silicon only (arm64), macOS 14 or later.**

Download **MacLink-v0.1.0-preview.2-macos-arm64.zip**. Quit the previous MacLink, extract the ZIP, and replace the old app with this copy. Saved Macs are preserved. Open the new app; macOS may still show its ordinary downloaded-app confirmation.

## Verification

- Apple notarization accepted, with no issues reported.
- Ticket stapled to the app and verified after extracting the final ZIP.
- Gatekeeper: **accepted — Notarized Developer ID**.
- Both executables use hardened runtime and secure timestamps.
- 40 Rust tests, formatting, and strict Clippy passed locally.
- GitHub Actions remains disabled; builds and validation run on the local Mac. Apple performs the required notarization scan.

Assets include the app ZIP, `SHA256SUMS.txt`, `local-validation.txt`, `notarization-validation.txt`, and `TESTING.md`.

## Scope

This remains a native connection launcher with a Rust core. Apple Screen Sharing handles the actual remote session. Automatic High Performance switching and a custom video engine are not included yet. No remote passwords are stored by MacLink.
