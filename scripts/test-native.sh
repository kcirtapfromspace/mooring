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
