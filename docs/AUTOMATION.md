# Menu-bar automation preview

MacLink stays in the menu bar when its Connections window closes. New installations use Auto mode, full screen and reconnection on familiar networks by default. An explicit Connect selects the Mac to manage; browsing saved Macs does not. Existing configured preferences, including disabled automation, are preserved. Only old installations without a selected target adopt the new defaults.

## Connect

1. Choose **Add Mac**, enter its hostname or IP, and click **Add & Connect**. Name and port are optional under **More Options**; the default port is 5900.
2. On the first connection, choose **Enable & Connect** and grant MacLink Accessibility access in the system pane. The connection continues when macOS reports access. **Connect Without Automation** opens a manual session instead. If skipped, access remains available through **Enable Full Screen & Auto Switching** in the menu.
3. Sign in through Apple Screen Sharing if prompted. Passwords remain in Apple's flow. No home marking or support checkbox is needed to connect.

Settings is optional. It contains display mode, full screen, reconnect and login preferences. **Advanced** contains automation controls, manual home paths, confirmed-support and VPN overrides. Login launch remains optional; install the app in Applications before enabling it.

## Learning and mode decisions

- An explicitly initiated connection can teach MacLink a familiar path only after its session is uniquely identified and connection checks remain healthy for 35 seconds on the same network generation. The target route must be direct Wi-Fi or Ethernet, and a local network fingerprint must be available. Network changes, sleep/wake and cancellation invalidate learning. Familiarity is specific to the saved Mac; up to eight deduplicated paths are retained.
- The fingerprint uses this Mac's physical interface, gateway and cached router hardware address. It needs no SSID or Location Services permission. It indicates familiarity, not authentication, physical location or bandwidth. Wi-Fi and Ethernet may differ. A travel bridge can reproduce the same network identity, and a tunnel inside a router may be invisible to macOS.
- One credential-free RFB probe runs at a time, normally every three seconds. It reads the 12-byte greeting without logging in. TCP setup and greeting timings exclude DNS; the entire helper has a six-second deadline. These measurements do not measure throughput, packet loss, video quality or input latency.
- Auto starts in Standard. On a familiar, known direct Wi-Fi/Ethernet path, it can make an experimental High Performance request without asserting remote capability. Promotion still requires eight healthy samples over 30 seconds, TCP setup ≤20 ms, greeting ≤40 ms, recent TCP spread ≤12 ms, and a 30-second mode residence. Learning the path resets policy evidence, so the first trial takes additional observation time.
- An unconfirmed automatic trial is limited to once per target/path during an app run; the set of attempted paths is capped at 32. Continuing the current requested High Performance session does not spend a new trial. Failure/fallback does not authorize repeated trials on that path. These limits are separate from the three-launch and Rust switch budgets.
- Auto keeps identified VPN/tunnel and unknown routes in Standard by default. Existing explicit capability confirmation and path/VPN overrides retain their behavior; an override never makes an unknown route eligible in the network policy. Choosing **Prefer High Performance** in Settings can explicitly request it when connecting. Trial permission, a fast RFB reply and an exported mode document do not independently prove support.
- Two adverse observations spanning two seconds can recommend Standard, subject to a 30-second mode residence. Unknown routes, stale evidence or lost eligibility force conservative policy fallback. Automatic reconnects are spaced by at least 30 seconds. Outage probes back off and eventually slow to one per minute.

## Session behavior

Automatic opening on a learned or manually approved path requires 35 seconds of healthy checks, Accessibility access and unpaused automation. A new installation has no selected target or learned path, so it waits for the first explicit connection. Legacy manually marked home paths still work. Optional **Detect Network → Use This Network as Home** controls in Advanced work independently of the remote Mac; missing router-cache information or an ambiguous physical path produces an explanation instead of waiting indefinitely.

A mode change closes and reopens the matching session. MacLink manages only a new, unique standard window whose exported `.vncloc` matches the expected host, port and requested mode. It leaves existing or ambiguous windows alone and verifies that the old managed window disappears before opening a replacement. Avoid starting another same-host/same-mode connection during launch, since it may be indistinguishable.

Three launches per active automation run and a separate Rust switch budget limit repeated changes. Pause cancels queued actions. Resume, explicit Connect or selecting a different target resets the app launch budget, but does not clear attempted trial paths. Closing the managed window pauses automation. A viewer exit also pauses because MacLink cannot distinguish a crash from Quit; the next automatic attempt uses Standard. Explicitly connect or resume when ready.

Full screen means Apple's viewer occupies a macOS full-screen Space; it is not embedded in a MacLink tab. Leaving full screen yourself should remain respected for that session. MacLink never types passwords, approves authentication dialogs or grants its own permissions.

## Remaining verification

Apple's mode URLs are undocumented. Its exported connection document records requested options, not independently verified video negotiation. If Apple omits that document, rewrites the endpoint, reuses a window, rejects the requested mode or leaves a dialog unresolved, MacLink pauses instead of managing an uncertain session. High Performance may use a virtual display and blank the remote physical display.

There is no custom host, Rust video renderer or live video congestion controller. Local tests do not validate actual mode transitions, full screen, hotel bandwidth restrictions, decoder crashes or two-Mac performance. See [TESTING.md](TESTING.md) for live checks and [compatibility evidence](automation-research.md) for the URL research.
