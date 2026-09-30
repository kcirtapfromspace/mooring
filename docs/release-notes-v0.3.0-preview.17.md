# MacLink 0.3.0 preview 17 — Faster decoding, and a lower-latency option

Installed copies of preview 6 or later update to this version by themselves when no session is connected.

## What the measurements showed

With preview 16 on both Macs, the time from a change on the sharing Mac's screen to it appearing on the MacBook was a median of 66–82 ms:

| Stage | Time |
|---|---|
| Until decoding starts (capture, encoding, network) | 17–28 ms |
| Decoding on the MacBook | about 17 ms |
| Waiting to reach the MacBook's screen | 25–57 ms |

## Decoding about 40% faster

The viewing Mac used to ask its decoder to convert every frame to RGB. It now takes the decoder's own colour format, 4:4:4 YCbCr for sharp text, and draws that directly. On the Mac Studio, a MacBook-sized frame decodes in 4.6 ms instead of 7.6 ms. The picture is the same: 0.1 colour levels apart on average, at most 2 out of 255. The MacBook's decoder should gain in proportion.

## Try: Lower Display Latency (May Tear)

A new option in the menu bar on the viewing Mac, off by default. It shows each frame as soon as it's drawn instead of waiting for the display's next refresh. Tested on the Mac Studio, it cut the wait before a frame appeared by up to 50 ms in some cases, and by a few milliseconds when typing. The cost is that a fast-moving picture, such as scrolling or video, can show a horizontal tear line.

Turn it on, watch the latency in the viewer's status bar, and decide whether the tear lines matter to you.

## Tried and left out

Drawing each frame the moment it's decoded, rather than on the display's timer, looked promising. Measured, it was at best 5 ms sooner when typing and often a refresh later for video, so it isn't included.

## Validation

Local validation passed with 114 Rust session tests and the native suites. The encrypted loopback median from capture timestamp to decoded fell from about 9.7 ms to 7.6 ms. The presentation measurement tool now covers typing-like frames and reports the wait from decoded to shown.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
