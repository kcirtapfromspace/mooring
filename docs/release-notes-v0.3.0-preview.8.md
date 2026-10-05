# Mooring 0.3.0 preview 8 — Smoother picture on the viewing Mac

Installed copies of preview 6 or 7 update to this version by themselves: when no session is connected, within about four hours. It is the first update meant to arrive with no action at all.

## Every decoded frame gets its own screen refresh

Telemetry from a preview 7 session showed the viewing Mac decoding 55–59 frames per second during motion but drawing only 30–50. The network, capture and decoding were keeping up; frames were lost in the last step.

The viewer used to draw each frame as soon as it arrived. It allowed only one frame on the graphics card at a time, and a frame arriving while another was being drawn replaced the waiting one. Frames arriving close together, as Wi-Fi delivers them after a pause, lost all but the newest.

Now:

- **Paced by the display:** the viewer draws once per screen refresh, up to 120 Hz on ProMotion displays.
- **Nothing lost to bunching:** up to two decoded frames wait their turn, so frames that arrive together are each shown. A third replaces the oldest, which limits the extra delay to one refresh.
- **Two frames on the GPU:** up to two frames can be rendering at once.
- **Correct colour on wide-gamut displays:** the picture is tagged sRGB, so macOS colour-matches it correctly. Colours may look slightly less saturated than before, and now match the sharing Mac.

## Diagnostics

Every 10 seconds of a session, the viewing Mac logs where its frames went: decoded, drawn, waiting for the GPU, or replaced, plus drawing time on the processor and the GPU. This stays on that Mac and is never sent to the other one, so the connection protocol is unchanged. Read it on the viewing Mac with:

```sh
/usr/bin/log show --last 1h --style compact --predicate 'subsystem == "dev.mooring" AND eventMessage CONTAINS "viewer drawing"'
```

## Validation

Local validation passed with 153 Rust tests and every native Swift suite. `scripts/measure-native-present.swift` feeds decoder-style 1920×1080 frames at 60 fps through the viewer's drawing code, in a window on screen:

- **Even arrival:** all frames drawn at 60 fps, both in a 1600×900 window and at a 3456×2234 Retina drawable size.
- **Frames arriving in pairs:** 60 of 60 in the window, and 57 of 60 at the Retina size, where the rest were replaced by design.
- **Cost on this Mac (M1 Ultra):** about 0.2 ms on the processor and 0.1–0.3 ms on the GPU per frame.

The viewing Mac's own numbers will come from its log.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
