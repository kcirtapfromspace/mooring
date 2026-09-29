# MacLink 0.3.0 preview 2 — Native session fixes

Fixes from the first two-Mac test of the experimental native session. Both Macs must run this preview.

- **One pointer.** With keyboard and mouse enabled, the sharing Mac no longer draws its own pointer into the video; your local pointer is the remote pointer and responds without delay. It always shows the standard arrow for now. In a view-only session, your pointer is hidden over the video and the remote pointer is shown instead.
- **Paired Macs in Connections.** MacLink pairings now appear in the Connections window alongside Apple Screen Sharing Macs. Connect and double-click work for both kinds; **Remove** forgets a pairing, including its secret. Check Connection applies to Screen Sharing Macs only.
- **Sessions stay up.** A connected session keeps both Macs from idle display and system sleep, so a quiet sharing Mac no longer ends the session when its display sleeps or its screen saver starts. Locking, sleeping or stopping sharing still ends it. A frame that the hardware encoder or decoder drops or rejects now recovers with a fresh keyframe; only a run of failures ends the session.
- **Clear endings.** When a session ends, the viewer shows why, with **Reconnect** and **Close**, instead of a blank screen.
- **Higher frame rate on Retina displays.** The sharing Mac now encodes the next frame while the previous one is still being sent, with at most two frames in flight. In local loopback tests this raised a 3024×1964 stream from about 30 to about 51 frames per second and a 3456×2234 stream from about 28 to about 41. Real-network rates will be lower and depend on the link.
- The status line shows the sharing Mac's resolution and reports "screen unchanged" when no new frames are needed, because the sharing Mac sends frames only when its screen changes. Diagnostics now include encoder drops and failures.

Local validation passed with 128 Rust tests (61 for the session) and every native Swift suite, including new checks for the two-frame bound and decoder failure recovery.

## Limitations

Not yet tested between two Macs beyond the first session that prompted these fixes. The pointer does not yet reflect the remote cursor's shape. One display, SDR H.264 over TCP, keyboard and mouse only; no audio, clipboard or automatic reconnection. Intended for the local network. No claim of performance parity with Apple Screen Sharing.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. All CI and builds run on the local host; GitHub Actions is disabled.
