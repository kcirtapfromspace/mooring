# Menu-bar automation preview

MacLink now stays in the menu bar when its Connections window closes. Existing saved Macs are preserved. Automation starts disabled until you select a target and enable it in Settings; launching a new build does not silently open a remote desktop.

## Setup

1. Add the remote Mac through the menu's Open Connections window.
2. Open Settings and choose the Mac to automate. On your home connection, click Detect Network, then Use This Network as Home. Save after configuring the options below.
3. Confirm that both Macs support Apple's High Performance sharing if you want Auto to consider it. Enable VPN paths only if you want to try High Performance through an identified tunnel.
4. Enable Accessibility for the installed, signed MacLink app using the Settings button. macOS requires you to grant this permission. It enables identification, full screen and closing/reopening the matching viewer window; MacLink never types passwords or approves authentication dialogs.
5. Enable automation, automatic home connection and full screen. Optionally select Launch MacLink at Login. Moving the app to Applications before registering login launch keeps the registered path stable.

Home marking reads this Mac’s physical network interface, gateway and cached router hardware address. It does not resolve or contact the remote Mac, and it works before adding a saved Mac. Existing home preferences from the first automation preview remain supported. It is a preference hint, **not authentication or proof of physical location**. Ethernet and Wi-Fi can produce different fingerprints; mark each while at home. MacLink remembers up to eight home paths and includes Forget Home Paths to clear them. A Ubiquiti travel bridge may reproduce the same path; checks still evaluate timing, but cannot reliably infer your physical location or available bandwidth. No SSID or Location Services permission is required. Detection has a bounded timeout and returns an explanation if the router cache is empty or the physical path is ambiguous. Ordinary network activity can populate the router cache; then retry Detect Network. A target connection check may still fail independently.

## Decisions and actions

- One credential-free RFB probe runs at a time, normally every three seconds. It reads the 12-byte greeting without logging in. TCP setup and greeting time are real measurements; DNS is excluded from those timing values. The app bounds the entire helper process to six seconds.
- High Performance requires explicit capability confirmation, an approved home path or explicit preference/override, a known target route, and at least eight healthy probes spanning 30 seconds. Provisional healthy thresholds are TCP setup ≤20 ms, greeting ≤40 ms and recent TCP spread ≤12 ms. These thresholds do not prove sufficient bandwidth or smooth video.
- Two adverse observations spanning two seconds can recommend Standard, with a 30-second minimum mode residence. Route uncertainty, stale evidence and lost eligibility conservatively reset the policy. The session controller also spaces automatic reconnects by at least 30 seconds.
- Automatic initial opening requires the marked home route and 35 seconds of good reachability checks. Away connections remain available from Connect to Mac. Modes are requested using Apple's native-exported URL format; these are undocumented compatibility options.
- A mode change disconnects and reconnects the session. Only a new, unique standard window whose exported `.vncloc` identifies the expected host, port and requested mode is managed. Existing or ambiguous windows are left alone. A concurrent same-host/same-mode user connection is indistinguishable; avoid opening another connection to that same target during automatic launch.
- MacLink verifies that the old managed window disappears before opening its replacement. Three launches per active automation run and a separate Rust switch budget limit repeated changes. Pause cancels queued mutations. Resume or saving Settings resets the app launch budget.
- Closing the managed window pauses automation. Quitting or losing Screen Sharing also pauses; the app cannot reliably distinguish a crash from a deliberate Quit. Resume uses a conservative Standard fallback after a viewer exit. Explicitly preferring High Performance and manually connecting can request another trial.
- During an outage, probe retries back off. After the short retry budget is exhausted, checks slow to one per minute until the target returns. Network changes and wake invalidate accumulated evidence.
- Full screen means Apple's viewer occupies a macOS full-screen Space. This build does not embed Apple's viewer in a MacLink tab. Exiting full screen yourself should remain respected for that session.

The menu exposes Auto, Standard and Prefer High Performance, plus Pause/Resume. A direct Standard preference can request a reconnect immediately. Prefer High Performance allows a trial; it does not disable fallback. Passwords remain in Apple's authentication flow.

## Limits of this preview

There is no custom host, Rust video renderer, UDP throughput test, frame-loss measurement or live video congestion controller. Tailscale/WireGuard tunnel detection concerns the resolved target route, not whether a VPN app happens to be running. A tunnel inside an external router cannot be detected from the Mac's local interface. The policy cannot diagnose UDP blocking, hotel rate limits or Apple's decoder crashes from TCP timings alone.

Apple's exported connection document confirms only its recorded options. It does not independently prove the negotiated video format. If Apple omits that document from Accessibility, rewrites the endpoint, reuses an existing window, declines the requested mode, or displays an unresolved dialog, MacLink pauses rather than managing an uncertain session. Actual mode transitions and full-screen behavior require the two-Mac checks in TESTING.md.

See [the compatibility evidence](automation-research.md) for why the mode URLs were selected and the remaining verification gates.
