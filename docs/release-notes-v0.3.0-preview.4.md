# Mooring 0.3.0 preview 4 — Shared clipboard and steadier sessions

Both Macs must run this preview; earlier previews cannot connect to it.

## Shared clipboard

While a Mooring session is connected, copy on one Mac and paste on the other. It works both ways and carries text, rich text and images, up to 4 MiB per copy. When you connect, whatever you already copied on the viewing Mac becomes available on the sharing Mac. This isn't done for a brand-new pairing, and a reconnect doesn't send the same item again.

The clipboard is on by default. Turn it off on either Mac with **Shared Clipboard** in the menu bar or the checkbox in **Share This Mac**; when it's off, that Mac neither sends nor accepts clipboard content.

Privacy protections:

- Items that password managers mark as private or temporary are never sent.
- Mooring pairing codes are never sent, even after the app that carried the code drops its privacy marker.
- Copied files send only their names, not the files.
- The session log records only the kind and size of each transfer, never the contents.

macOS 15.4 and later can ask before an app reads the clipboard in the background. The first time you copy something during a session, macOS may ask whether Mooring can access it; allow it for the clipboard to cross. If you choose to always deny, Mooring stops reading this Mac's clipboard. You can change that choice in System Settings → Privacy & Security.

## Fewer dropped sessions

On a live session, the watcher captured a drop in preview 3. The sharing Mac ended the session with "The other Mac sent an invalid or incomplete session message". Just before, the round trip spiked to 136 ms. A message from the viewer was still arriving when the sharing Mac's one-second receive window ended, so it was rejected as a protocol error.

Now, once a message has started arriving, it gets up to 10 seconds to finish. Preview 3's automatic reconnection had restored that session within a second.

## Smoother picture

When several frames arrived together after a brief network pause, the viewing Mac discarded them and waited for a fresh full frame, causing a short freeze. It now lets up to six frames (about 0.1 s) wait while one decodes. If a full frame is already waiting when it recovers, that frame is used rather than requesting another.

## Other fixes

- **Mouse moves:** they merge while a large clipboard is sending, so the session can't overflow its send queue.
- **Rejected items:** clipboard items Rust would reject are left out instead of ending the session.
- **Version mismatch:** a connection refused because the Macs run different Mooring versions now says to update both Macs.

## Clearer frame rate

The viewer's status bar now reads, for example, "12 fps as the screen changes". The sharing Mac sends a frame only when its screen changes, so a low number on a quiet screen is expected and is not a limit. On the same session, frames ran at 56 fps end to end during continuous motion.

## Validation

Local validation passed with 153 Rust tests (84 for the session) and every native Swift suite. New checks cover:

- the clipboard wire format and each malformed variant;
- the size bound and the four-per-second limit;
- clipboards in both directions over a real encrypted loopback, up to the 4 MiB maximum;
- private-item filtering, echo prevention and image conversion, on a private test pasteboard;
- a message that starts near the receive deadline;
- the decoder's six-frame bound;
- recovery using a keyframe that's already queued;
- pointer moves merging behind a 4 MiB clipboard on a live channel;
- pairing codes and invalid representations never being sent.

## Limitations

The shared clipboard has not yet been tested between two Macs. It carries text, rich text and PNG images, not files or other formats. Items larger than 4 MiB are skipped; if an image doesn't fit alongside its text, only the text is sent.

The limitations of preview 3 still apply:

- sharing stops while the sharing Mac's display sleeps;
- the viewer spends about 15 seconds reconnecting after sharing is stopped on purpose;
- one display;
- SDR H.264 over TCP;
- no audio.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. All CI and builds run on the local host; GitHub Actions is disabled.
