# Delivery gates

Priorities in order: no lost control or stuck input, consistently low interaction delay, legible Retina text, and a connection flow with minimal choices. Automatic quality must improve the session without unexpectedly resizing the user's desktop.

## Gate 0 — usable foundation (current)

Deliver a native app that saves Macs and launches Apple's existing viewer. Bound diagnostics, show useful errors, keep the UI responsive, and preserve connection data through concurrent operations. Treat successful app launch separately from successful remote login. Keep every unfinished engine capability out of the UI.

This establishes packaging and a way to compare against Apple's client. It does not resolve manual switching between Apple's sharing modes.

## Gate 1 — prove the media path on the actual Mac pair

Run Apple High Performance at a fixed resolution/scale, then evaluate a separately installed experimental Apple-compatible client. Test colored terminal text, scrolling, window dragging, audio, clipboard, sleep/wake, lock/unlock, and a long session. Record macOS versions and hardware at both ends. Do not assume that a protocol implementation proven on one macOS release works on another.

In parallel, use only public APIs to test whether a custom host can deliver the required text fidelity and hardware encoding. First run the capability probe, then a synthetic chart encode/decode test, then an explicit user-started ScreenCaptureKit test. Probe results alone do not establish encode speed or 4:4:4 fidelity.

Decision:

- Select an Apple-compatible Rust viewer if hardware decoding, input, virtual display geometry, and reconnect behavior are stable, and protocol controls permit the adaptation needed.
- Select a custom Rust host/viewer if protocol gaps prevent reliability or adaptation, provided the public capture/codec path meets fidelity requirements.
- Keep the native Apple launcher available while the selected engine is experimental.

Do not implement two production engines simultaneously. Do not depend on Accessibility scripts that edit Apple's UI or unsupported preference writes for core connection behavior.

## Gate 2 — one real streaming session

Initially one display, SDR, keyboard/mouse, a visible user-controlled host process, and explicit pairing. Capture and decode buffers stay GPU-backed where supported. Use a native Metal view; all frame queues are bounded. Drop obsolete raw frames before encoding and expired decoded frames before presenting. Compressed-frame loss requires reference-aware recovery; arbitrarily dropping reference frames is not a valid latency optimization.

A custom transport must have authenticated encryption, pinned peer identity after pairing, bounded message/frame lengths, control priority, fragment limits, media deadlines, keyframe recovery, and congestion feedback. LAN detection never substitutes for authentication. Avoid opening internet ports automatically. Build and verify the LAN path before adding discovery, relay, or public-internet connectivity.

Input must use explicit press/release events and release all held keys/buttons on disconnect or focus loss. Coordinate mapping uses confirmed host display geometry and handles Retina scale separately from logical size.

## Gate 3 — automatic quality

Wire the tested Rust policy to real telemetry and to supported encoder/session controls. Maintain the logical desktop size. Downgrade promptly on persistent queue growth or loss; upgrade only after sustained recovery. Handle stale, invalid, and out-of-order metrics conservatively. Keep a manual override, but default to Auto only after it controls the real engine.

Use the measurement matrix in `performance.md`. Compare p95 latency as well as averages. A high FPS counter is not proof of responsive interaction. Connection policy must not infer available bandwidth from a TCP handshake.

## Gate 4 — daily-driver reliability

Complete clipboard, audio, reconnect after Wi-Fi handoff, sleep/wake, bounded retry budgets, and crash recovery. Add headless virtual display support only after verifying the platform path; capture APIs do not create a login-session replacement. Validate lock-screen and FileVault limitations separately.

Run sustained sessions and network impairment tests on both target Macs. Resolve failures before adding HDR, multiple displays, file transfer, internet relays, or further platform support. Sign and notarize distributable builds; store pairing keys in Keychain. Provide connection diagnostics that never contain passwords, session keys, clipboard contents, or screen frames by default.

## Needed for the next real-device gate

The two Mac models/macOS versions, target display resolution and Retina scale, and whether off-site connectivity is required. Actual addresses and login should be entered locally in the app. No credentials are needed in chat.
