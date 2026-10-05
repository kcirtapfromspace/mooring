# Mooring 0.2.0 preview 1

Mooring now lives in the macOS menu bar with quick Connect, Auto/Standard/Prefer High Performance, Pause/Resume and Settings controls. It remembers separate home Wi-Fi and Ethernet paths, checks the route and TCP/RFB response of your saved Mac, and waits for sustained good conditions before recommending High Performance. Optional login launch and automatic home opening are included.

The experimental session controller requests modes using Apple's own exported URL format, identifies a unique matching Screen Sharing window through Accessibility, enters full screen and reconnects after a policy change. Switching disconnects the current session; closing the window or quitting the viewer pauses automation. Ambiguous windows are left alone. Repeated attempts are capped.

**Setup:** replace the earlier Mooring app, open its menu → Settings, choose your Mac, mark each home path, confirm High Performance support, grant Accessibility, and enable automation/full screen. Passwords remain in Apple's sign-in flow. Existing saved Macs are preserved.

**Limits:** the mode URL format is undocumented. Actual Apple mode negotiation, full screen and reconnect behavior still need testing on two Macs. Network checks measure reachability and handshake timing, not bandwidth, packet loss or video lag. A Ubiquiti travel bridge may look identical to home. There is no custom streaming engine. Full screen uses Apple's macOS Space, not an embedded Mooring tab.

Apple silicon only; macOS 14+. Developer ID signed, Apple notarized and stapled. Local validation includes 58 Rust tests, 73 Swift parser/file checks, packaged CLI loopback integration, and isolated UI checks. All builds, tests and signing ran locally; GitHub Actions remains disabled. See the attached TESTING.md for the two-Mac checklist.
