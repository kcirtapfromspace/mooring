# Mooring 0.3.0 preview 3 — Automatic sharing, reconnection and live tuning

Both Macs must run this preview; earlier previews cannot connect to it.

## Sharing without keeping a window open

Closing **Share This Mac** no longer stops sharing. Stop it from the window or with **Stop Sharing This Mac** in the menu bar.

The new **Share this Mac automatically** option starts sharing when Mooring opens. It also resumes sharing after sleep, lock or a user switch, once the Mac is awake and unlocked. To share after you log in, also turn on **Launch Mooring at login** in Settings. Clicking **Stop Sharing** keeps sharing off until you start it again or Mooring next opens. Automatic starts never show a permission prompt; grant Screen Recording once by starting sharing yourself.

## ⌘-Tab and system shortcuts

While the viewer has focus and keyboard control is enabled, ⌘-Tab, ⌘-Space and other system shortcuts go to the remote Mac instead of this one. This requires allowing Mooring in Accessibility on the **viewing** Mac. Until you do, the viewer's status bar shows an **Allow ⌘-Tab…** button. These shortcuts always stay on your own Mac:

- Force Quit (⌘⌥Esc)
- Lock Screen (⌃⌘Q)
- Leave full screen (⌃⌘F or Globe-F)

## Automatic reconnection

When a session ends unexpectedly, the viewer reconnects in the same window and keeps full screen. It does not bring Mooring to the front or take keyboard focus from another app. It makes up to five attempts, 0.5 to 8 seconds apart (about 15 seconds in all), and shows **Reconnecting…** with a **Cancel** button. The count resets once a session has stayed connected for 20 seconds.

The viewer does not reconnect in these cases:

- you close the window;
- either Mac sleeps or locks;
- the sharing Mac rejects the pairing.

If the budget runs out, the usual **Session ended** panel appears with **Reconnect**.

The cause of the unexpected disconnects reported in preview 2 has not been identified yet. To help find it, each Mac now records why every session ended:

- **Session log:** starts and ends, reconnects, automatic sharing and tuning go to the macOS log, readable with `/usr/bin/log show --last 2h --style compact --predicate 'subsystem == "dev.mooring"'`.
- **Telemetry:** snapshots include `last_end`, the latest reason and how long ago it was.

## Live telemetry and tuning

While a session is connected, each Mac sends the other a small set of measurements once a second over the encrypted session:

- capture, encode, send and decode rates and times;
- frame sizes, backpressure and keyframes;
- round-trip time.

Each running Mooring serves the combined view on an owner-only local socket in its data folder, and the bundled command-line tool reads it:

```sh
/Applications/Mooring.app/Contents/Resources/mooring telemetry
/Applications/Mooring.app/Contents/Resources/mooring tune --bitrate-mbps 15 --max-width 2560
```

Tuning adjusts the sharing Mac's stream live: bitrate, maximum capture width, frame-rate cap, frames in flight and keyframe interval. Commands typed on the viewing Mac are sent to the sharing Mac. Every value is validated and bounded. Settings last until the sharing Mac's app quits, and `tune --reset` restores the defaults. See [docs/TELEMETRY.md](TELEMETRY.md) for every field and how to read them.

Nothing opens a network port for telemetry. The socket sits in an owner-only folder and serves at most four clients. It carries measurements only: no screen content, input, addresses or keys.

## Fixes

- **Width changes:** changing the maximum width can no longer end the session. Rapid width changes now restart capture at most once a second, at the latest width.
- **Counters:** skipped, dropped and failed-frame counts no longer go backward after a capture restart.
- **Bounded delivery:** tuning and keyframe requests on the sharing Mac use the session's bounded delivery queue.
- **Input checks:** the sharing Mac re-reads its lock and permission state at most every 250 ms, instead of on every mouse event. Lock and sleep still end a session at once.
- **Send timeout:** a send may now wait up to 8 seconds, up from 3, before ending the session.
- **View-only shortcuts:** ⌘W and other Command shortcuts now act on your own Mac, instead of being swallowed.
- **Stuck keys:** keys held on the remote Mac are released if macOS interrupts shortcut capture.

Local validation passed with 145 Rust tests (76 for the session, 10 for the CLI) and every native Swift suite. New checks cover:

- the telemetry wire format and bounds;
- direction rules (only viewers tune);
- the local socket's limits and stale-file handling;
- stats and tuning crossing a real encrypted, hardware-encoded loopback session;
- the actual CLI commands against the app's socket;
- the reconnect budget;
- the shortcuts that stay local.

## Limitations

Automatic sharing, ⌘-Tab capture and reconnection have not yet been tested between two Macs. Sharing still stops when the sharing Mac's display sleeps and resumes only once it wakes. An idle Mac therefore stops accepting connections after its display-sleep time; a connected session keeps the display awake. While the viewer is focused, ⌃-arrow Space switching also goes to the remote Mac. Leave full screen with ⌃⌘F to use your own Mac's shortcuts again. Live tuning affects the native Mooring session only, not Apple Screen Sharing. The session does not tell the viewer when sharing is stopped on purpose, so the viewer tries to reconnect for about 15 seconds before showing that the session ended.

The limitations of preview 2 still apply:

- one display;
- SDR H.264 over TCP;
- keyboard and mouse only;
- the standard arrow pointer while controlling;
- no audio or clipboard.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. All CI and builds run on the local host; GitHub Actions is disabled.
