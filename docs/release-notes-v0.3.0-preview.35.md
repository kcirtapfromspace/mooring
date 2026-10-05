# Mooring 0.3.0 preview 35 — Mooring repositories

The GitHub repositories now match the product name: source is in `kcirtapfromspace/mooring`, and public downloads and updates are in `kcirtapfromspace/mooring-releases`.

Existing installations follow the old release URL through GitHub's redirect. This update carries the canonical Mooring feed URL, so later checks use the new name directly. The Developer ID, Sparkle signing key, app bundle identifier, packaging and saved-data paths stay compatible. Saved Macs and pairings carry forward.

This preview also includes preview 34's UX changes: a separate **Recent Macs** section with three quick connections and a **More Macs** flyout, plus a sharing badge on the Mooring menu bar logo once screen capture starts for a connected viewer. The macOS privacy indicator remains separate.

## Validation

Full local Apple silicon CI passed, including 232 Rust tests, native media and session checks, menu checks, encrypted loopback streaming, packaged CLI integration and the arm64 macOS 14 app build. The local updater test verified an installed build following a legacy feed redirect, verifying and installing the signed archive, relaunching with the canonical feed URL, and refusing a tampered archive and an altered feed. The old and new public download URLs were checked separately.

Real two-Mac sessions, live sharing badge transitions, Apple mode switching and downloaded-app launch remain separate acceptance checks. Use **Check for Updates…** on each Mac to test this preview; updates install while idle. Distribution is Developer ID signed, notarized and stapled. Builds and tests run locally, with GitHub Actions disabled.
