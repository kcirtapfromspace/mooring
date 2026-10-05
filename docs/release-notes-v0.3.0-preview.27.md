# Mooring 0.3.0 preview 27 — Back to preview 25's pacing

Installed copies of preview 6 or later update to this version by themselves when no session is connected. The change is on the sharing Mac.

## Why

Preview 26 gave the sharing Mac's network send buffer a smaller limit on slow links, to cut delay from away. Measured from away right after both Macs updated, it made things worse:

- Mooring sent about 4.2 Mbps instead of 9.3, and the bitrate target sat at the 4 Mbps floor, so the picture was softer.
- Frames waited 100 ms or more in 25 seconds of a minute, against one in preview 25's minute, and 333 frames were skipped.
- Frames waited 170–500 ms with only 55–85 KiB queued. The smaller limit held them even though the link had room.

Pacing counts time frames are held as a sign the link is full, so it kept cutting the bitrate. A lower bitrate made the limit smaller still. It was a loop, and preview 26 shouldn't have shipped without a test that tied the two together.

This release restores preview 25's send buffer and pacing exactly. The buffer still holds a little more than it strictly needs away from home, about 10–20 ms. Any future change to it has to keep pacing from mistaking its own holding for a slow link.

## Validation

Local validation passed with the full suite. The pacing code is identical to preview 25's.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
