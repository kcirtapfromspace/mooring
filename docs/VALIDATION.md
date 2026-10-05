# Preview validation

Validated locally on an Apple M1 Ultra running macOS 26.6.2. Rust 1.98.1 and the installed Xcode toolchain were used. No GitHub runner or remote CI was used.

## Automated checks

- Workspace formatting and Clippy with warnings denied.
- 127 Rust tests: eight CLI/storage tests, 41 network/quality/mailbox/reconnect tests, 18 platform tests, and 60 native-session tests.
- 73 Swift connection-document parser and bounded-reader checks, including IPv6, ambiguous modes, invalid ports, oversized files, symlinks and FIFOs. These perform no Accessibility actions.
- Packaged CLI integration against a live loopback RFB fixture verifies zero application bytes sent, real timing/route JSON, policy-state round-trip, and connection-refused output.
- Storage tests exercise concurrent saves, corrupted/future schemas, private file permissions, oversized IDs, and malformed input.
- Local mock servers exercise valid/fragmented/truncated/malformed RFB greetings and aggregate timeouts without authenticating.
- Platform launch tests verify successful, failed, and hung helper-process handling.
- Policy unit tests use synthetic telemetry to check hysteresis, unknown routes, VPN overrides, stale callbacks, invalid samples and retry budgets. The menu-bar runtime consumes live target probes. Neither proves live video latency or successful Apple mode negotiation.
- Native Swift compilation, bundle metadata lint, ad hoc code signature validation, and release archive checks.

## Preview 2 notarization

The complete local validation script passed again with all 40 tests. Both executables were signed with Developer ID, hardened runtime, and secure timestamps. Apple accepted submission `33b0a81d-3418-411e-9bc8-e3f072bfad76`; its log reports no issues. The final ZIP contains the stapled app. `stapler validate`, strict signature verification, and `spctl --assess --type execute` all passed after extracting that ZIP; Gatekeeper reported `source=Notarized Developer ID`. No Gatekeeper override was used.

## Automation preview notarization

Apple accepted submission `06ba781a-fd15-49be-aa71-1ac4b358b162` for `v0.2.0-preview.1` with no issues. Both arm64 executables use Developer ID, hardened runtime and timestamps. The app was stapled and the final ZIP was extracted for strict signature, ticket and Gatekeeper verification; Gatekeeper reported `accepted` and `source=Notarized Developer ID`.

## GUI check

Used a separate app identifier and isolated connection store. Verified empty state, Add Mac, the saved connection list, an RFB check against a localhost mock server, a clear refused-connection error after that server stopped, and readable/scrollable diagnostics. No real remote session was initiated by this QA flow.

For the automation preview, an isolated accessory app verified first-run setup, adding a localhost target, the 610×660 scrollable settings window, live Check Current Path results, explicit home marking, saving/reopening settings, closing Connections without quitting, reopening it with the menu command, and quitting the QA copy. Accessibility and login registration were not granted or changed during QA. The user's existing app and connections were preserved.

Review corrected queued-action cancellation, stale network-change callbacks, intentional viewer quit handling, and the cancelled-authentication retry path. No two-Mac Accessibility or mode transition is claimed by those reviews or parser tests.

## Home-settings regression checks

The updated local detector completed in approximately 0.3 seconds on this host without contacting a remote Mac. Local CI exercises router identity parsing, missing/ambiguous neighbors, IPv6/VPN route handling, timeout cleanup, and detection with a corrupted isolated connection store. Swift state tests cover late callbacks, timeout recovery, network invalidation, explicit marking, saving, bounds and settings migration.

A separate QA app verified Detect Network → Use This Network as Home → Save with no saved Mac, persisted home settings after adding a Mac, and successful detection while background checks repeatedly failed against an unreachable loopback target. The candidate remained usable after those failures. No Accessibility or login permissions were changed.

Apple accepted the home-settings fix, `v0.2.0-preview.2`, as submission `3e09ae81-d055-4f19-89e2-0ccb1c2f1b12`. The final extracted ZIP passed strict code-signature verification, stapled-ticket validation and Gatekeeper assessment as Notarized Developer ID.

## Automatic-defaults regression checks

For `v0.2.0-preview.3`, the complete local validation script passed with 67 Rust tests, 73 Swift session-document checks and the expanded defaults/home-state suite. Tests cover automatic trial eligibility and dwell, VPN/unknown-route exclusion, revocation fallback, explicit target selection, target-isolated learned paths, bounded deduplicated persistence, legacy migration and preservation of explicitly disabled/custom settings.

An isolated QA bundle showed the address-only Add & Connect form and expanded optional name/port controls without clipping. The contextual permission window was also observed. This check did not grant Accessibility, register login launch, or verify a real remote connection. Permission-granted automatic continuation, learned-path reconnect and High Performance trials still require the two-Mac checks below.

Review corrected permission-completion duplicate-launch races, paused-session closure handling, stale recommendations on explicit reconnect, migration of explicitly disabled new settings and switching targets while an old session remains tracked.

Apple accepted the automatic-defaults build as submission `bb184472-bbf6-4730-bdbb-5d3bc1ab01ef`. The final extracted arm64 ZIP passed strict signature, stapled-ticket and Gatekeeper validation as Notarized Developer ID.

## Native session preview

For `v0.3.0-preview.1`, the complete local validation script passed with 127 Rust tests and every native Swift suite. The 60 session tests cover Noise authentication with a pinned key and pairing secret, key confirmation before a handle is published, tamper and replay rejection, bounded chunked framing, deadlines and cancellation, per-role message direction, rate limits, ping and keyframe spacing, geometry before video, the idle limit, every typed wire format and its malformed variants, the host's staged held-input state, pairing codes and legacy Keychain credentials, the saved-peer store, and the C ABI. Struct layouts are asserted at compile time in both Rust and the C header.

Swift suites cover the input boundary and Command key-up dispatch through an off-screen in-process window, privacy-state classification, the session wrappers, and real hardware H.264: 120 paced 1080p frames plus a 4K smoke check, keyframe-flag and in-band-configuration rejection by the Rust validator, gap/overflow recovery and bounded keyframe retry. An encrypted loopback integration streams 120 hardware-encoded 1080p frames at 60 fps with a return input event per frame. These use synthetic pixels and loopback only: no screen capture, remote Mac, Keychain, permission request or injected input.

Review corrected Command-held key releases that AppKit never delivers, keyframe requests dropped by the host's spacing, a handshake cut off at the end of the host's accept window, and connections blocked by an unwritable peer list.

Apple accepted the native session build as submission `cfa02dc6-48de-466f-8fca-bcb1843e5030` with no issues. Both arm64 executables use Developer ID, hardened runtime and secure timestamps. The final extracted ZIP passed strict signature, stapled-ticket and Gatekeeper validation as Notarized Developer ID. The built app was not launched on this host, and no permission was granted or changed.

## Native session fixes

For `v0.3.0-preview.2`, the complete local validation script passed with 128 Rust tests (61 session) and every native Swift suite. New checks cover forgetting saved peers (including never rewriting an unreadable store), the encoder's two-frame in-flight bound with held transport sends, and decoder recovery: isolated failures request a keyframe without ending the session, while a run of five is reported. Restoring the old fatal-on-first-failure decoder behavior made that test fail.

A paced 60 Hz synthetic feed through the hardware encoder, encrypted loopback and hardware decoder measured decoded frame rates before and after allowing two frames in flight: 3456×2234 rose from 28.3 to 41.3 fps, 3024×1964 from 30.3 to 51.0 fps, and 1920×1080 stayed at 60 fps. Loopback excludes network transmission, capture and display.

The pointer, Connections list, power assertions and session-ended overlay are AppKit behavior verified only by compilation here; they need the two-Mac checks in the testing guide.

Apple accepted the preview 2 build as submission `28240f8a-2fc0-4079-97e9-92d24f05ceb2` with no issues. The final extracted arm64 ZIP passed strict signature, stapled-ticket and Gatekeeper validation as Notarized Developer ID.

## Telemetry, automatic sharing and reconnection

For `v0.3.0-preview.3`, the complete local validation script passed with 145 Rust tests (76 session, 10 CLI) and every native Swift suite. New Rust checks cover:

- the telemetry wire format and every tuning bound;
- the direction rule that only viewers tune;
- the owner-only socket folder, its client and per-line limits, commands from clients that close immediately, and stale-file handling;
- the bounded reconnect backoff;
- the chords that stay on the viewing Mac.

The encrypted hardware loopback now carries stats both ways and a tuning command to the host. The session suite drives the real `mooring telemetry` and `tune` commands against the app's socket.

Automatic sharing, ⌘-Tab capture through an event tap, reconnection in the same window, and capture restarts for a new width are AppKit and ScreenCaptureKit behavior, verified here only by compilation and by the Swift boundary checks. They need the two-Mac checks in the testing guide. The cause of the preview 2 disconnects is not yet known. This build logs every session end with Mooring's reason and reports it in telemetry.

Review made these corrections before release:

- automatic sharing no longer resumes while the display sleeps;
- automatic reconnects no longer take focus;
- held keys are released when macOS interrupts the shortcut tap;
- reconnects no longer rewrite saved pairings;
- a pairing to a different Mac starts a fresh reconnect budget;
- view-only sessions keep Command shortcuts local;
- a retired capture's cancellation can no longer end a session during a width change;
- width changes restart capture at most once a second;
- encoder counters no longer go backward after a restart;
- telemetry commands from clients that disconnect immediately still apply.

## Shared clipboard and receive grace

For `v0.3.0-preview.4`, the complete local validation script passed with 153 Rust tests (84 session) and every native Swift suite. Clipboards cross the real encrypted loopback in both directions: all three kinds to the host, 3 MB of text to the viewer, and the 4 MiB maximum through a live channel while 1,000 pointer moves merge behind it. New checks cover:

- each malformed clipboard message, including clearing rejected plaintext;
- the per-second limit;
- private-marker filtering, echo prevention across apply and reconnect, off-main TIFF conversion and superseded conversions, on a private uniquely named pasteboard;
- a two-record message whose second record arrives after the caller's receive deadline, which previously ended the session;
- the viewer decoder's six-packet bound, and recovery from a keyframe that's already queued (the previous flush fails this test).

Review before release led to these changes:

- clipboard items Rust would reject are dropped rather than ending the session;
- pairing codes are never shared;
- a fresh pairing doesn't share the current clipboard;
- pointer moves merge behind large writes;
- image conversions are limited to one at a time;
- a version mismatch at connect is explained;
- a keyframe queued during recovery is kept.

macOS 15.4 and later may ask before Mooring reads the clipboard in the background; that prompt has not been exercised here.

A live preview 3 session between two Macs, watched from the sharing Mac, recorded one drop: `The other Mac sent an invalid or incomplete session message`. It came right after round-trip spikes of 104–136 ms, and the viewer reconnected in 0.8 s. The receive grace addresses that path. Whether it removes every drop still needs two-Mac confirmation.

## Clipboard echo fix

In a live preview 4 session between two Macs, a copied image bounced between them about once a second. Universal Clipboard carried each applied copy back to the other Mac, which sent it again. The viewing Mac's picture then stalled for seven seconds: it received about 57 fps, presented none, and its round-trip measurement stopped updating. The session ended and reconnected 0.8 s later.

For `v0.3.0-preview.5`, every pasteboard access moved to one serial background queue, with polls coalesced. The item last exchanged in either direction is never re-sent, and items marked `com.apple.is-remote-clipboard` are skipped. The complete local validation script passed with 153 Rust tests and every native Swift suite, including new private-pasteboard checks for each case.

## In-place updates

For `v0.3.0-preview.6`, the complete local validation script passed with 153 Rust tests and every native Swift suite. `scripts/test-update-local.sh` then ran over loopback only, using ad hoc builds under a separate bundle ID with a separate data folder and preferences:

- **Install:** an installed build 9000 read a signed local feed and fetched build 9001. It verified the EdDSA signatures, installed the new build in place and relaunched it within 3 s of launch. The relaunched copy passed strict code-signature verification.
- **Refusals:** an archive changed after signing was fetched and refused. A feed changed after signing was read, and no archive was fetched.

The embedded Sparkle 2.10.0 framework is pinned by SHA-256, thinned to arm64 and stripped of its unused XPC services and headers. Each nested component is signed before the app. An update between the two Macs from the public feed has not yet been observed; the first will be the release after preview 6.

## First automatic update

`v0.3.0-preview.7` raises the viewer decoder's bound from 6 to 16 packets. Two-Mac telemetry on previews 4 and 6 showed a single overflow in the first second of each session: the sharing Mac captured about 30 frames while the viewing Mac was still starting its decoder. The complete local validation script passed with 153 Rust tests and every native Swift suite. It is the first release published for installed copies to pick up by themselves.

## Display-paced viewer

In a preview 7 session between two Macs, the viewing Mac decoded 55–59 fps during motion but drew only 30–50. The network, capture and decoder were keeping up. For `v0.3.0-preview.8`, the viewer draws once per display refresh from a two-frame queue, keeps up to two frames rendering on the GPU and tags its drawable sRGB.

`scripts/measure-native-present.swift` drives the real view on screen on the build Mac (M1 Ultra, 60 Hz display) with synthetic decoder-tagged 1920×1080 frames at 60 fps:

| Arrival | Drawable | Drawn | Replaced |
|---|---|---|---|
| Even | 1600×900 window | 60 of 60 fps | 0 |
| Even | 3456×2234 | 60 of 60 fps | 0 |
| In pairs | 1600×900 window | 60 of 60 fps | 0 |
| In pairs | 3456×2234 | 57 of 60 fps | 14 in 5 s, by design |

Each frame cost about 0.2 ms on the processor and at most 0.4 ms on the GPU. On `presentedTime`:

- It stays zero for this windowed view, so "presented" counts frames handed to the display, not frames confirmed on the glass.
- The same harness drew about 60 fps with the old code on this fast Mac, so it doesn't reproduce the viewing Mac's shortfall.
- That Mac's own 10-second drawing log (local only) will show whether the change fixed it.

The complete local validation script passed with 153 Rust tests and every native Swift suite.

## HEVC 4:4:4 and protocol negotiation

For `v0.3.0-preview.9`, the session protocol negotiates versions 4–5. The Rust suite covers:

- version negotiation in both directions, and fallback to a host that accepts only version 4;
- the Hello rules: at most once, version 5 only, unknown bits kept;
- `MLV2` HEVC packets and their malformed variants;
- SPS chroma parsing, including an emulation-prevention byte;
- HEVC gated on the peer's capability on send and on the local capability on receive.

On the build Mac (M1 Ultra), the native media suite ran 120 paced 1080p frames through the hardware HEVC 4:4:4 encoder and decoder, at 60 fps:

- Every SPS reported 4:4:4.
- ffprobe independently read HEVC Rext `yuv444p` with no B-frames.
- Encode averaged about 10.4 ms and decode about 3.4 ms (`target/native-media-report.json`).

The encrypted loopback added a version 5 phase in which the viewer decoded HEVC 4:4:4 from the host after the capability exchange. The viewing Mac's hardware decode support isn't known here; its launch self-test decides.

## Viewer-sized virtual display

For `v0.3.0-preview.10`, the Rust suite added display request checks:

- exact scale, and pixels that match the points;
- size limits, and the all-zero release request;
- direction, protocol 5 only, and capability gating on send and on receive.

Encode cost at MacBook Pro sizes on the build Mac: HEVC 4:4:4 averaged about 17 ms per frame at 3024×1900 and 22 ms at 3456×2234. H.264 took 19 ms and 25 ms.

A first run of the private API on the build Mac (headless, with macOS's 1920×1080 placeholder):

- it created, resized and removed a Retina virtual display;
- macOS chose a doubled mode unless the exact Retina mode was selected, so Mooring now selects it;
- the virtual display replaced the placeholder, and a new placeholder appeared after release.

That run interrupted a live session three times, because the old capture code ended the session on a display change. It now restarts capture instead.

`scripts/test-virtual-display.sh` checks the request → main display → release cycle. It is manual because it changes the display arrangement, and must not run during a session. Its first run failed:

- modes are given in points, not pixels;
- selecting a mode across the session failed with error 1001;
- the display lingered after release because an autoreleased reference was never drained.

After those fixes, it passed on the build Mac: 1512×916 points became the main display at 3024×1832 pixels, a resize to 1280×800 applied in place, and release restored the 1920×1080 placeholder at once.

## Trackpad gestures

For `v0.3.0-preview.11`, the Rust suite added gesture checks:

- a single phase (began, changed, ended or cancelled) and a finite value: magnification within ±5 per event, rotation within ±360°;
- smart zoom carries only a position;
- one open gesture at a time; a change or end for a gesture that isn't open is ignored, and cleanup ends an open gesture;
- gestures only from viewers to hosts that announced the capability.

The native input suite builds each gesture with the private event fields and reads it back through AppKit, without posting it: a pinch becomes a magnify event with its phase and value, a rotation a rotate event with its degrees, and a smart zoom a smart magnify event. Whether macOS delivers a posted gesture to apps on the sharing Mac is checked only between two Macs.

## Sound

For `v0.3.0-preview.12`, the Rust suite added sound checks:

- the packet format: Opus only, one or two channels, 5, 10 or 20 ms, and at most 1500 bytes;
- direction (sharing Mac to viewer only), protocol 5 only, and capability gating on send and on receive;
- beyond 400 packets a second, sound is dropped rather than ending the session;
- the playout rule: playback starts at 40 ms buffered, and beyond 150 ms the oldest sound is trimmed back to 40 ms.

The native media suite, with no capture or playback:

- runs the launch self-test (a tone through AudioToolbox's Opus encoder and decoder);
- feeds ScreenCaptureKit-style planar stereo and interleaved mono buffers, which become 10 ms packets (about 160 bytes at 128 kbps), and skips sound at another sample rate;
- keeps only the newest 100 ms when too much arrives at once;
- decodes both channels;
- checks that the playout buffer waits for 40 ms, deinterleaves, pauses when it runs dry and trims a burst;
- checks that the sending side holds at most eight packets and numbers across drops.

The encrypted loopback carries 100 ms of Opus from host to viewer in order after the capability exchange, and the viewer decodes it into the playout buffer.

Capture of real system sound, playback, output device changes and lip sync are checked only between two Macs.

## Viewer-sized display between two Macs

The first real two-Mac run of the viewer-sized display (preview 12 on both Macs) failed. Each session ended about 3 s after it started with "Screen capture stopped: Failed to find any displays or windows to capture", and the viewer reconnected in a loop. ScreenCaptureKit stopped the stream when the virtual display replaced the headless placeholder, before CoreGraphics reported the new main display, so Mooring treated it as fatal.

For `v0.3.0-preview.13`:

- the sharing Mac stops capture itself before changing the display, and captures the display in use once macOS has it ready;
- ScreenCaptureKit's "no display, window or capture source" errors count as a display change, which restarts capture instead of ending the session;
- a display that has no ID yet is waited for within the existing 3 s bound;
- if capture has not resumed 5 s after a change, it resumes on the current main display.

The fix is verified on the two Macs, not by the local suite, which does not change displays.

## Latency measurement

For `v0.3.0-preview.14`, the viewer measures, per frame, the time from a screen change on the sharing Mac to that frame appearing on its own display.

- Frames carry ScreenCaptureKit's display time, the moment the change reached the sharing Mac's screen.
- A sharing Mac answers the viewer's once-a-second ping with a clock reply carrying its own time. The viewer places the two clocks with the fastest of its last 16 replies, as NTP does, and the error is at most half that round trip.
- Both Macs count CoreMedia host time. On the build Mac it agreed with CACurrentMediaTime and the process uptime to within 13 µs.

The Rust suite added:

- the clock reply format, sent only by hosts, only in protocol 5 and only to viewers that announced the latency capability;
- latency metrics, left out of stats sent to older peers, which would otherwise end the session on an unknown ID;
- the clock estimate: the fastest round trip wins, and replies slower than 1 s or out of range are ignored.

The native session suite checks the clock placement, the latency arithmetic and the percentiles. The encrypted loopback exchanges real clock replies. The placed offset was zero within its bound, as expected with both ends on one Mac. Thirty HEVC 4:4:4 1080p frames stamped with the capture clock measured a median of about 12 ms from capture timestamp to decoded, covering encode, encryption, transport and decode.

Between two Macs, the figure also includes ScreenCaptureKit's delivery, the network, and waiting for the viewer's display refresh. Two-Mac values are reported, not asserted.

## Encoder pacing

Preview 14 between the two Macs (sharing Mac at 3360×2032) showed HEVC 4:4:4 encoding took about 50 ms per frame, even at 2 frames a second with nothing queued. Preview 14 also left the latency capability out of what each Mac announces, so the latency figures never started; `v0.3.0-preview.15` announces it, and a native session check covers the announced set.

Benchmarks on the build Mac (M1 Ultra), with text-heavy 3360×2032 frames and the live session running, found the cause. In real-time mode, VideoToolbox paces the HEVC encoder to the gap between frame timestamps. A desktop changes in bursts, so most frames follow a pause and were encoded slowly, and with a larger bit budget.

| Frames arrive | Real-time mode | Without |
|---|---|---|
| 16 ms apart | 23 ms, 119 KB | 17 ms, 104 KB |
| 33 ms apart | 23 ms, 164 KB | 18 ms, 145 KB |
| 100 ms apart | 54 ms, 380 KB | 19 ms, 210 KB |
| 500 ms apart | 56 ms, 386 KB | 18 ms, 197 KB |

What changed and what didn't:

- **What didn't matter:** colour tagging (about 2 ms), the power-efficiency setting, and frame pacing with evenly spaced timestamps.
- **Why not switch encoders:** low-latency HEVC 4:2:0 and H.264 took 25–27 ms, so HEVC 4:4:4 without real-time mode is both the fastest and the sharpest.
- **Decoding:** it didn't depend on real-time mode (8–10 ms on the build Mac).
- **The fix:** preview 15 turns real-time mode off for HEVC and keeps Apple's low-latency mode for H.264. Through Mooring's own encoder, a frame after a 500 ms pause now takes 18 ms instead of 54 ms.
- **Local suite:** 1080p HEVC 4:4:4 encode averages about 7 ms, down from about 10 ms. The loopback median from capture timestamp to decoded fell from about 12 ms to 9 ms.

## Sessions wait for the launch self-tests

After preview 15 installed, the sharing Mac relaunched and started sharing, and the viewer reconnected within about 130 ms. That was before the sharing Mac's self-tests (HEVC 4:4:4, Opus, virtual display) had finished. Each side announces its capabilities once, at the start of a session, so that session ran with H.264 at 1920×1080, no sound, no screen matching and no latency figures.

In `v0.3.0-preview.16`, sharing and connecting wait for the self-tests, which take well under a second. At most eight requests wait. If the tests haven't finished after 5 s, sessions go ahead with the capabilities that need no test.

The local suite does not relaunch the app, so this is verified by the next update between the two Macs: the sharing Mac's log should show the self-test results before "sharing started automatically".

## Viewer decode and presentation

With preview 16 on both Macs (MacBook Pro viewer at 60 Hz, sharing Mac at 3360×2032):

| Stage | Time |
|---|---|
| Latency, screen change to the MacBook's display | median 66–82 ms, 95th percentile up to about 130 ms |
| Until decoding starts | 17–28 ms |
| Decode | about 17 ms |
| Decoded to shown | 25–57 ms |

Totals fell in 16.6 ms steps, the display's refresh.

For `v0.3.0-preview.17`:

- **Decode to YCbCr.** The viewer asks the decoder for YCbCr at the stream's chroma (4:4:4 for HEVC, 4:2:0 for H.264) instead of BGRA. On the build Mac, decoding 3360×2032 text frames took 4.6 ms median against 7.6 ms. Rendered through Core Image into the same sRGB target, the two pictures differed by 0.1 colour levels on average, at most 2 of 255, and the YCbCr path was marginally closer to the source. The encrypted loopback median from capture timestamp to decoded fell from about 9.7 to 7.6 ms.
- **Draw frames on arrival.** Tried and not shipped. Drawing a frame as soon as it was decoded, with Mooring's own display link instead of MTKView's timer, was measured with `scripts/measure-native-present.swift` (now with a sparse, typing-like case and a decoded-to-presented figure). Isolated frames were at best about 5 ms sooner. Steady 60 fps streams were often a refresh later, and the build Mac's virtual display gives no presentation time, so the figures are the presented handler's time. The change was reverted.
- **Lower Display Latency (May Tear).** A new viewer option, off by default, turns off CAMetalLayer display sync. On the build Mac, over two runs each: steady 60 fps into a window, 46–69 ms with sync against 14 ms without; retina-sized, 19–30 against 20–23; isolated frames, 25 against 19–22. Its effect on a real display, including any tearing, is checked between two Macs.

## Pacing and the newest frame

Sampling the live session's send queue with `netstat` found it empty most of the time. The 99th percentile was 49 KB, but it reached 524 KB during a Wi-Fi slowdown, about 200 ms at 20 Mbit/s. The viewer's 95th-percentile latency spiked to 283 ms at the same time as a 143 ms ping. The encoder also discarded frames that arrived while it was busy, so if the last change before the screen went still was discarded, the viewer kept an earlier picture until the next change.

For `v0.3.0-preview.18`:

- **The newest frame always goes out.** A frame that can't start now waits in the encoder, replacing older waiting frames, and starts as soon as a slot frees or the connection clears. Frames older than the last one started are dropped, so the encoder always receives them in order.
- **A frame starts only while the send buffer is under the queue limit.** The limit is 1.5 times the bytes sent per fastest round trip of the last ten seconds, between 128 KiB and 4 MiB, so a long connection stays busy.
- **The bitrate adapts once a second, from how long frames waited.** A second with 150 ms or more of waiting is congested. Two such seconds of the last four lower the bitrate to three quarters, and each three clear seconds raise it 10% (at least 500 kbps), between 4 Mbps and the tuned bitrate. One slow second, as for a single large keyframe, changes nothing.
- **Review fixes.** A code review of the first version found four problems, all fixed before release:
  - it counted each 5 ms retry as a wait, so one keyframe looked like congestion and the bitrate could slide to the floor on a healthy network;
  - a retried older frame could replace a newer waiting one;
  - frames could reach the encoder out of order in a rare interleaving;
  - the bitrate rose every second after three clear ones.
- **Where the rules live.** The pacing rules are in Rust. The send buffer comes from TCP_CONNECTION_INFO, through a struct declared to match the SDK's 112-byte layout; the libc crate's version differs because of a bit field.

Local checks:

- **Rust suite:** the queue limit, admission, the two-of-four rule, one step per three clear seconds, convergence under a periodic slow keyframe, the bounds, a live send-queue reading on loopback, and local-only metrics never reaching the peer.
- **Native media suite:** the newest refused frame is encoded once a slot frees. A frame refused by a busy connection starts within a few milliseconds of it clearing, with its own capture time. Only the newest of five is kept, and an older frame never replaces it. The wait is measured once and in milliseconds, however many retries it takes.
- **Session suite:** the limit's window.
- **Between two Macs:** pacing under a real Wi-Fi slowdown is observed in telemetry and the session log.

## Versions, remote updates and Settings

For `v0.3.0-preview.19`, each Mac tells the other its Mooring version, and a viewer can ask an older sharing Mac to update itself.

- **Version messages.** Rust adds three control messages, each sent only to a peer that announced the matching capability, so an older Mac never receives an ID it would reject:
  - Version: either way, once per session;
  - UpdateRequest: viewer to a sharing Mac that updates itself, at most once a minute;
  - UpdateStatus: sharing Mac to viewer.
- **Release numbers.** Releases pack as 16-bit major, minor, patch and preview, with a final release after its previews. Builds without an update feed report as development builds and are never ordered.
- **Updating.** A sharing Mac's check runs through Sparkle, with the same signed feed and verification. The update still installs only when no session is connected. **Disconnect and Update** ends the viewer's session and reconnects on Rust's update schedule, every 3 s for 2 minutes.
- **Checks.** The Rust suite covers the message formats and their field rules, strict release parsing and ordering, the direction, once-only, capability and spacing rules, loopback delivery, and refusal toward protocol 4 peers. The session suite covers the Swift mapping, version ordering, and a build without a feed reporting as a development build.
- **Settings window.** Rendered off-screen in light and dark appearance to check its layout. Its toggles call the same setters as before, so a running session follows them.
- **Telemetry.** Latency values are now removed rather than repeated when no frame reached the screen in a second.
- **Review fixes.** A code review of the first version found two problems, fixed before release:
  - a sharing Mac that shared manually would never install, so **Disconnect and Update** reconnected to the old version in a loop. It now installs when the viewer that was told of the update disconnects, stops taking connections just before, and shares again after the relaunch;
  - the Settings window didn't refresh after Accessibility or login approval in System Settings. It now refreshes whenever it comes forward.

  Also from the review:
  - a check that never answers lets the viewer ask again after 90 s;
  - a ready update's build is never 0;
  - `build-app.sh` accepts only the release grammar Rust packs;
  - ⌘, opens Settings while another window is busy.
- **Update test.** `scripts/test-update-local.sh` passed after these updater changes: the in-place update relaunched in 2 s, and a tampered archive and an altered feed were refused.

Between two Macs, the update request needs preview 19 or later on both, and is first useful when preview 20 is published.

## Per-Mac pairing keys

For `v0.3.0-preview.20`, each viewing Mac has its own Noise static key, and the sharing Mac approves keys rather than sharing one secret.

- **Handshakes.** A 16-byte plain-text mode record precedes the first Noise message. The mode is also bound into the prologue (`Mooring direct session v2` plus the mode byte):
  - pair: `Noise_IKpsk1_25519_ChaChaPoly_BLAKE2s` with a one-time secret;
  - device: `Noise_IK_25519_ChaChaPoly_BLAKE2s` with an approved key;
  - migrate: IKpsk1 with the old long-lived secret, while the sharing Mac still accepts it.

  Anything else is read as the old `Noise_NKpsk0` first message. A sharing Mac from before this version reads the mode record that way, fails, and closes; the viewer then uses the old handshake with the old code.
- **Refusal.** An unknown key, or a wrong, used, replaced or expired code, is refused on the first message, before the sharing Mac sends anything. The viewer reports such a close as an authentication failure, which stops reconnecting.
- **Approval.** The sharing Mac records an approval or uses up a code only after the viewer's key confirmation, and before its own. A viewer that finished the handshake was approved, and an unfinished one approves no one.
- **One-time codes.** Held only in the listener's memory, zeroized. They work for 10 minutes, once; a newer code replaces an unused one. The code text is `MLP2.` and is never saved: the viewer saves a device pairing with the sharing Mac's public key and no secret.
- **The old code.** It is accepted only on a sharing Mac whose identity existed before this version. It closes a week after the first Mac moves over, or at once with **Stop Now**, which also ends a session using it. A new identity, or **Reset Pairing**, never accepts it. Reset clears the approved list before making the new identity.
- **The list.** `native-devices.json` holds IDs (SHA-256 of the public key), public keys, names and times, at most 32 entries. It follows the peer list's rules: owner-only, bounded, strict, atomic, locked, never overwritten when unreadable. An unreadable list refuses every per-device and old-code connection.
- **Local checks.**
  - The Rust suite runs the full matrix over loopback:
    - an old viewer while the old code is accepted, then after it stops;
    - moving over once, then connecting as a device;
    - falling back to a sharing Mac without a list;
    - one-time codes that are used, replaced, guessed or expired;
    - a copied device pairing on another key;
    - removal and reset;
    - a mode changed in transit between pair and migrate, and an unknown mode.

    Three mutations were each caught:
    - a prologue without the mode;
    - codes that never expire;
    - falling back after the host answered.
  - The Swift session suite pairs, reconnects and is refused after removal over loopback, with a temporary list.
- **Security review.** A focused review found nothing critical or high. Fixed before release:
  - A Migrate that failed after the sharing Mac answered fell back to the old handshake, so a reset in the network path could discard an approval already recorded. It now falls back only when the host never answered. A session whose connection drops after the last answer is returned closed, so the viewer saves what was approved. The test fills the old code's approvals so the host refuses after answering; allowing the fallback fails it.
  - A session committed in Rust but not yet started in the app survived **Remove** and **Stop Now**. The app now re-checks the list before each session starts. `approve` refuses a move-over, under the lock, once the old code has stopped.
  - A lost list reopened the old code for an existing identity. The Keychain identity now notes that it keeps a list, so a lost list starts closed.
  - The old code could approve all 32 slots. It now approves at most 8.
  - **Another Week** could revive an expired old code; it now requires the code to still be open. Settings reports raw acceptance and the end date, so it can say when the code stopped.
  - A failed last-seen write refused an approved Mac. Removal is now checked by a read, and the write is bookkeeping.
  - Two FFI calls now clear their outputs before anything can fail.
- **Known limit.** The viewer can't tell a refusal from a close injected in the network path before the first answer. Either one stops automatic reconnecting, with a message to pair again; **Reconnect** tries again. Nothing is deleted.
- **Between two Macs.** Moving over, removal ending a live session, and pairing with a one-time code are checked by hand (TESTING.md step 9).

## Pointer image

From preview 10 to preview 20, the sharing Mac sent its pointer drawn at half size in the bottom-left of its image. The drawing context was made before the bitmap was given its size in points, so it drew at one point per pixel. The hotspot was sent correctly, so on the viewing Mac a click landed well above the visible pointer: about 18 points above the arrow's tip on this Mac Studio. Its display and click mapping were exact (1680×1016 points at 2x, streamed at 3360×2032).

For `v0.3.0-preview.21`, the size is set first and the image is anchored at its top left, where the hotspot is measured from. A session test draws a 2-point square 3 points in and 5 points down, including in a fractional-point image. It checks the square's pixels as sent and after the viewer rebuilds the pointer. With the old order, the test fails.

## Remote menu bar in full screen

For `v0.3.0-preview.21`, a controlling viewer enters full screen with this Mac's menu bar and Dock hidden, so the top edge reaches the sharing Mac's menu bar. An in-process check without a visible window showed that the viewer window does not handle ⌃⌘F itself. Before this release, the chord fell through to the remote view and went to the sharing Mac. The new **View → Enter Full Screen** item takes it. Whether the menu bar and title bar stay hidden at the top edge is checked on the two Macs; the local suite does not enter full screen.

## Waiting for a dropped viewer

For `v0.3.0-preview.22`, a sharing Mac tells a session the viewer ended apart from one that dropped.

- **Protocol.** Rust adds `Leaving`, control kind 12:
  - viewer to host only, all fields zero;
  - sent only to a host that announced `ML_CAPABILITY_WAITS` (bit 8);
  - a protocol violation for a host without it, or in protocol 4.

  The wait's bound, 12 hours, is Rust's `ML_VIEWER_WAIT_SECONDS`.
- **Ordering.** The host notes the message on its reader thread. A queued main-thread update would be skipped, because the viewer closes the connection right after. The viewer writes it behind anything already queued, then closes. The Swift loopback test checks that the host reads a ping, then `Leaving`, then the close. Sending the goodbye after closing fails it.
- **Host.**
  - After an end without `Leaving`, the host keeps the session's display and sleep assertion, and keeps its listener, for up to 12 hours or until the next session, **Stop Sharing**, or a lock.
  - Remove and Stop Now never wait.
  - Only a viewer closing its window or quitting Mooring says it's leaving; sleep, lock, dropped connections and the update hand-off don't.
- **Viewer.** A session ended by this Mac's sleep or lock is reconnected by the one-second tick, once this Mac is awake and unlocked, with a fresh budget. Notifications still only stop sessions; nothing starts from one.
- **Not verified.** Whether the display assertion also keeps a screen saver from starting and locking is untested. The overnight lid-close check (TESTING.md step 11) is the gate.

## Every address of the sharing Mac

For `v0.3.0-preview.23`, a pairing code lists the sharing Mac's addresses, and the viewer tries them together.

- **Format.**
  - One-time codes (`MLP2.`, version 2) gain an optional `addresses` list. It holds up to seven, each valid by the host rule, none repeated or equal to the main address. Their joined length is at most 1023, so a code is at most 2005 characters.
  - Old codes and Keychain credentials never carry the list, and a version 1 or 3 object that has one is refused. A preview 22 viewer refuses a preview 23 code, because its parser rejects unknown fields.
- **Addresses.** Rust lists IPv4 addresses from `getifaddrs`: up and running, not loopback or link-local, `en*` first, then `utun*`. Virtual machine and Internet Sharing bridges are left out. This Mac Studio lists `192.168.25.201 100.122.9.8` after `thinkstudio.local`.
- **Connecting.**
  - One thread per address, at most eight, started 200 ms apart, resolves and connects, bounded by the overall deadline. The global resolver cap of four still applies.
  - Each connection that completes gets the handshake in turn. It has at most 2 s while other candidates are pending, and the remaining time for the last.
  - A connection that waited over 500 ms is reconnected first, because the sharing Mac gives an accepted connection about a second to begin.
  - Any close before the sharing Mac's answer is a refusal, including one surfacing on a write, or as macOS's invalid-argument error when setting an option on a reset socket.
  - The result is Auth only when every candidate that reached a host refused; otherwise the non-refusal error, so reconnecting continues. A sharing Mac that answered is never retried on another address, because it may have recorded an approval.
  - Moving over falls back to the old handshake on the first address that connected.
- **Saved peers.** `alternates` default to none, so earlier files load. After a saved peer connects, the address that worked moves to the front.
- **Logs.** The log names the address's position, never the address.
- **Known limit.** Another Mooring host at a stale address can refuse while the real one is unreachable. That reads as a refusal and stops reconnecting. **Reconnect** tries again.
- **Checks.** Loopback tests put the sharing Mac on 127.0.0.1 and a stand-in on ::1 at the same port. They cover a stand-in that never answers, one that closes at once, every address refusing, none answering, and the move-over fallback. Unit tests cover the format, size and strictness, the address ordering, and saved-peer ordering. Three mutations were each caught: no per-candidate time slice, a close ending the attempt, and no reconnect after waiting.

## Keyframes only when needed

For `v0.3.0-preview.24`, the sharing Mac sends keyframes on demand, and pacing ignores their drain.

- **Measured first.** In a session from away over Tailscale, at 3360×2032 HEVC 4:4:4, the old 2 s keyframes averaged about 48 KiB per frame over their second, about 1.2 MB for the keyframe itself. Each held the link for most of a second: waits up to 300 ms, 10–21 skipped frames a second, presented 25–42 fps. Pacing cut the bitrate from 18.75 to 4 Mbps in 90 s. Between keyframes the stream used about 1 Mbps.
- **Default.** Tuning's `keyframe_seconds` defaults to `ML_KEYFRAMES_ON_DEMAND` (255; 0 in local JSON). Keyframes come at the start, on a display change (a new encoder), after an encoder failure, and on the viewer's request, which it retries every 0.75 s while it waits. The transport is TCP and never drops an encoded frame, so nothing else needs one. 1–10 s still works when tuned.
- **Encoder.** VideoToolbox documents 0 as no limit, but Apple silicon's HEVC encoder then makes a keyframe every 32 frames. The new media test, on the hardware encoder, showed keyframes at frames 0, 32, 64, 96 and 128, plus the requested one. "On demand" is therefore an explicit one-hour limit. The test now checks that 3.5 s on demand gives only frame 0 and the requested frame, and that a 1 s interval gives four.
- **Pacing.** `ml_flow_next_bitrate` takes `after_keyframe`. A congested second during or right after a keyframe is left out: shifted into the four-second window as not congested, and not counted as clear. The host passes it only while keyframes are on demand, so a tuned 1–2 s interval can't hide a slow connection. Rust tests cover a keyframe's two slow seconds, two keyframes close together, left-out seconds not counting toward a raise, and congestion between keyframes still cutting.
- **Compatibility.** A viewer's `tune --keyframe-seconds 0` reaches an older host as 255, which it refuses as invalid tuning.
- **Between two Macs.** Not yet measured after the change: `keyframes`, `skipped_fps`, `queue_wait_ms` and `bitrate_mbps` from away.

## Pacing against the link's rate

For `v0.3.0-preview.25`, pacing cuts against what the link carries rather than against the encoder's target.

- **Measured first.**
  - From away on preview 24, during busy content, the target stayed at 25 Mbps while the encoder sent 7.8–9.7 Mbps.
  - About every 10–15 s, a burst overfilled the ~9.5 Mbps link, with waits of 140–250 ms and 6–14 skipped frames.
  - Pacing cut the target to 18.75 Mbps, which changed nothing the encoder did, and climbed back to 25 within 13 s.
- **Link meter.**
  - Rust's `LinkMeter` takes each send-buffer reading: bytes queued, and the kernel's total sent.
  - Time between two readings that both had 64 KiB or more queued counts, since the kernel is then sending as fast as the connection allows.
  - The rate over at least 40 ms of such time each second is the link's rate. A counter that goes backwards is ignored.
  - A run of 50 ms or more with nothing sent is a stall, as when Wi-Fi pauses and no acknowledgments arrive, and doesn't count. Shorter gaps, as between packets on a slow link, do.
  - The host samples at every frame admission and at every few-millisecond retry while a frame waits.
- **Rule.**
  - The link's rate is taken as no less than the recent peak of what was sent. That peak decays an eighth each clear second, not in congested ones, so a trickle after a stall can't pass for the link.
  - A cut is `min(¾ × target, ¾ × link)`, and that rate is remembered.
  - Raises stop at nine tenths of it.
  - Each 30 clear seconds the remembered rate rises a tenth. A higher measured rate replaces it, and one whose nine tenths reaches the ceiling is forgotten.
  - Without a measurement, the earlier rule applies unchanged.
  - `MLFlowState` grows to 20 bytes, and `MLLinkMeter` is 48, asserted on both sides.
- **Telemetry.** `link_mbps` (metric 21) is local only, like the other pacing figures. It is present only in seconds with a measurement.
- **Checks.**
  - Rust tests cover the cut, the stop, the probe, a faster link, forgetting, keyframe seconds and the meter's rules.
  - A home stall: 15 Mbps sent cleanly, then two congested seconds measuring 2 Mbps. That cuts to 11.25 Mbps and remembers 15, where a naive meter would remember 2 and drop to the floor. Removing the peak floor or the stall rule fails these tests.
  - The Swift check feeds real readings 100 ms apart through `NativeFlowLimit` to confirm units.
- **Trade-off at home.** After a genuine slowdown, recovery to the ceiling is probe-paced (a tenth per 30 clear seconds), so it takes minutes rather than the earlier 13 s.
- **Between two Macs.** Not yet measured after the change: `link_mbps` and `bitrate_mbps` from away with busy content.

## A send-buffer limit for slow links

For `v0.3.0-preview.26`, the host's send-buffer limit fits a slow link across the internet.

- **Measured first.**
  - From away on preview 25, with a busy screen at 9–10 Mbps, the kernel's smoothed round trip for the connection stayed at 20–48 ms (median 28), read with `nettop` once a second for a minute. That includes the one stall.
  - The viewer's ping, which queues behind video in the host's send buffer, read up to 116 ms.
  - So pacing on the network's round trip would not have detected these stalls, and was not built. The queue was the host's own.
  - `send_queue_kib` stayed at 78–157 KiB. About 33 KiB of that was in flight (10 Mbit/s × 28 ms), leaving 45–125 KiB waiting.
- **Rule.**
  - With a minimum round trip of 10 ms or more and something sent, the limit is `max(48 KiB, 1.5 × in flight + 20 ms × rate)`, never above the earlier `max(128 KiB, 1.5 × in flight)`.
  - The rate is the most sent in any of the last ten seconds.
  - Under 10 ms, or before anything is sent, the earlier rule applies unchanged.
- **Checks.** Rust: 77.5 kB at 10 Mbit/s and 28 ms; the 48 KiB floor; 128 KiB at 3 and 9 ms; and never above the earlier rule. Swift: `NativeFlowLimit` keeps the busiest recent second.
- **Expected effect.** In ordinary seconds the queue should sit around 60–95 KiB, against 80–130, which is about 10–20 ms less. During bursts, where it had reached 150+, it's up to about 50 ms less. A relayed connection over 10 ms counts as across the internet.
- **Withdrawn in preview 27.** Measured from away right after both Macs updated, over a minute:
  - `sent_mbps` fell from a median of 9.3 to 4.2;
  - the bitrate target sat at the 4 Mbps floor;
  - 25 seconds had waits of 100 ms or more, against one before, and 333 frames were skipped;
  - the pacing log showed frames waiting 170–500 ms with only 55–85 KiB queued.

  Pacing counts the time the admission limit holds a frame as congestion. A smaller limit held frames on an uncongested link, the cuts lowered the sent rate, and that lowered the limit further. Preview 27 restores preview 25's `flow.rs`, header text, `NativeFlowLimit` and its test exactly.
- **Lesson.** A change to the admission limit must be tested together with the bitrate rule. The tests checked the limit's value and that it couldn't starve the link at a steady rate, but not the loop through pacing.

## The wait survives a relaunch, and "not sharing" is reported

For `v0.3.0-preview.28`.

- **Found.** The Mac Studio's log showed a wait start at 21:47 after an unexpected drop. Sparkle installed preview 27 at 01:10 with no session connected, which relaunched Mooring. The wait was held only in memory, so the display turned off and the screen locked at 01:15, and sharing stopped until Screen Sharing unlocked it at 08:08.
- **Persistence.**
  - The wait's end is saved in defaults (`native.waitForViewerUntil`) when it starts.
  - `stopSharing` clears it unless `keepWait`. Only the update preparation passes that, and the quit after it.
  - On launch, if sharing will restart by itself and the session isn't locked, the display assertion is taken back at once and the wait resumes from the saved end. Starting sharing resumes it too.
  - If the display is already asleep, `IOPMAssertionDeclareUserActivity` (public IOKit) wakes it, since an assertion alone doesn't wake a dark display.
  - A viewer reconnecting, Stop Sharing, the privacy guard, a user's quit, or the wait's own expiry clear it.
  - This was traced against the log, not run on the live host. It's first exercised when an update after preview 28 installs during a wait.
  - Last night's wait ran 3 h 23 min without the 3-hour screen saver locking the Mac Studio: one data point that the display assertion also holds off the screen saver.
- **Error.** `ConnectionRefused` now maps to the new `ML_SESSION_UNAVAILABLE` (−13): the other Mac answered, but Mooring isn't sharing there. In a multi-address connect it's kept over a later timeout from other addresses. The viewer shows it with the likely cause and keeps reconnecting. The Rust tests cover two closed addresses, and a closed one next to an unroutable one within the deadline.
- **Toolchain.** Rust 1.99 deprecates `AtomicU64::fetch_update` and `AtomicUsize::fetch_update` in favor of `try_update`, and the two uses were renamed.

## Waking for a returning viewer

For `v0.3.0-preview.29`, which replaces the 12-hour wait of previews 22 to 28.

- **Found (2026-10-02).**
  - On the Mac Studio, the "lock" after display sleep is loginwindow's shield (`kLWLockFromDisplayDim`). It sets `CGSSessionScreenIsLocked`, but needs no password there: `sysadminctl -screenLock status` reports off.
  - At 16:57:55, Screen Sharing declared user activity ("Remote user active"). loginwindow logged "Keybag was NOT locked" and lowered the shield 52 ms later, and Mooring resumed a second after that.
  - The waits that day had been ended at 09:54 and 17:01 by the viewer's `Leaving`.
- **Measured, with the user's consent.**
  - `pmset displaysleepnow` raised the shield. A separate process's `IOPMAssertionDeclareUserActivity(kIOPMUserActiveRemote)` lowered it in 192 ms, with no password.
  - 3.3 s later, Codex Computer Use's lock-screen guardian on that Mac locked the screen properly (`kAELockScreenEvent`). It does that for an unlock it didn't see a person cause. Screen Sharing's wakes hadn't triggered it.
  - The user turned that feature off. Mooring does not try to look like a person to such tools.
- **Host.**
  - **Listening.** With automatic sharing, display sleep or a shield no longer stops sharing. A live session still ends at once, since a covered screen is never captured, but the listener stays open. `NativePrivacyGuard.mayListenNow` needs the user's session on the console and logged in, whatever the lock flag says. Pure checks cover it.
  - **Waking.** An approved connection while the display sleeps or the screen is covered declares user activity; Rust has already authenticated it before Swift sees it. The host then checks every 100 ms, for up to `ML_HOST_WAKE_WAIT_MS` (5 s), until the session may share and the display is awake.
    - The transport stays unread meanwhile, and the viewer's pings queue within `IDLE_LIMIT` (10 s). A Rust test keeps the wait at most half of it.
    - Removal during the wait is checked again before the session starts.
  - **A password.** A screen still asking for its password stops sharing. Later attempts are refused (`ML_SESSION_UNAVAILABLE`), so the display isn't woken again, and automatic sharing restarts only after an unlock: one wake per lock.
  - **Starting.** Automatic sharing starts listening while the screen is covered, as after an update relaunched Mooring with the display off. Manual sharing still stops on a lock or display sleep.
  - **The old wait.** Hosts no longer announce `ML_CAPABILITY_WAITS`, so viewers don't send them `Leaving`. Launch removes preview 28's saved wait (`native.waitForViewerUntil`). Viewers still send `Leaving` to previews 22–28.
- **Viewer.** `ML_SESSION_UNAVAILABLE` switches reconnecting to the update schedule, every 3 s for two minutes, so an unlock is noticed within seconds.
- **Cost.**
  - A sharing Mac that asks for a password after its display sleeps stayed connectable through the 12-hour wait. Now it needs unlocking, with Screen Sharing for example, and Mooring says so.
  - After a session drops, the display now turns off on its usual schedule.
- **Not verified.** The wake was tested from a stand-alone process, not from Mooring, and not with a viewer connecting. Whether ScreenCaptureKit starts cleanly right after the wake is also untested. Both are checked in TESTING.md step 11.

## Lid/wake reconnect recovery (2026-10-04)

This revises preview 29's single-activity wake policy above.

- **Observed locally.** At 07:50:41, loginwindow began clearing its display-dim shield after remote user activity but did not complete. At 07:50:46, Mooring's five-second wake deadline expired; it described a password lock and stopped listening. The next remote user activity at 08:03:28 cleared the shield. loginwindow reported that the keybag was not locked and that no password was required; Mooring resumed sharing. This explains the dependence on a subsequent Screen Sharing/RDP connection, but is not a reproduction of the patched two-Mac path.
- **Change.** An authenticated connection makes at most three remote user activity requests, a second apart, within the existing five-second wait. The public IOKit boundary keeps the returned activity ID for renewal and holds the display through the wait, releasing both on completion or cancellation. The display hold has a five-second powerd timeout as well. Capture and input still require an eligible, uncovered console session; waking does not grant access to a locked screen.
- **Recovery.** A wake timeout no longer proves a password is required. A still-covered or unavailable session waits for an unlock. An eligible session whose display is asleep keeps listening, and an eligible session clears a prior timeout latch without requiring the display to be awake first. This lets an approved connection supply the wake request instead of depending on another remote-desktop app.
- **Local regression scope.** Rust tests exercise a shield that needs a second request, the three-request budget, the five-second deadline, missing console access, display/session readiness, and the C ABI's invalid state/flag handling. Swift tests use fake power APIs to check retained/replaced IDs, cleanup after API failures, cancellation cleanup, and the same Rust wake policy. They do not alter the live desktop's power state.
- **Validation result.** `./scripts/ci-local.sh` passed on the local Mac with 232 Rust tests, 247 native session checks, native media/streaming checks, and the arm64 macOS 14 app build. Validation used a separate source copy and did not replace or launch the installed app.
- **Release gate.** Repeat TESTING.md step 11 with two Macs, including overnight lid sleep and an actual password lock. Local tests and an arm64 build do not independently verify macOS's wake response, immediate ScreenCaptureKit recovery, or the user's exact lid cycle.

## Media feasibility

The capability probe and synthetic encode probe are separate developer tools. Their JSON findings and limitations are documented alongside them. They capture no desktop and transmit no frames. A normal hardware-required HEVC Main444 session produced an actual 4:4:4 synthetic bitstream on this Mac. This is a feasibility result, not proof of real-time 4K performance or a working remote-desktop engine.

## Not yet validated

Second-Mac installation, downloaded-app first launch, end-to-end remote login, Apple's actual response to both mode URLs (including opposite remembered modes), real Accessibility session matching/full screen/reconnect, login registration, travel/VPN transitions, live capture/network/decode, a native session between two Macs (pairing, permissions, input, lock/sleep handling and legibility), click-to-photon latency, sustained 4K60, audio/clipboard integration, and headless virtual displays. Apple provides remote authentication, negotiated display mode, and rendering.
