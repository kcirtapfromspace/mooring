#!/bin/bash
# Manual: changes this Mac's display arrangement for about ten seconds.
# Never run it while a Mooring session is connected.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p target
sdk="$(xcrun --show-sdk-path)"
clang -fobjc-arc -O2 -Wall -Werror -isysroot "$sdk" -target arm64-apple-macos14.0 -c app/NativeVirtualDisplay.m -o target/NativeVirtualDisplay.o
swiftc -O -swift-version 5 -warnings-as-errors -parse-as-library -target arm64-apple-macosx14.0 -framework AppKit \
  -import-objc-header app/NativeVirtualDisplay.h target/NativeVirtualDisplay.o \
  app/NativeDisplayTopology.swift app/NativeSharedDisplay.swift scripts/test-virtual-display.swift -o target/mooring-virtual-display-check
target/mooring-virtual-display-check
