# Mooring 0.3.0 preview 19 — Versions you can see, and one Settings window

Installed copies of preview 6 or later update to this version by themselves when no session is connected.

## Which Mac runs what

Earlier today the Mac Studio sat on an old version while the MacBook had a new one, and nothing said so. Sound and screen matching simply didn't work.

Now each Mac tells the other which Mooring it runs. When they differ, the viewing Mac's window says so in its bottom bar, with the next step:

- **The sharing Mac is older:** **Update It** asks it to check for and download its update. When the update is ready, **Disconnect and Update** ends the session so it can install. The viewing Mac then waits up to two minutes for it to come back and reconnects by itself. If the sharing Mac was sharing, it shares again after the update, even if it doesn't share automatically.
- **This Mac is older:** **Check for Updates** updates this Mac.
- **Where versions also show:** the sharing Mac's Share window shows the viewer's version when it differs, and both Macs log each other's version.

Updates still install only from the signed release feed, and never during a session.

Both Macs need preview 19 or later. The first time **Update It** will do something is when preview 20 comes out.

## One Settings window

**Settings…** in the menu bar now opens a single window, in three parts:

- **Sharing this Mac:** share automatically, the shared clipboard, keyboard and mouse permission, and the pairing code.
- **Viewing another Mac:** screen matching, sound, lower display latency, and the Macs this Mac is paired with. Each Mac has a **Remove…** button, disabled while you're connected to it.
- **Mooring:** launch at login, the version, updates, and Apple Screen Sharing automation, which keeps its own window.

Changes apply at once, including to a session that's running. Those four toggles are no longer in the menu bar menu.

## Also

Latency figures in telemetry now go blank when nothing reached the screen, for example while the viewer window is hidden, instead of repeating the last value.

## Coming next

Preview 20 gives each paired Mac its own key. New pairing codes will work once and expire, and you'll be able to remove any one Mac from the sharing Mac. Existing pairings will keep working and move over by themselves.

## Validation

Local validation passed with 127 Rust session tests and the native suites, including:

- the version and update messages and their rules;
- strict release parsing and ordering;
- refusal toward older peers.

The Settings window was rendered off-screen in light and dark appearance to check its layout. The update request between two Macs is first exercised by preview 20.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
