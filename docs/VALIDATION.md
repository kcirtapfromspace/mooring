# Preview validation

Validated locally on an Apple M1 Ultra running macOS 26.6.2. Rust 1.98.1 and the installed Xcode toolchain were used. No GitHub runner or remote CI was used.

## Automated checks

- Workspace formatting and Clippy with warnings denied.
- 40 Rust tests: eight CLI/storage tests, 21 quality/mailbox/reconnect tests, and 11 platform tests.
- Storage tests exercise concurrent saves, corrupted/future schemas, private file permissions, oversized IDs, and malformed input.
- Local mock servers exercise valid/fragmented/truncated/malformed RFB greetings and aggregate timeouts without authenticating.
- Platform launch tests verify successful, failed, and hung helper-process handling.
- Adaptive-policy tests use synthetic telemetry. They do not measure live video latency or demonstrate automatic Apple mode switching.
- Native Swift compilation, bundle metadata lint, ad hoc code signature validation, and release archive checks.

## Preview 2 notarization

The complete local validation script passed again with all 40 tests. Both executables were signed with Developer ID, hardened runtime, and secure timestamps. Apple accepted submission `33b0a81d-3418-411e-9bc8-e3f072bfad76`; its log reports no issues. The final ZIP contains the stapled app. `stapler validate`, strict signature verification, and `spctl --assess --type execute` all passed after extracting that ZIP; Gatekeeper reported `source=Notarized Developer ID`. No Gatekeeper override was used.

## GUI check

Used a separate app identifier and isolated connection store. Verified empty state, Add Mac, the saved connection list, an RFB check against a localhost mock server, a clear refused-connection error after that server stopped, and readable/scrollable diagnostics. No real remote session was initiated by this QA flow.

## Media feasibility

The capability probe and synthetic encode probe are separate developer tools. Their JSON findings and limitations are documented alongside them. They capture no desktop and transmit no frames. A normal hardware-required HEVC Main444 session produced an actual 4:4:4 synthetic bitstream on this Mac. This is a feasibility result, not proof of real-time 4K performance or a working remote-desktop engine.

## Not yet validated

Second-Mac installation, downloaded-app first launch, end-to-end remote login, live capture/network/decode, click-to-photon latency, sustained 4K60, actual automatic quality switching, audio/clipboard integration, and headless virtual displays. Apple currently provides remote authentication, display mode, and rendering.
