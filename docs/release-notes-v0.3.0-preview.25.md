# Mooring 0.3.0 preview 25 — Pacing that knows how fast the link is

Installed copies of preview 6 or later update to this version by themselves when no session is connected. The change is on the sharing Mac.

## What was wrong

With preview 24 the hitch every two seconds was gone. From away, though, a busy screen still stalled for about a fifth of a second every 10 to 15 seconds: frames waited around 200 ms, about 11 were skipped, and the frame rate dipped to around 30.

The Mac Studio's telemetry showed why:
- **The target wasn't what was sent.** The bitrate target was 25 Mbps, but the encoder sent about 9: that's all the screen needed. The link carried about 9–10 Mbps.
- **So cuts did nothing.** A burst briefly overfilled the link, and pacing cut the target from 25 to 18.75 Mbps. That changed nothing the encoder did, since it was already far below that.
- **And the cycle repeated.** Pacing climbed back to 25 within about 13 seconds, and the next burst did the same.

## What changes

- **Pacing measures the link.** While video waits in the network buffer, the connection sends as fast as it can, so the rate at which it drains is the link's real rate. The Mac Studio measures it from every frame's reading of the buffer.
- **A stall isn't a slow link.** When Wi-Fi pauses, video waits but nothing moves, which would look like a very slow link. So time with nothing sent for 50 ms or more doesn't count. And the link is never taken as slower than what it recently carried without trouble.
- **A cut goes below what the link carries:** three quarters of the measured rate, when that's lower than three quarters of the target. On a 9.5 Mbps link that's about 7 Mbps, which leaves room for bursts.
- **It remembers where the link ran out.** Climbing back stops at nine tenths of that rate, instead of going all the way to 25 Mbps and overfilling the link again.
- **It still finds a faster connection.** Every 30 seconds without trouble, the remembered rate rises a tenth. A faster rate, measured while video waits, is believed at once.
- **New telemetry:** `link_mbps` in `mooring telemetry` on the sharing Mac shows the measured rate whenever video waited in that second.

On a slow link, a busy screen now looks a little softer during motion instead of stalling. A calm screen is unchanged; it never needed much.

At home, the network is far faster than any screen needs, and nothing changes unless something goes wrong. After a real Wi-Fi slowdown, though, the bitrate now climbs back to just under what the link carried, then a tenth more every 30 seconds. Recovery to full quality can take a few minutes, where before it was about 13 seconds. If that's noticeable at home, say so; probing faster trades it against more frequent stalls away.

## Validation

Local validation passed with the full suite, including 155 Rust session tests.

- **Rust:**
  - At a measured 9.4 Mbps, two slow seconds cut a 25 Mbps target to 7.05 Mbps; before, it was 18.75.
  - Clear seconds climb back to 8.46 Mbps and no further.
  - After 30 clear seconds, the remembered rate rises to 10.34 Mbps and the climb continues.
  - A faster measured rate replaces it.
  - A rate the ceiling no longer reaches is forgotten.
  - A keyframe's slow seconds keep what was learned.
  - The meter counts only time with 64 KiB or more queued. It leaves out a 350 ms stall but keeps gaps under 50 ms, and ignores a counter that went backwards.
  - At home, after sending 15 Mbps without trouble, a stall measuring 2 Mbps cuts only to 11.25 Mbps and remembers 15. Without the guard it would remember 2 and drop to the 4 Mbps floor.
  - Removing either guard fails its test.
- **Swift:** the meter, fed real readings 100 ms apart, reports about 10 Mbps for 125 kB, which confirms its units.
- **Between the two Macs:**
  - From away with a busy screen, `link_mbps` should read roughly what the link carries. `bitrate_mbps` should settle just under it, with no repeating stall every 10–15 seconds.
  - At home, after a Wi-Fi interruption, note how long `bitrate_mbps` takes to return to 25.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
