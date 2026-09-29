# MacLink 0.3.0 preview 5 — Clipboard fixes

Install on both Macs. The connection protocol is unchanged, so preview 5 still connects to preview 4.

## Shared clipboard no longer bounces or freezes the session

In preview 4, a copied image bounced between the two Macs about once a second. When MacLink placed a copy on one Mac, Universal Clipboard (Apple's Handoff clipboard between Macs on the same Apple ID) carried it back. MacLink on the other Mac then treated it as a new copy and sent it again.

MacLink also read the clipboard on the thread that draws the picture. Universal Clipboard fetches data across the network only when an app asks for it. On the viewing Mac, that stalled the picture for several seconds and ended the session, which then reconnected.

Now:

- **No echo:** MacLink never re-sends the item it last exchanged in either direction, whatever path brings it back.
- **Universal Clipboard items skipped:** anything Universal Clipboard brought from another device isn't sent. Both Macs on the same Apple ID already have it.
- **Off the picture thread:** every clipboard read and write happens on its own background queue, so a slow read can't freeze the picture or the connection.

## Pasting a screenshot into a terminal

A screenshot copied on one Mac arrives on the other as an image. Terminal apps paste text with ⌘V, so an image-only clipboard pastes nothing there. Claude Code pastes images with Ctrl+V. Paste into an app that accepts images to check the transfer, such as Notes, Preview or TextEdit.

## Validation

Local validation passed with 153 Rust tests and every native Swift suite. New checks use a private test pasteboard, never the user's clipboard, and cover:

- items that come back through another path;
- Universal Clipboard items;
- repeated copies of the item just sent;
- polls that pile up behind a slow read;
- clipboard work staying off the main thread.

The clipboard, including macOS's clipboard-access prompt, has not yet been tested between two Macs.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. All CI and builds run on the local host; GitHub Actions is disabled.
