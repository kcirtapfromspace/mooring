# Mooring 0.3.0 preview 22 — Open the lid and pick up where you left off

Installed copies of preview 6 or later update to this version by themselves when no session is connected. It also carries preview 21's fixes: the pointer now lines up with clicks, and in full screen the sharing Mac's menu bar can be reached. See the [preview 21 notes](release-notes-v0.3.0-preview.21.md).

## A closed lid no longer locks you out

Last night the MacBook's lid closed with a session on, and in the morning it couldn't reconnect until Apple Screen Sharing woke the Mac Studio. Here's what happened:

- Closing the lid ended the session, and the sharing Mac treated that like any other goodbye.
- Mooring keeps the sharing Mac's display on only during a session. Ten minutes later, with no session, macOS turned the display off and locked the screen.
- Mooring stops sharing when the screen locks: it never shows a lock screen. The sharing Mac stayed awake and on the network, but nothing was listening.

Now the sharing Mac tells the two apart:

- **You end the session:** you close the viewer or quit Mooring, and the viewing Mac says it's leaving. The sharing Mac then lets its display turn off and lock as before.
- **The session drops:** a lid closes, Wi-Fi drops, or anything else ends it without a goodbye. The sharing Mac keeps its display on and keeps taking connections for up to 12 hours, so it doesn't lock. Its Share window says it's waiting, and until when. **Stop Sharing** ends the wait.

The viewing Mac also reconnects on its own after it wakes. When its sleep or lock ended a session, it waits until it's awake and unlocked, then reconnects in the same window. Before, it said "Reconnect when ready" and waited for you.

## What changes on each Mac

- **Sharing Mac:** while it waits, it stays unlocked. Anyone connecting still needs an approved key. Don't use this on a Mac with a screen that others can see and reach: stop sharing there instead of letting the session drop.
- **Viewing Mac:** closing the viewer is now a clear goodbye. Closing the lid is not.
- **Both Macs need preview 22.** A sharing Mac on an earlier version locks as before. A viewing Mac on an earlier version can't say it's leaving, so a preview 22 sharing Mac waits after every session with it.

The screen saver on the sharing Mac is untested with this. Its display stays on, but if a screen saver starts after hours idle and asks for a password, the screen locks and sharing stops. On the Mac Studio, the screen saver starts after 3 hours. If that happens, set **Start Screen Saver when inactive** to **Never** there.

## Validation

Local validation passed with the full suite, including 141 Rust session tests.

- **Rust:** the new message's format, its direction (viewer to sharing Mac only), and both sides of its capability.
- **Swift, over loopback:** a viewer that closes on purpose sends its goodbye after anything already queued, and the sharing Mac reads it before the connection closes. The test fails when the goodbye is sent after closing.
- **Between two Macs:** the overnight lid-close check can't run locally. It's step 10 in TESTING.md.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
