# Mooring 0.3.0 preview 18 — Steadier on Wi-Fi, and never a stale picture

Installed copies of preview 6 or later update to this version by themselves when no session is connected.

## The last change always arrives

When the sharing Mac's encoder was busy, a newly captured frame was thrown away. If that was the last change before the screen went still, say the final letter you typed, the viewing Mac kept showing the picture from just before it until something else changed. macOS only captures a screen when it changes, so nothing came along to fix it.

Now the newest frame waits and goes out as soon as the encoder is free. Older waiting frames are dropped, since only the newest matters.

## Less lag when Wi-Fi slows

The latency measurements showed occasional spikes to nearly 300 ms, at the same moments the network round trip jumped. The cause: when Wi-Fi slowed, up to half a megabyte of video queued in macOS's network send buffer. Once there, a frame can't be replaced by a newer one, so everything waited behind it.

Now the sharing Mac:

- **Waits for the queue:** it starts a frame only while little video is queued, and the newest frame waits in Mooring instead, where a newer one can replace it. On a longer connection, such as a VPN, it allows more in flight so the link stays busy.
- **Adapts the bitrate:** when frames spend 150 ms or more of a second waiting, in two of any four seconds, it lowers the bitrate to three quarters. It raises it 10% for each three clear seconds, up to your setting, and never goes below 4 Mbps, where text stays legible. A single slow moment, such as one large keyframe, changes nothing.

On a steady home network nothing changes. During a slowdown, you should see a lower frame rate or a slightly softer picture for a moment instead of a long freeze.

`mooring telemetry` on the sharing Mac shows the bitrate in use, the send queue and how long frames waited. The session log notes each reduction ("pacing:").

## Validation

Local validation passed with 122 Rust session tests and the native suites, including:

- the pacing rules;
- a live send-queue reading;
- the newest waiting frame being encoded once the encoder or the connection frees up.

The effect of a real Wi-Fi slowdown is checked between two Macs.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
