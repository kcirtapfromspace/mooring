# MacLink 0.3.0 preview 11 — Trackpad gestures

Installed copies of preview 6 or later update to this version by themselves when no session is connected.

## Pinch, rotate and smart zoom

While you control the sharing Mac, trackpad gestures on the viewing Mac now act on the sharing Mac:

- **Pinch** zooms in Preview, Safari, Maps and other apps that zoom with a pinch.
- **Rotate** turns images in Preview and anywhere else that supports it.
- **Smart zoom**, a two-finger double tap, zooms to the part of a web page or PDF under the pointer.

Before, these gestures did nothing over the video.

Three- and four-finger swipes still belong to the viewing Mac, so Spaces, Mission Control and App Exposé switch on the Mac in front of you.

macOS has no public way for an app to create gesture events. The sharing Mac builds them with the same private event fields macOS's own test tools use. If a future macOS stops accepting them, gestures do nothing on the sharing Mac; everything else works as before.

## Safe cleanup

Only one gesture is open at a time. If the session ends, focus leaves the viewer, or you stop control mid-pinch, the sharing Mac ends the gesture so no app is left half-zoomed.

## Needs both Macs on preview 11

Both Macs must run preview 11 for gestures. With an older Mac on either end, the viewer doesn't send them and everything else works.

## Validation

Local validation passed with 103 Rust session tests, including the new gesture checks:

- one phase per event and bounded, finite values;
- one gesture at a time, and cleanup ending an open gesture;
- gestures only to hosts that announced them.

The native input suite builds each gesture event and reads it back through AppKit without posting it. A pinch becomes a magnify event with its phase and value, a rotation a rotate event, and a smart zoom a smart magnify event. Delivery to apps on the sharing Mac is a two-Mac check.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
