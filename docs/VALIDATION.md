# Preview validation

Validated locally on an Apple M1 Ultra running macOS 26.6.2. Rust 1.98.1 and the installed Xcode toolchain were used. No GitHub runner or remote CI was used.

## Automated checks

- Workspace formatting and Clippy with warnings denied.
- 58 Rust tests: eight CLI/storage tests, 37 network/quality/mailbox/reconnect tests, and 13 platform tests.
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

## Media feasibility

The capability probe and synthetic encode probe are separate developer tools. Their JSON findings and limitations are documented alongside them. They capture no desktop and transmit no frames. A normal hardware-required HEVC Main444 session produced an actual 4:4:4 synthetic bitstream on this Mac. This is a feasibility result, not proof of real-time 4K performance or a working remote-desktop engine.

## Not yet validated

Second-Mac installation, downloaded-app first launch, end-to-end remote login, Apple's actual response to both mode URLs (including opposite remembered modes), real Accessibility session matching/full screen/reconnect, login registration, travel/VPN transitions, live capture/network/decode, click-to-photon latency, sustained 4K60, audio/clipboard integration, and headless virtual displays. Apple provides remote authentication, negotiated display mode, and rendering.
