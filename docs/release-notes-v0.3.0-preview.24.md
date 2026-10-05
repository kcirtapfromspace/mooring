# Mooring 0.3.0 preview 24 — No more hitch every two seconds

Installed copies of preview 6 or later update to this version by themselves when no session is connected. The change is on the sharing Mac.

## What was wrong

From away, over Tailscale, the stream ran at about 48 fps but caught every two to three seconds. The Mac Studio's own measurements showed why:

- It sent a full picture, a keyframe, every two seconds. A sharp 4:4:4 keyframe of a 3360×2032 screen is around a megabyte, against two or three kilobytes for an ordinary frame.
- On a link of about 10 Mbps, each keyframe held the connection for a good part of a second. Frames waited up to 300 ms, 10 to 20 a second were skipped, and the frame rate dipped to 25–42 fps.
- Pacing took those waits for a slow connection and cut the bitrate from 25 Mbps to 4 Mbps in a minute and a half, softening the picture. The steady stream needed about 1 Mbps.

## What changes

- **Keyframes only when needed:**
  - at the start of a session;
  - when the shared screen changes size;
  - after an encoder hiccup;
  - when the viewing Mac asks, which it does whenever its decoder needs one, and again every 0.75 s until it arrives.

  Mooring's connection never loses data, so a periodic keyframe repairs nothing.
- **Pacing ignores a keyframe's drain.** A slow second during or right after an on-demand keyframe no longer lowers the bitrate. A slow connection still shows in the seconds between.
- **You can still ask for periodic keyframes:** `mooring tune --keyframe-seconds N` for one every N seconds (1–10), and `--keyframe-seconds 0` for only when needed, the default. With a periodic interval tuned, pacing counts every slow second as before.

## What still costs a moment

A keyframe that's needed is still about a megabyte. Over a slow link it still takes most of a second, at the start of a session and again when the shared screen resizes to the viewing Mac a few seconds in. Expect a brief catch then, not every two seconds. Making that keyframe smaller is the next step.

## Also found

On Apple silicon, the HEVC encoder ignores VideoToolbox's "no limit" keyframe setting and makes a keyframe every 32 frames instead. A new test on the real encoder caught it, so "only when needed" is an explicit one-hour limit.

## Validation

Local validation passed with the full suite, including 152 Rust session tests.

- **Encoder:** a new test on the hardware HEVC encoder checks 3.5 s of changing frames. On demand, only the first frame and one requested frame are keyframes. With an interval of 1 s, there are four.
- **Pacing:** slow seconds during or just after a keyframe are left out, even two keyframes close together as at a session's start. Slow seconds between keyframes still lower the bitrate.
- **Between the two Macs:** check from away with `mooring telemetry` on the sharing Mac. `keyframes` should stay at 0 between changes of screen size, and `skipped_fps` and `queue_wait_ms` near 0. `bitrate_mbps` should climb back toward 25 over the first minute; before, it fell to 4.

A tuning of `--keyframe-seconds 0` sent from a viewing Mac to a sharing Mac before preview 24 is refused by that Mac, which ends the session. Update the sharing Mac first.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
