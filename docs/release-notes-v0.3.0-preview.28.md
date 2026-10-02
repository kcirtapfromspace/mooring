# MacLink 0.3.0 preview 28 — The wait survives an update

Installed copies of preview 6 or later update to this version by themselves when no session is connected. Both changes help most with both Macs on preview 28.

## What went wrong overnight

The MacBook's session dropped at 21:47 without a goodbye. The Mac Studio began its 12-hour wait, keeping its display on so it wouldn't lock. Then:

| Time | What happened |
|---|---|
| 01:10 | With no session connected, preview 27 installed itself and MacLink relaunched. The wait was held only in memory, so it was lost. |
| 01:15 | The display turned off and the screen locked, so MacLink stopped sharing. |
| 08:08 | Screen Sharing unlocked the Mac Studio, and MacLink reconnected seven seconds later. |

From away, the MacBook said "Operation timed out". The Mac Studio's Tailscale address had actually answered at once, with nothing listening on MacLink's port. The local name and home address can't be reached from away, so they used up the time, and their timeout is what was reported. No address changed.

## What changes

- **The wait survives a relaunch.** It's saved when it starts.
  - **An update or a crash** resumes it. MacLink takes back its hold on the display as soon as it launches, if sharing will start by itself, so the gap can't let the screen lock.
  - **The viewer reconnecting, Stop Sharing, a lock, or quitting MacLink** ends it.
- **"Reachable, but not sharing" is said plainly.** When the sharing Mac answers but MacLink isn't accepting connections there, the viewing Mac now says so. It says the Mac may be locked or asleep and that unlocking it, for example with Screen Sharing, lets MacLink reconnect. It keeps trying in the meantime. That answer takes precedence over a timeout from other addresses.

## Validation

Local validation passed with the full suite, including 155 Rust session tests.

- **Rust:**
  - Two addresses with nothing listening report "not sharing".
  - So does one that isn't sharing alongside one that never answers, within the time limit.
  - The error has readable text.
- **The relaunch path** was traced step by step against last night's log: the update preparation keeps the saved wait, the quit after it keeps it, and launch resumes it. It wasn't run on the Mac Studio, which would interrupt your session. The next automatic update with no session connected is the real test.
- **Toolchain:** this Mac's Rust updated to 1.99 overnight and renamed one atomic operation (`fetch_update` to `try_update`). The code now uses the new name.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
