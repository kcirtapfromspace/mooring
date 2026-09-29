# Preview validation

Validated locally on an Apple M1 Ultra running macOS 26.6.2. Rust 1.98.1 and the installed Xcode toolchain were used. No GitHub runner or remote CI was used.

## Automated checks

- Workspace formatting and Clippy with warnings denied.
- 67 Rust tests: eight CLI/storage tests, 41 network/quality/mailbox/reconnect tests, and 18 platform tests.
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

## Media feasibility

The capability probe and synthetic encode probe are separate developer tools. Their JSON findings and limitations are documented alongside them. They capture no desktop and transmit no frames. A normal hardware-required HEVC Main444 session produced an actual 4:4:4 synthetic bitstream on this Mac. This is a feasibility result, not proof of real-time 4K performance or a working remote-desktop engine.

## Not yet validated

Second-Mac installation, downloaded-app first launch, end-to-end remote login, Apple's actual response to both mode URLs (including opposite remembered modes), real Accessibility session matching/full screen/reconnect, login registration, travel/VPN transitions, live capture/network/decode, click-to-photon latency, sustained 4K60, audio/clipboard integration, and headless virtual displays. Apple provides remote authentication, negotiated display mode, and rendering.
