# MacLink 0.3.0 preview 15 — Encoding about three times faster

Installed copies of preview 6 or later update to this version by themselves when no session is connected.

## Encoding: 50 ms down to under 20

The first latency measurements between two Macs showed the sharing Mac taking about 50 ms to encode each frame of its screen at your MacBook's resolution. That was the largest delay in the whole path.

The cause was macOS's real-time mode for the video encoder. It paces the encoder to the gap between frames. A desktop changes in bursts, typing, then a pause, then a scroll, so most frames come after a pause, and the encoder took its time with them.

With real-time mode off for sharp-text HEVC, the same frames encode in 17–19 ms whatever the gap, and they come out no larger. On the Mac Studio at 3360×2032:

| Frames arrive | Before | Now |
|---|---|---|
| 60 a second | 23 ms | 17 ms |
| After a 100 ms pause | 54 ms | 19 ms |
| After a 500 ms pause | 56 ms | 18 ms |

Faster encoding also lets the sharing Mac keep up at higher frame rates when a lot is changing, instead of skipping frames.

Only the sharing Mac's encoder changed. The picture is still HEVC with full 4:4:4 colour for sharp text.

## Latency figures now appear

Preview 14 measured latency, but each Mac left the new capability out of what it announces, so the figures never started. Preview 15 announces it, and a test now checks what each Mac announces. With preview 15 on both Macs, the status bar shows "NN ms latency" while the picture changes, and `maclink telemetry` shows the breakdown.

## Validation

Local validation passed with 114 Rust session tests and the native suites. 1080p HEVC 4:4:4 encoding in the media suite averages about 7 ms, down from 10. The encrypted loopback median from capture timestamp to decoded fell from about 12 ms to 9 ms. Two-Mac figures are measured in use.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
