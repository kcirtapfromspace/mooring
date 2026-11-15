# Mooring 0.3.0 preview 46 — Internet Links and X11

**Release candidate, build 51.** The source is ready for testing.
The Mac download is not yet notarized or published.
The signed public download remains preview 45.

## Included changes

- Add experimental Internet Links with a Rust Iroh/QUIC transport.
- Support direct UDP and an explicit HTTPS relay.
- Keep the existing Noise pairing check for native Mac sessions.
- Add an arm64 Linux helper that forwards only to the host's loopback SSH server.
- Add `mooring-link ssh-session` for concurrent Linux video and control channels.
- Stop owned SSH processes and remove temporary configuration when the command ends.
- Separate SSH control sockets by remote host, port, and account.
- Include X11/x11vnc support and display restoration for desktops with no active monitor.
- Separate domain rules, application workflows, and platform adapters.
- Pin the local native build graph and toolchains.
- Update the README, feature guide, architecture guide, and GitHub Pages site.

Source builds include the experimental Internet menu and helper by default.
A disabled build retains the rejecting Internet ABI stubs.
The feature requires no Mooring account.
Mooring does not operate a hosted relay.

## Setup

For Macs, use the same candidate on both devices.
Pair the Macs through the existing pairing flow.
Then choose **Mooring → Internet Connections (Experimental)**.
Approve the viewer's Internet ID and exchange an expiring locator.

For Linux, start the helper with an approved Internet ID and use `ssh-session` on the Mac.
The child Mooring command receives the temporary SSH configuration.
The Linux connection form does not yet select a locator.
Read [Internet Links](INTERNET-CONNECTIVITY.md) before setup.

## Validation and limits

Full local validation passed, including 369 Rust tests, strict Clippy, native workflows, media fixtures, and app packaging.
Live forced-relay SSH checks passed on Omarchy and the Jetson.
The owned SSH workflow passed with two concurrent channels and verified configuration cleanup.
A graphical Jetson desktop was displayed through the relay in the preceding live demonstration.

Direct-only live testing timed out on the test network.
A real two-Mac desktop session through the new Internet transport remains an acceptance check.
Linux sound, clipboard, and gesture sharing are not included.
Automatic stream quality selection remains a simulation.
See the [validation record](INTERNET-VALIDATION.md).

## Delivery status

The Mac artifact requires a valid Developer ID Application identity and notarytool profile on the build Mac.
The current build Mac reports no valid signing identity.
No unsigned archive replaces the signed update feed.
Apple silicon and macOS 14 or later remain required.
All builds and tests run on the local Mac.
GitHub Actions remains disabled.
