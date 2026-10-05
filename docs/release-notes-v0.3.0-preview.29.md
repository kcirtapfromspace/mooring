# Mooring 0.3.0 preview 29 — The sharing Mac wakes for you

Installed copies of preview 6 or later update to this version by themselves when no session is connected. The change is on the sharing Mac. The viewing Mac's part helps most when it's on preview 29 too.

## What went wrong

After the MacBook had been closed for a while, Mooring often couldn't connect, but Apple Screen Sharing could, and after that Mooring worked again.

The Mac Studio's display turns off after 10 minutes. macOS then covers the screen, and Mooring stopped sharing, because it never shares a covered or locked screen. Previews 22 to 28 tried to keep the display on for 12 hours after a session dropped, but that wait often ended early:

| Time | What happened |
|---|---|
| 01:10 | An update relaunched Mooring. Preview 28 fixed this one. |
| 09:54 and 17:01 | The viewing Mac said it was leaving, which happens when its window closes or Mooring quits. The wait ended there. |

On the Mac Studio, that cover doesn't ask for a password. Screen Sharing gets past it only by telling macOS that a user is active, and the cover lifts in a twentieth of a second.

## What changes

- **The sharing Mac wakes for your other Mac.** With **Share this Mac automatically** on, it keeps listening while its display is off or its screen is covered. When an approved Mac connects, it wakes the display, the cover lifts, and the session starts, usually within a second.
- **No more 12-hour wait.** After a session drops, the display turns off on its usual schedule. Closing the viewer window no longer leaves the sharing Mac unreachable.
- **A screen that asks for a password is said plainly.** Mooring never types or sends a password. If the sharing Mac's screen still asks for one after 5 seconds, it stops sharing until someone unlocks it, so it doesn't light the display again on every try. The viewing Mac says the screen may be locked with a password and keeps trying every 3 seconds for two minutes. Unlock it with Screen Sharing, for example, and Mooring reconnects within seconds.
- **After an update relaunches Mooring** with the display off, sharing starts listening again without waking the display.

## What it costs

- **A Mac that asks for a password after its display sleeps** used to stay connectable through the 12-hour wait. Now it needs unlocking first. To avoid that, set the sharing Mac to require a password later after the display turns off, or never, if that's acceptable where it sits.
- **Other apps that relock the screen.** Some tools lock any screen that was unlocked without someone at the keyboard. On the Mac Studio, Codex Computer Use's lock-screen guardian did, about 3 seconds after the wake. Turn that feature off on a Mac you reach with Mooring. Mooring doesn't try to look like a person to such tools.
- **Manual sharing is unchanged.** With **Share this Mac automatically** off, a lock or display sleep still stops sharing until you start it again.

## Validation

Local validation passed with the full suite, including 156 Rust session tests and 27 privacy checks.

- **Measured on the Mac Studio, with your consent:**
  - turning the display off raised the cover, and declaring user activity the way Mooring now does lowered it in 192 ms, with no password;
  - the log of Screen Sharing's earlier unlocks shows the same: the cover lifted 52 ms after it declared activity.
- **Rust:** the wake's 5-second limit is at most half the time a viewer waits for an answer, so a waking Mac never looks dead to it.
- **Swift:** the new listening check accepts a covered or locked screen, but never a user session that isn't on the console or isn't logged in.
- **Not yet run between the two Macs:** Mooring waking the display itself, and capture starting right after. See TESTING.md step 11.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
