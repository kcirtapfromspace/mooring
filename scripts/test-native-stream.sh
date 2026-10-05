#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release -p mooring-session --target aarch64-apple-darwin
media_frameworks=(-framework AppKit -framework ScreenCaptureKit -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework MetalKit -framework CoreImage -framework CoreText -framework Security -framework AVFoundation -framework AudioToolbox)
bridge=(-import-objc-header crates/mooring-session/include/mooring_session.h -L target/aarch64-apple-darwin/release -lmooring_session)
swiftc -O -swift-version 5 -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 \
  "${media_frameworks[@]}" "${bridge[@]}" \
  app/NativeInput.swift app/NativePrivacyGuard.swift app/NativeMedia.swift app/NativeAudio.swift app/NativePairing.swift app/NativeTransport.swift app/NativeSessionState.swift app/NativeClipboard.swift app/NativeCursor.swift \
  scripts/test-native-stream.swift -o target/mooring-native-stream-tests
python3 - <<'PY'
import subprocess
subprocess.run(['target/mooring-native-stream-tests'],check=True,timeout=45)
PY
