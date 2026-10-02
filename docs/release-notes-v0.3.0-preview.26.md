# MacLink 0.3.0 preview 26 — Less waiting in the buffer from away

Installed copies of preview 6 or later update to this version by themselves when no session is connected. The change is on the sharing Mac.

## What the measurements showed

Pacing on round-trip time was the plan, so first I measured the round trip the operating system itself sees. It's what network-aware video usually paces on.

- **Busy screen from away, preview 25:** 55–58 fps, with one brief stall in a minute.
- **The network round trip stayed flat**, 20–48 ms, even during that stall.
- **MacLink's own ping read as high as 116 ms**, and earlier 200–330 ms. Ping replies queue behind video in the Mac Studio's send buffer, so those figures showed MacLink's own buffer, not the network.

Pacing on the network's round trip wouldn't have caught anything, so it wasn't built. The delay to remove was in that buffer.

## What changes

The sharing Mac lets video into its network send buffer only while little is waiting there. It never let in less than 128 KiB. At home that drains in a few milliseconds. On a link of about 10 Mbps it's around 100 ms, and in the measurements 45–100 KiB was usually waiting there beyond what was already on its way.

Now, across the internet (a round trip of 10 ms or more), the limit fits the link:
- one and a half times what's in flight, so the link stays busy;
- plus 20 ms of sending for the next frame, sized from the busiest of the last ten seconds;
- and never less than 48 KiB, for a sudden large frame.

Over your remote link at about 10 Mbps, that's about 77 KiB instead of 128. Frames that would have waited in the buffer now wait in the app instead, where a newer frame replaces them, so what you see is fresher.

At home, with a round trip under 10 ms, nothing changes.

## Validation

Local validation passed with the full suite, including 155 Rust session tests.

- **Rust:**
  - 10 Mbps at 28 ms gives 77.5 kB.
  - A calm slow link keeps 48 KiB.
  - Nothing sent yet gives 128 KiB.
  - At home, at 3 or 9 ms, it stays 128 KiB whatever is sent.
  - It never goes above the earlier rule.
- **Swift:** the limit follows the busiest of the last ten seconds, so one quiet second doesn't shrink it.
- **Between the two Macs, from away:** `send_queue_kib` in `maclink telemetry` on the sharing Mac should drop from about 80–130 to about 50–80. The ping time on the viewer should drop by a similar 20–40 ms, with frame rate unchanged.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
