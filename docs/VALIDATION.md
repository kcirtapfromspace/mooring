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

The encrypted hardware loopback now carries stats both ways and a tuning command to the host. The session suite drives the real `maclink telemetry` and `tune` commands against the app's socket.

Automatic sharing, ⌘-Tab capture through an event tap, reconnection in the same window, and capture restarts for a new width are AppKit and ScreenCaptureKit behavior, verified here only by compilation and by the Swift boundary checks. They need the two-Mac checks in the testing guide. The cause of the preview 2 disconnects is not yet known. This build logs every session end with MacLink's reason and reports it in telemetry.

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

macOS 15.4 and later may ask before MacLink reads the clipboard in the background; that prompt has not been exercised here.

A live preview 3 session between two Macs, watched from the sharing Mac, recorded one drop: `The other Mac sent an invalid or incomplete session message`. It came right after round-trip spikes of 104–136 ms, and the viewer reconnected in 0.8 s. The receive grace addresses that path. Whether it removes every drop still needs two-Mac confirmation.

## Clipboard echo fix

In a live preview 4 session between two Macs, a copied image bounced between them about once a second. Universal Clipboard carried each applied copy back to the other Mac, which sent it again. The viewing Mac's picture then stalled for seven seconds: it received about 57 fps, presented none, and its round-trip measurement stopped updating. The session ended and reconnected 0.8 s later.

For `v0.3.0-preview.5`, every pasteboard access moved to one serial background queue, with polls coalesced. The item last exchanged in either direction is never re-sent, and items marked `com.apple.is-remote-clipboard` are skipped. The complete local validation script passed with 153 Rust tests and every native Swift suite, including new private-pasteboard checks for each case.

## In-place updates

For `v0.3.0-preview.6`, the complete local validation script passed with 153 Rust tests and every native Swift suite. `scripts/test-update-local.sh` then ran over loopback only, using ad hoc builds under a separate bundle ID with a separate data folder and preferences:

- **Install:** an installed build 9000 read a signed local feed and fetched build 9001. It verified the EdDSA signatures, installed the new build in place and relaunched it within 3 s of launch. The relaunched copy passed strict code-signature verification.
- **Refusals:** an archive changed after signing was fetched and refused. A feed changed after signing was read, and no archive was fetched.

The embedded Sparkle 2.10.0 framework is pinned by SHA-256, thinned to arm64 and stripped of its unused XPC services and headers. Each nested component is signed before the app. An update between the two Macs from the public feed has not yet been observed; the first will be the release after preview 6.

## Media feasibility

The capability probe and synthetic encode probe are separate developer tools. Their JSON findings and limitations are documented alongside them. They capture no desktop and transmit no frames. A normal hardware-required HEVC Main444 session produced an actual 4:4:4 synthetic bitstream on this Mac. This is a feasibility result, not proof of real-time 4K performance or a working remote-desktop engine.

## Not yet validated

Second-Mac installation, downloaded-app first launch, end-to-end remote login, Apple's actual response to both mode URLs (including opposite remembered modes), real Accessibility session matching/full screen/reconnect, login registration, travel/VPN transitions, live capture/network/decode, a native session between two Macs (pairing, permissions, input, lock/sleep handling and legibility), click-to-photon latency, sustained 4K60, audio/clipboard integration, and headless virtual displays. Apple provides remote authentication, negotiated display mode, and rendering.
