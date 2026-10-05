#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' 'The Mooring app requires macOS and the Apple command line tools.' >&2
    exit 1
fi

for build_tool in cargo rustup swiftc xcrun lipo codesign plutil iconutil; do
    command -v "$build_tool" >/dev/null || {
        printf 'Missing build tool: %s. Install Rust and the Apple command line tools.\n' "$build_tool" >&2
        exit 1
    }
done

release_version="${MOORING_RELEASE_VERSION:-0.3.0}"
# The grammar the session library packs for the version message: numbers
# without leading zeros below 65536, and preview numbers from 1 to 65534.
invalid_release() { printf 'Invalid release version: %s (use 1.2.3 or 1.2.3-preview.N)\n' "$release_version" >&2; exit 1; }
[[ "$release_version" =~ ^(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})(-preview\.([1-9][0-9]{0,4}))?$ ]] || invalid_release
release_parts=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
release_preview="${BASH_REMATCH[5]}"
for part in "${release_parts[@]}"; do (( part <= 65535 )) || invalid_release; done
[[ -z "$release_preview" ]] || (( release_preview <= 65534 )) || invalid_release
short_version="${release_version%%-*}"
app_bundle="${MOORING_APP_OUTPUT:-$project_root/dist/Mooring.app}"
[[ "$app_bundle" = /* ]] || app_bundle="$project_root/$app_bundle"
if [[ "$app_bundle" != *.app || -L "$app_bundle" || ( -e "$app_bundle" && ! -d "$app_bundle" ) ]]; then
    printf 'App output must be a non-symlink .app directory: %s\n' "$app_bundle" >&2
    exit 1
fi

mkdir -p "$project_root/dist" "$(dirname "$app_bundle")"
build_root="$(mktemp -d "$project_root/dist/.mooring-build.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
staged_bundle="$build_root/Mooring.app"
mkdir -p "$staged_bundle/Contents/MacOS" "$staged_bundle/Contents/Resources" "$staged_bundle/Contents/Frameworks"
sdk_path="$(xcrun --show-sdk-path)"
# Render every standard icon size from the same geometry used by the shell.
swiftc -O -swift-version 5 -parse-as-library -sdk "$sdk_path" -target arm64-apple-macosx14.0 \
    -framework AppKit "$project_root/app/MooringBrand.swift" "$project_root/scripts/render-brand.swift" \
    -o "$build_root/render-brand"
"$build_root/render-brand" "$build_root/Mooring.iconset"
iconutil -c icns "$build_root/Mooring.iconset" -o "$staged_bundle/Contents/Resources/Mooring.icns"
installed_targets="$(rustup target list --installed)"
rust_target=aarch64-apple-darwin
if ! printf '%s\n' "$installed_targets" | /usr/bin/grep -Fqx "$rust_target"; then
    printf 'Missing Rust target. Install it with: rustup target add %s\n' "$rust_target" >&2
    exit 1
fi

# Mooring currently targets Apple Silicon only, with the same macOS floor in both binaries.
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release --package mooring-cli --package mooring-session \
    --target "$rust_target" --target-dir "$project_root/target"
# In-place updates: the pinned, checksum-verified Sparkle framework.
sparkle_dir="$("$project_root/scripts/fetch-sparkle.sh")"
# The one Objective-C file: the private virtual-display boundary (AGENTS.md).
clang -fobjc-arc -O2 -Wall -Werror -isysroot "$sdk_path" -target arm64-apple-macos14.0 \
    -c "$project_root/app/NativeVirtualDisplay.m" -o "$build_root/NativeVirtualDisplay.o"
swiftc -O -swift-version 5 -parse-as-library -sdk "$sdk_path" -target arm64-apple-macosx14.0 \
    -framework AppKit -framework Foundation -framework Network -framework ServiceManagement \
    -framework Security -framework SystemConfiguration -framework ScreenCaptureKit -framework VideoToolbox \
    -framework CoreMedia -framework CoreVideo -framework Metal -framework MetalKit -framework CoreImage \
    -framework AVFoundation -framework AudioToolbox \
    -import-objc-header "$project_root/app/Mooring-Bridging.h" "$build_root/NativeVirtualDisplay.o" \
    -L "$project_root/target/$rust_target/release" -lmooring_session \
    -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "$project_root"/app/*.swift -o "$staged_bundle/Contents/MacOS/Mooring"
cp "$project_root/target/$rust_target/release/mooring" "$staged_bundle/Contents/Resources/mooring"

# Embed Sparkle for Apple silicon only. Mooring is not sandboxed, so Sparkle's
# optional XPC services are unused; headers are build-time only.
sparkle="$staged_bundle/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto "$sparkle_dir/Sparkle.framework" "$sparkle"
for unused in XPCServices Headers PrivateHeaders Modules; do
    rm -rf "${sparkle:?}/Versions/B/$unused" "${sparkle:?}/$unused"
done
for binary in "$sparkle/Versions/B/Sparkle" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app/Contents/MacOS/Updater"; do
    lipo -thin arm64 "$binary" -output "$binary.arm64" && mv "$binary.arm64" "$binary"
done
cp "$sparkle_dir/LICENSE" "$staged_bundle/Contents/Resources/Sparkle-LICENSE.txt"

python3 "$project_root/scripts/collect-licenses.py" --check
cp "$project_root/docs/THIRD-PARTY-NOTICES.txt" "$staged_bundle/Contents/Resources/THIRD-PARTY-NOTICES.txt"
cp "$project_root/app/Info.plist" "$staged_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $short_version" "$staged_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MooringReleaseVersion $release_version" "$staged_bundle/Contents/Info.plist"
# Only release builds follow the public update feed; development builds never
# replace themselves. MOORING_UPDATE_FEED overrides it for a local update test.
signing_identity="${MOORING_CODESIGN_IDENTITY:--}"
update_feed="${MOORING_UPDATE_FEED:-}"
if [[ -z "$update_feed" && "$signing_identity" != "-" ]]; then
    update_feed="https://github.com/kcirtapfromspace/mooring-releases/releases/latest/download/appcast.xml"
fi
if [[ -n "$update_feed" && "$update_feed" != none ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $update_feed" "$staged_bundle/Contents/Info.plist"
fi
if [[ -n "${MOORING_BUNDLE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $MOORING_BUNDLE_VERSION" "$staged_bundle/Contents/Info.plist"
fi
if [[ -n "${MOORING_BUNDLE_IDENTIFIER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $MOORING_BUNDLE_IDENTIFIER" "$staged_bundle/Contents/Info.plist"
fi
chmod +x "$staged_bundle/Contents/MacOS/Mooring" "$staged_bundle/Contents/Resources/mooring"
plutil -lint "$staged_bundle/Contents/Info.plist"

# No identity discovery, credential lookup, or notarization occurs here.
# Explicitly configure an identity only when the signing setup is already in place.
sign_options=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
    sign_options+=(--options runtime --timestamp)
fi
# Inside out: Sparkle's helpers, then the framework, the CLI and the app.
codesign "${sign_options[@]}" "$sparkle/Versions/B/Autoupdate"
codesign "${sign_options[@]}" "$sparkle/Versions/B/Updater.app"
codesign "${sign_options[@]}" "$sparkle"
codesign "${sign_options[@]}" "$staged_bundle/Contents/Resources/mooring"
codesign "${sign_options[@]}" "$staged_bundle"
codesign --verify --deep --strict "$staged_bundle"
for executable in "$staged_bundle/Contents/MacOS/Mooring" "$staged_bundle/Contents/Resources/mooring" \
    "$sparkle/Versions/B/Sparkle" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app/Contents/MacOS/Updater"; do
    if [[ "$(lipo -archs "$executable")" != arm64 ]]; then
        printf 'Expected an Apple Silicon executable: %s\n' "$executable" >&2
        exit 1
    fi
done

# Publish a complete, verified bundle, so failed builds preserve the previous one.
if [[ -e "$app_bundle" ]]; then
    mv "$app_bundle" "$build_root/previous.app"
fi
if ! mv "$staged_bundle" "$app_bundle"; then
    [[ ! -e "$build_root/previous.app" ]] || mv "$build_root/previous.app" "$app_bundle"
    exit 1
fi

printf 'Built %s (arm64)\n' "$app_bundle"
if [[ "$signing_identity" = "-" ]]; then
    printf '%s\n' 'Signing: ad hoc. This build is not notarized.'
else
    printf '%s\n' 'Signing: configured identity. This script does not notarize the build.'
fi
printf 'Run: open "%s"\n' "$app_bundle"
