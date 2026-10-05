# Mooring 0.3.0 preview 12 — Sound

Installed copies of preview 6 or later update to this version by themselves when no session is connected.

## Hear the sharing Mac

The sharing Mac's sound now plays on the viewing Mac: videos, music, alerts and calls. It's stereo at 48 kHz, compressed with Opus at 128 kbps, which is under 2% of a typical video stream.

- **Delay:** designed for about a tenth of a second, which should keep sound in step with the picture. This hasn't yet been measured between two Macs.
- **Your output:** sound plays through the viewing Mac's current output. If you switch to headphones mid-session, it follows within a second or two.
- **Turning it off:** **Play Sound from Shared Mac** in the menu bar, on the viewing Mac. It's on by default and takes effect at once.
- **On the sharing Mac:** sound keeps playing there as well. Mooring doesn't change its volume. Mute it there if you don't want both.

Mooring captures sound with the same ScreenCaptureKit permission it already uses for the screen, and never includes its own sound. No new permission is needed.

## Built to stay smooth

- **Network pauses:** the sharing Mac never queues more than 80 ms of sound behind a slow connection. Newer sound is dropped instead, so delay can't build up.
- **Jitter:** the viewing Mac waits for 40 ms of sound before playing, which rides out ordinary Wi-Fi jitter.
- **Bursts:** if more than 150 ms arrives at once, as after a pause, the oldest is skipped to bring the delay back to 40 ms.
- **Running dry:** if sound runs out, playback pauses and resumes once 40 ms is buffered again.

Every 10 seconds the viewing Mac's session log reports how sound is doing ("viewer sound, last 10 s"). It shows packets received, any missing, running dry and trimming.

## Needs both Macs on preview 12

Both Macs must run preview 12 for sound. At launch, each Mac encodes and decodes a short tone to confirm Opus works before offering sound. With an older Mac on either end, sessions work as before, silently.

## Validation

Local validation passed with 109 Rust session tests, including the new sound checks:

- the packet format;
- direction, protocol and capability gating;
- dropping bursts beyond 400 packets a second;
- the 40 ms and 150 ms playout rule.

The native media suite runs Opus through AudioToolbox without capturing or playing anything. It covers ScreenCaptureKit-style buffers, the playout buffer and the 80 ms send bound. The encrypted loopback carries Opus from host to viewer and decodes it. Real capture, playback and lip sync are two-Mac checks.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
