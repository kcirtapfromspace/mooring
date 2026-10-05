# Mooring 0.3.0 preview 26 — Less waiting in the buffer from away

Installed copies of preview 6 or later update to this version by themselves when no session is connected. The change is on the sharing Mac.

## What the measurements showed

Pacing on round-trip time was the plan, so first I measured the round trip the operating system itself sees. It's what network-aware video usually paces on.

- **Busy screen from away, preview 25:** 55–58 fps, with one brief stall in a minute.
- **The network round trip stayed flat**, 20–48 ms, even during that stall.
- **Mooring's own ping read as high as 116 ms**, and earlier 200–330 ms. Ping replies queue behind video in the Mac Studio's send buffer, so those figures showed Mooring's own buffer, not the network.

Pacing on the network's round trip wouldn't have caught anything, so it wasn't built. The delay to remove was in that buffer.

## What changes

The sharing Mac lets video into its network send buffer only while little is waiting there. It never let in less than 128 KiB. At home that drains in a few milliseconds. On a link of about 10 Mbps it's around 100 ms, and in the measurements 45–100 KiB was usually waiting there beyond what was already on its way.

Now, across the internet (a round trip of 10 ms or more), the limit fits the link:
- one and a half times what's in flight, so the link stays busy;
- plus 20 ms of sending for the next frame, sized from the busiest of the last ten seconds;
- and never less than 48 KiB, for a sudden large frame.

Over your remote link at about 10 Mbps, that's about 77 KiB instead of 128. Expect roughly 10–20 ms less delay in ordinary seconds. During bursts it's up to about 50 ms less: frames that would have piled up in the buffer now wait in the app, where a newer frame replaces them, so what you see is fresher.

At home, with a round trip under 10 ms, nothing changes. A connection through a relay, such as Tailscale's when it can't connect directly, counts as across the internet.

Big screen changes, like switching windows, still make very large frames that can overfill a slow link for a moment. Capping frame size is the next step for that.

## Validation

Local validation passed with the full suite, including 155 Rust session tests.

- **Rust:**
  - 10 Mbps at 28 ms gives 77.5 kB.
  - A calm slow link keeps 48 KiB.
  - Nothing sent yet gives 128 KiB.
  - At home, at 3 or 9 ms, it stays 128 KiB whatever is sent.
  - It never goes above the earlier rule.
- **Swift:** the limit follows the busiest of the last ten seconds, so one quiet second doesn't shrink it.
- **Between the two Macs, from away:**
  - `send_queue_kib` in `mooring telemetry` on the sharing Mac should mostly sit around 60–95, and rarely above 100 during bursts. It was 80–130 normally and 150+ in bursts.
  - The viewer's ping time should drop by about 10–20 ms.
  - `sent_mbps` for a busy screen should stay where it was, about 9–10. If it falls, the smaller limit is starving the link.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
