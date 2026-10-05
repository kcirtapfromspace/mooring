# Mooring 0.3.0 preview 28 — The wait survives an update

Installed copies of preview 6 or later update to this version by themselves when no session is connected. Both changes help most with both Macs on preview 28.

## What went wrong overnight

The MacBook's session dropped at 21:47 without a goodbye. The Mac Studio began its 12-hour wait, keeping its display on so it wouldn't lock. Then:

| Time | What happened |
|---|---|
| 01:10 | With no session connected, preview 27 installed itself and Mooring relaunched. The wait was held only in memory, so it was lost. |
| 01:15 | The display turned off and the screen locked, so Mooring stopped sharing. |
| 08:08 | Screen Sharing unlocked the Mac Studio, and Mooring reconnected seven seconds later. |

From away, the MacBook said "Operation timed out". The Mac Studio's Tailscale address had actually answered at once, with nothing listening on Mooring's port. The local name and home address can't be reached from away, so they used up the time, and their timeout is what was reported. No address changed.

## What changes

- **The wait survives a relaunch.** It's saved when it starts.
  - **An update or a crash** resumes it. Mooring takes back its hold on the display as soon as it launches, if sharing will start by itself. If the display went dark in the gap, Mooring wakes it before it can lock. A Mac that's already locked can't share, so its wait is dropped.
  - **The viewer reconnecting, Stop Sharing, a lock, or quitting Mooring** ends it.
- **"Reachable, but not sharing" is said plainly.** When the sharing Mac answers but Mooring isn't accepting connections there, the viewing Mac now says so. It says the Mac may be locked or asleep and that unlocking it, for example with Screen Sharing, lets Mooring reconnect. It keeps trying in the meantime. That answer takes precedence over a timeout from other addresses.

## Validation

Local validation passed with the full suite, including 155 Rust session tests.

- **Rust:**
  - Two addresses with nothing listening report "not sharing".
  - So does one that isn't sharing alongside one that never answers, within the time limit.
  - The error has readable text.
- **The relaunch path** was traced step by step against last night's log: the update preparation keeps the saved wait, the quit after it keeps it, and launch resumes it. It wasn't run on the Mac Studio, which would interrupt your session.
- **It can't be checked until the next update installs during a wait,** which is preview 29 or later. Sparkle won't reinstall the same build.
- **The screen saver:** last night's wait ran three and a half hours before the update ended it, and the screen saver, set to start after three hours, didn't lock the Mac Studio. That's one night; longer waits are still unverified.
- **Toolchain:** this Mac's Rust updated to 1.99 overnight and renamed one atomic operation (`fetch_update` to `try_update`). The code now uses the new name.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
