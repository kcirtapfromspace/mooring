# MacLink 0.3.0 preview 32 — Streamed viewer diagnostics

The native viewer's diagnostic footer can now be hidden, and Stats for Nerds shows live session measurements over the picture. Existing connections, pairings, and preferences are preserved.

## Viewer changes

- **View → Diagnostic Footer** (⌃⌘D) hides or restores the footer and gives its space back to the picture. The choice is remembered and also appears in **Settings → Viewing**.
- **View → Stats for Nerds** (⌃⌘I) opens a scrollable overlay with actual received codec and resolution, verified hardware decoding, throughput, frame rates, synchronized screen-to-display latency, network RTT, recovery counters, and audio buffer details.
- Measurements push updates as receive, decode, presentation, audio, and peer telemetry events arrive. Bursts are coalesced to at most 10 UI updates per second. There is no repeating UI refresh timer or diagnostic polling. Local rates cover a rolling second; host measurements still arrive in the protocol's one-second samples.
- Unavailable values show **—**, still-screen zero FPS remains valid, and stale host values expire after three seconds. Screen-to-display latency and network RTT are labeled separately.
- Footer and stats shortcuts remain local while controlling the remote Mac, including in full screen. **Save Session Diagnostics…** remains available from the View menu and stats overlay with the footer hidden.

## Validation and testing

The complete local CI suite passes: 232 Rust tests, 110 native input checks, 259 native session checks, hardware media tests, the encrypted loopback stream, and the arm64 macOS 14 app build. Stream checks cover burst coalescing, quiet-stream expiry without repeating callbacks, cancellation, missing measurements, and stale host data. Isolated UI checks cover footer space, menu and keyboard toggles, full screen, and the overlay at the minimum viewer size.

On both Macs, check that the footer preference survives reopening a viewer, both shortcuts work while controlling the remote Mac, and stats track motion, still screens, audio, reconnects, and disconnects. Local and loopback checks do not establish real two-Mac video negotiation, mode switching, or wake behavior; those remain separate acceptance checks in [TESTING.md](TESTING.md). Native sessions remain experimental.

Use **Check for Updates** on each Mac, or download the ZIP from this release. Automatic updates install while no session is connected. Apple silicon and macOS 14 or later; Developer ID signed, notarized, and stapled. GitHub Actions stays disabled.
