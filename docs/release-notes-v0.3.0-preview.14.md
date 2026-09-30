# MacLink 0.3.0 preview 14 — Measured latency

Installed copies of preview 6 or later update to this version by themselves when no session is connected.

## How long the picture takes to reach you

The viewing Mac now measures, for every frame, the time from a change on the sharing Mac's screen to that frame appearing on its own display. While the picture is changing, the status bar shows it as "NN ms latency" in place of the network round trip.

- **Clock placement:** once a second, the sharing Mac answers the viewing Mac's connection check with its own clock. The viewing Mac lines the two clocks up the way NTP does, and the result is accurate to within half the fastest recent round trip, usually well under a millisecond on a home network.
- **Breakdown:** telemetry (`maclink telemetry`) splits the figure into:
  - the part until decoding starts: capture, encoding, sending and the network;
  - decoding;
  - waiting for the next display refresh.

  The sharing Mac also reports how long ScreenCaptureKit takes to deliver a change.
- **Session log:** every 10 seconds the viewing Mac logs the median and 95th percentile ("viewer latency, last 10 s").

This is the baseline for the next speed changes. The figure doesn't include the time the sharing Mac's app takes to react to a click, or the viewing display's own scan-out.

## Needs both Macs on preview 14

The sharing Mac has to send its clock. With an older Mac on either end, the status bar shows the round trip as before, and older Macs never receive the new messages.

## Validation

Local validation passed with 114 Rust session tests, including:

- the clock reply format and its direction, protocol and capability rules;
- latency metrics left out for older peers;
- the clock estimate.

The encrypted loopback placed the clocks, as expected with both ends on one Mac. HEVC 4:4:4 1080p frames measured a median of about 12 ms from capture timestamp to decoded. Two-Mac figures are measured in use.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
