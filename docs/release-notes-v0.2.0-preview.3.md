# MacLink 0.2.0 preview 3 — Add your Mac and connect

Enter an address and click **Add & Connect**. Auto mode, full screen and reconnection on familiar networks are now the defaults. Name and port are optional under More Options; detailed tuning is tucked into Settings → Advanced.

The first connection asks for macOS Accessibility access where it is needed. Choose **Enable & Connect**, grant access in the system pane, and MacLink continues automatically. **Connect Without Automation** remains available. Apple Screen Sharing handles sign-in.

No manual home marking or capability checkbox is required to start. MacLink learns a target-specific direct Wi-Fi/Ethernet path only after an explicitly initiated, identified session and 35 seconds of healthy checks on the same network. Auto starts with Standard and can later make one bounded High Performance trial per path during the app run. Trial permission is separate from verified capability; VPN and unknown paths remain conservative by default. Legacy confirmed-support overrides remain available.

Saved Macs and previously configured preferences are preserved, including disabled automation and display choices. Old unconfigured installations adopt the new defaults. Familiar paths are deduplicated and bounded; explicit connection selection does not itself mark a network familiar. Closing a managed session still pauses automation.

Local validation includes 67 Rust tests, 73 Swift session-parser checks, expanded defaults/home-state regressions and CLI integration. Apple silicon only; distribution uses Developer ID signing, notarization and a stapled ticket. All CI and builds remain on the local host; GitHub Actions is disabled.

Apple's mode URL options remain experimental. TCP/RFB checks do not measure video bandwidth, and router bridges can hide a change of location. Actual two-Mac negotiation, full-screen behavior and performance still need live testing.
