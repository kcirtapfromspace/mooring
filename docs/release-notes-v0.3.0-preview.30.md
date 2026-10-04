# MacLink 0.3.0 preview 30 — Reconnect after lid sleep

This preview includes the wake-recovery fix and the code-audit fixes. Update both Macs before testing; the wake change runs on the sharing Mac. Existing connections, pairings and preferences are preserved.

## Reconnect fix

The sharing Mac could miss a wake request, label the timeout as a password lock, and stop listening. An RDP or Apple Screen Sharing connection could then clear macOS's display cover, making MacLink work again.

An approved connection now makes up to three wake requests, a second apart, within the existing five-second wait. MacLink holds the display awake through that attempt and releases the power assertions when it finishes or is canceled. An unlocked console can resume listening even while its display sleeps, and a display-only timeout keeps the listener available for another approved connection. The timeout message no longer assumes a password is required.

Capture and input still require an unlocked, active console session. A screen that remains covered after the wake attempt waits for an unlock.

## Audit fixes

- Clipboard work stays with the connection that started it. Disconnecting, disabling sharing or replacing a connection cancels stale delivery. Pairing codes are filtered from shared clipboard content.
- Canceling a connection while startup checks run prevents the deferred connection from starting later.
- Virtual-display calls validate the runtime interface, and display-arrangement changes restore the physical layout on cancellation or failure.
- Latency calculations reject invalid timing and arithmetic overflow.

## Validation and testing

The full local CI suite passed: 232 Rust tests, 247 native session checks, privacy and display-boundary checks, hardware media tests, the encrypted loopback stream, and the arm64 macOS 14 app build. Wake tests use fake power APIs and simulated console/display observations; they do not sleep or wake the live desktop.

The actual two-Mac lid cycle remains to be tested with this preview. With **Share this Mac automatically** enabled, close the viewing laptop overnight, then open and unlock it. It should reconnect without first using RDP or Screen Sharing. Repeat a shorter lid cycle and test a real password lock separately. See [TESTING.md](TESTING.md), step 11.

Use **Check for Updates…** on each Mac, or download the ZIP from this release. Automatic updates install while no session is connected. Apple silicon and macOS 14 or later; Developer ID signed, notarized and stapled. Builds and tests run on the local Mac, with GitHub Actions disabled.
