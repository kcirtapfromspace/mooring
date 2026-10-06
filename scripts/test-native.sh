#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p target
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx14.0 -framework AppKit \
  app/MooringBrand.swift app/MooringPrivacy.swift app/MooringStatusMenu.swift scripts/test-status-menu.swift \
  -o target/mooring-status-menu-tests
target/mooring-status-menu-tests
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx14.0 -framework AppKit -framework ApplicationServices \
  app/AppleSession.swift scripts/test-apple-session.swift \
  -o target/mooring-apple-session-tests
target/mooring-apple-session-tests
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx14.0 app/HomeNetworkCheck.swift scripts/test-home-network.swift \
  -o target/mooring-home-network-tests
target/mooring-home-network-tests
swiftc -swift-version 5 -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 \
  -framework CoreGraphics -framework AppKit app/NativeDisplayTopology.swift app/NativeSharedDisplay.swift scripts/test-native-display.swift \
  -o target/mooring-native-display-topology-tests
target/mooring-native-display-topology-tests
clang -fobjc-arc -O2 -Wall -Werror -DML_VIRTUAL_DISPLAY_TESTING -target arm64-apple-macos14.0 \
  -framework Foundation -framework CoreGraphics app/NativeVirtualDisplay.m scripts/test-native-display.m \
  -o target/mooring-native-display-boundary-tests
target/mooring-native-display-boundary-tests
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx14.0 -framework AppKit \
  app/NativePrivacyGuard.swift scripts/test-native-privacy.swift \
  -o target/mooring-native-privacy-tests
target/mooring-native-privacy-tests

# Native session code validates through the arm64 Rust static library. These
# checks use synthetic pixels, in-process events and loopback only.
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release -p mooring-session -p mooring-cli --target aarch64-apple-darwin
bridge=(-import-objc-header crates/mooring-session/include/mooring_session.h -L target/aarch64-apple-darwin/release -lmooring_session)
media_frameworks=(-framework AppKit -framework Security -framework ScreenCaptureKit -framework VideoToolbox
  -framework CoreMedia -framework CoreVideo -framework Metal -framework MetalKit -framework CoreImage -framework CoreText
  -framework AVFoundation -framework AudioToolbox)
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx14.0 -framework AppKit -framework ApplicationServices "${bridge[@]}" \
  app/NativeInput.swift scripts/test-native-input.swift \
  -o target/mooring-native-input-tests
target/mooring-native-input-tests
swiftc -O -swift-version 5 -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 \
  "${media_frameworks[@]}" "${bridge[@]}" app/NativeMedia.swift app/NativeAudio.swift app/NativePrivacyGuard.swift scripts/test-native-media.swift \
  -o target/mooring-native-media-tests
target/mooring-native-media-tests > target/native-media-report.json
printf '%s\n' 'Native media tests passed: hardware codec, Rust packet rules, recovery and bounds. Report: target/native-media-report.json'
swiftc -swift-version 5 -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 \
  "${media_frameworks[@]}" "${bridge[@]}" \
  app/NativePairing.swift app/NativeTransport.swift app/NativeSessionState.swift app/NativeViewerDiagnostics.swift app/NativeViewerMeasurementStream.swift app/NativeWakeActivity.swift app/NativeMedia.swift app/NativeAudio.swift \
  app/NativePrivacyGuard.swift app/NativeInput.swift app/NativeClipboard.swift app/NativeCursor.swift \
  scripts/test-native-session.swift -o target/mooring-native-session-tests
# The session check drives the real CLI against the app's local telemetry socket.
target/mooring-native-session-tests target/aarch64-apple-darwin/release/mooring
./scripts/test-native-stream.sh
