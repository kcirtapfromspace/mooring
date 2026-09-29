# MacLink 0.2.0 preview 2 — Home setup fix

Fixes home-network setup failing or staying on “Checking.” The old check depended on the remote Mac answering Screen Sharing and competed with background connection checks.

Home setup now detects this Mac's local network independently. Open Settings → Detect Network → Use This Network as Home → Save. The remote Mac can be asleep, offline, or not yet added. Repeat while using home Wi-Fi and Ethernet if you want both remembered.

The update also prevents stale replies from restoring an old network, clears the progress state on timeout or network change, moves Home controls above Display, refreshes saved Macs in an already-open Settings window, and saves home preferences even if Launch at Login registration fails. Existing saved Macs and home preferences are preserved.

Detection uses a physical interface, gateway and cached router hardware address; it requests no Wi-Fi location permission and makes no remote connection. If macOS has no cached router identity or the physical path is ambiguous, it gives a clear explanation and allows retry. Router bridges can still make different locations look alike; network identity is a preference hint, not a bandwidth guarantee.

Validated locally with 63 Rust tests, 73 Swift session-parser checks, new home-state regression tests, packaged CLI integration, and isolated UI checks with no saved Mac and an unreachable target. Apple silicon only; Developer ID signed, notarized and stapled. All CI and builds remain local; GitHub Actions is disabled.

Apple mode switching remains experimental and still needs two-Mac validation.
