# MacLink 0.3.0 preview 7 — First automatic update

This is the first release installed copies can pick up by themselves. If you run preview 6, you don't need to download anything. MacLink installs preview 7 and relaunches the next time no session is connected, usually within four hours. To update right away, choose **Check for Updates…** or **Install Update … & Relaunch** in the menu bar.

## Smoother start of each session

At connect, the sharing Mac sends every frame it captured while the viewing Mac was still setting up its decoder. Those frames arrive together, and the six-frame queue from preview 4 could overflow once. The picture then waited for a fresh full frame. The viewing Mac now lets up to 16 frames wait (about 0.27 s at 60 fps). Decoding takes about 5 ms each, so even a full queue clears in about 80 ms.

The connection protocol is unchanged, so previews 4 to 7 connect to each other while the two Macs update at different times.

## Validation

Local validation passed with 153 Rust tests and every native Swift suite. The decoder checks now run at the 16-frame bound.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
