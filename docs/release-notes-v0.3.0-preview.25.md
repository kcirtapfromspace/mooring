# MacLink 0.3.0 preview 25 — Pacing that knows how fast the link is

Installed copies of preview 6 or later update to this version by themselves when no session is connected. The change is on the sharing Mac.

## What was wrong

With preview 24 the hitch every two seconds was gone. From away, though, a busy screen still stalled for about a fifth of a second every 10 to 15 seconds: frames waited around 200 ms, about 11 were skipped, and the frame rate dipped to around 30.

The Mac Studio's telemetry showed why:
- **The target wasn't what was sent.** The bitrate target was 25 Mbps, but the encoder sent about 9: that's all the screen needed. The link carried about 9–10 Mbps.
- **So cuts did nothing.** A burst briefly overfilled the link, and pacing cut the target from 25 to 18.75 Mbps. That changed nothing the encoder did, since it was already far below that.
- **And the cycle repeated.** Pacing climbed back to 25 within about 13 seconds, and the next burst did the same.

## What changes

- **Pacing measures the link.** While video waits in the network buffer, the connection sends as fast as it can, so the rate at which it drains is the link's real rate. The Mac Studio measures it from every frame's reading of the buffer.
- **A cut goes below what the link carries:** three quarters of the measured rate, when that's lower than three quarters of the target. On a 9.5 Mbps link that's about 7 Mbps, which leaves room for bursts.
- **It remembers where the link ran out.** Climbing back stops at nine tenths of that rate, instead of going all the way to 25 Mbps and overfilling the link again.
- **It still finds a faster connection.** Every 30 seconds without trouble, the remembered rate rises a tenth. A faster rate, measured while video waits, is believed at once.
- **New telemetry:** `link_mbps` in `maclink telemetry` on the sharing Mac shows the measured rate whenever video waited in that second.

On a slow link, a busy screen now looks a little softer during motion instead of stalling. A calm screen is unchanged; it never needed much.

## Validation

Local validation passed with the full suite, including 154 Rust session tests.

- **Rust:**
  - At a measured 9.4 Mbps, two slow seconds cut a 25 Mbps target to 7.05 Mbps; before, it was 18.75.
  - Clear seconds climb back to 8.46 Mbps and no further.
  - After 30 clear seconds, the remembered rate rises to 10.34 Mbps and the climb continues.
  - A faster measured rate replaces it.
  - A rate the ceiling no longer reaches is forgotten.
  - A keyframe's slow seconds keep what was learned.
  - The meter counts only time with 64 KiB or more queued, and ignores a counter that went backwards.
- **Swift:** the meter, fed real readings 100 ms apart, reports about 10 Mbps for 125 kB, which confirms its units.
- **Between the two Macs:** from away with a busy screen, `link_mbps` should read roughly what the link carries. `bitrate_mbps` should settle just under it, with no repeating stall every 10–15 seconds.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
