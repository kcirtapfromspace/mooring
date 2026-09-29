# MacLink 0.3.0 preview 10 — Your screen size, and the real pointer

Installed copies of preview 6 or later update to this version by themselves when no session is connected.

## Native resolution on the viewing Mac

Until now you saw the sharing Mac's own screen, letterboxed and scaled to fit yours. Your Mac Studio has no monitor attached, so macOS gives it a 1920×1080 placeholder screen. On a MacBook Pro that was enlarged about 1.6×, with bars top and bottom.

Now the viewing Mac tells the sharing Mac the exact size of its video area and its Retina scale. The sharing Mac then shows its desktop on a virtual display of exactly that size: for example 1512×916 points at 2×, which is 3024×1832 pixels. The picture fills the window with one pixel per screen pixel, so nothing is scaled.

- **Timing:** the request goes out once the window's size has held steady for a second, such as after entering full screen. Resizing the window resizes the virtual display.
- **Headless sharing Mac:** the virtual display replaces macOS's placeholder.
- **Sharing Mac with a monitor:** the monitor mirrors the virtual display for the session, and its windows may be rearranged, as when you plug in a display.
- **When the session ends:** the virtual display is removed and the original arrangement returns. macOS also removes it if MacLink quits.
- **Turning it off:** **Match Shared Screen to This Mac** in the menu bar, on the viewing Mac. It's on by default.

The virtual display uses a private macOS API, the one Apple's own Screen Sharing uses for High Performance mode. MacLink looks it up before using it; if a future macOS removes it, MacLink shares the sharing Mac's own display as before.

## The pointer shows what it would on the other Mac

While you control the sharing Mac, the pointer over the video now takes that Mac's current shape: an I-beam over text, resize arrows at a window edge, a pointing hand over links. Before, it was always an arrow.

- **Sharing Mac:** it samples its own pointer ten times a second, using a public macOS API, and sends the image only when it changes.
- **Size:** a pointer is typically under 2 KB.
- **Limit:** at most 20 changes per second.

## Display changes no longer end the session

If the sharing Mac's display changes during a session, whether from a viewer-sized display appearing or disappearing, or a resolution change, MacLink now restarts capture on the new display and sends the viewer the new geometry. No input is accepted until the viewer has the new size. Before, the session ended with "Display geometry changed". Restarts are limited to six in 30 seconds.

## Needs both Macs on preview 10

Both Macs must run preview 10. With an older Mac on either end, the session works as before, at the sharing Mac's own resolution.

## Validation

Local validation passed with 100 Rust session tests, including the new display request checks:

- exact scale 1 or 2 and pixels that match the points;
- the size limits and the all-zero release request;
- requests only from viewers, to hosts that announced the capability, in protocol 5.

Pointer checks cover the image format, size and hotspot bounds, direction, capability gating and the per-second limit. The encrypted loopback carries a pointer shape from host to viewer, which becomes a cursor of the right size and hotspot.

At a MacBook Pro resolution, HEVC 4:4:4 encodes in about 17 ms per frame on this Mac. That's 3024×1900 pixels; 1920×1080 takes about 10 ms.

On this Mac (headless), `scripts/test-virtual-display.sh` passed. It is run by hand because it changes the display arrangement:

- **Request, 1512×916 points at 2×:** became the main display at exactly 1512×916 points, 3024×1832 pixels.
- **Resize, 1280×800 at 2×:** applied in place.
- **Release:** macOS's 1920×1080 placeholder was back immediately.

Two earlier runs found problems, both fixed before release. Modes had to be given in points. And the display lingered after release until a leftover reference was cleared.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
