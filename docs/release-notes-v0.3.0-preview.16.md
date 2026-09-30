# MacLink 0.3.0 preview 16 — Full quality right after an update

Installed copies of preview 6 or later update to this version by themselves when no session is connected.

## No more reduced session after a relaunch

When a Mac relaunched, for example after an update, a paired Mac could reconnect in the fraction of a second before MacLink had finished its launch checks. Those checks confirm sharp-text HEVC, sound and screen matching work on this Mac. Each Mac tells the other what it supports once, at the start of a session. So that session ran with H.264 at 1920×1080, no sound, no screen matching and no latency figures until you reconnected.

Now a Mac doesn't start sharing or connecting until those checks finish, which takes well under a second. If the checks ever stall, it goes ahead after 5 seconds without sharp-text HEVC and sound, rather than not sharing at all.

## Also in the last few previews

- **Preview 15:** the sharing Mac encodes about three times faster after a pause (18 ms instead of about 50 ms at MacBook resolution), and the latency figures switch on.
- **Preview 14:** the viewing Mac measures the time from a screen change on the sharing Mac to its own display ("NN ms latency" in the status bar).

## Validation

Local validation passed with 114 Rust session tests and the native suites. The local suite doesn't relaunch the app; the next update between two Macs shows the fix in the sharing Mac's log, where the self-test results come before "sharing started automatically".

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
