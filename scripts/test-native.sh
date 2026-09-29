#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p target
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx14.0 -framework AppKit -framework ApplicationServices \
  app/AppleSession.swift scripts/test-apple-session.swift \
  -o target/maclink-apple-session-tests
target/maclink-apple-session-tests
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx14.0 app/HomeNetworkCheck.swift scripts/test-home-network.swift \
  -o target/maclink-home-network-tests
target/maclink-home-network-tests
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx14.0 -framework AppKit \
  app/NativePrivacyGuard.swift scripts/test-native-privacy.swift \
  -o target/maclink-native-privacy-tests
target/maclink-native-privacy-tests

# Native session code validates through the arm64 Rust static library. These
# checks use synthetic pixels, in-process events and loopback only.
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release -p maclink-session -p maclink-cli --target aarch64-apple-darwin
bridge=(-import-objc-header crates/maclink-session/include/maclink_session.h -L target/aarch64-apple-darwin/release -lmaclink_session)
media_frameworks=(-framework AppKit -framework Security -framework ScreenCaptureKit -framework VideoToolbox
  -framework CoreMedia -framework CoreVideo -framework Metal -framework MetalKit -framework CoreImage -framework CoreText)
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx14.0 -framework AppKit -framework ApplicationServices "${bridge[@]}" \
  app/NativeInput.swift scripts/test-native-input.swift \
  -o target/maclink-native-input-tests
target/maclink-native-input-tests
swiftc -O -swift-version 5 -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 \
  "${media_frameworks[@]}" "${bridge[@]}" app/NativeMedia.swift app/NativePrivacyGuard.swift scripts/test-native-media.swift \
  -o target/maclink-native-media-tests
target/maclink-native-media-tests > target/native-media-report.json
printf '%s\n' 'Native media tests passed: hardware codec, Rust packet rules, recovery and bounds. Report: target/native-media-report.json'
swiftc -swift-version 5 -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 \
  "${media_frameworks[@]}" "${bridge[@]}" \
  app/NativePairing.swift app/NativeTransport.swift app/NativeSessionState.swift app/NativeMedia.swift \
  app/NativePrivacyGuard.swift app/NativeInput.swift \
  scripts/test-native-session.swift -o target/maclink-native-session-tests
# The session check drives the real CLI against the app's local telemetry socket.
target/maclink-native-session-tests target/aarch64-apple-darwin/release/maclink
./scripts/test-native-stream.sh
