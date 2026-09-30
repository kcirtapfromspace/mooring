# MacLink 0.3.0 preview 13 — Viewer-sized screen fix

Installed copies of preview 6 or later update to this version by themselves when no session is connected.

## Sessions no longer drop every few seconds

With preview 10 or later on both Macs, a session could end about 3 seconds after it started and then reconnect, over and over. The sharing Mac showed "Screen capture stopped: Failed to find any displays or windows to capture".

This happened when the viewing Mac asked for a screen of its own size (**Match Shared Screen to This Mac**). When the sharing Mac created that screen, macOS stopped the screen capture before it reported the new screen, and MacLink treated that as fatal. The session then ended, the screen was removed, and the next connection asked for it again.

Now the sharing Mac pauses capture itself before switching screens, and resumes on the new screen once macOS has it ready. It resumes on its current screen after at most 5 seconds if the switch doesn't finish. If macOS stops capture during any other display change, capture restarts and the session continues.

Only the sharing Mac needs preview 13 for this fix. Sound (preview 12) and everything else is unchanged.

## Validation

Local validation passed with the full suite. The local suite doesn't change displays, so this fix is confirmed on the two Macs.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
