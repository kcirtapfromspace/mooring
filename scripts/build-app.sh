#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' 'The MacLink app requires macOS and the Apple command line tools.' >&2
    exit 1
fi

for build_tool in cargo rustup swiftc xcrun lipo codesign plutil; do
    command -v "$build_tool" >/dev/null || {
        printf 'Missing build tool: %s. Install Rust and the Apple command line tools.\n' "$build_tool" >&2
        exit 1
    }
done

release_version="${MACLINK_RELEASE_VERSION:-0.1.0}"
if [[ ! "$release_version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    printf 'Invalid release version: %s\n' "$release_version" >&2
    exit 1
fi
short_version="${release_version%%-*}"
app_bundle="${MACLINK_APP_OUTPUT:-$project_root/dist/MacLink.app}"
[[ "$app_bundle" = /* ]] || app_bundle="$project_root/$app_bundle"
if [[ "$app_bundle" != *.app || -L "$app_bundle" || ( -e "$app_bundle" && ! -d "$app_bundle" ) ]]; then
    printf 'App output must be a non-symlink .app directory: %s\n' "$app_bundle" >&2
    exit 1
fi

mkdir -p "$project_root/dist" "$(dirname "$app_bundle")"
build_root="$(mktemp -d "$project_root/dist/.maclink-build.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
staged_bundle="$build_root/MacLink.app"
mkdir -p "$staged_bundle/Contents/MacOS" "$staged_bundle/Contents/Resources"
sdk_path="$(xcrun --show-sdk-path)"
installed_targets="$(rustup target list --installed)"
rust_target=aarch64-apple-darwin
if ! printf '%s\n' "$installed_targets" | /usr/bin/grep -Fqx "$rust_target"; then
    printf 'Missing Rust target. Install it with: rustup target add %s\n' "$rust_target" >&2
    exit 1
fi

# MacLink currently targets Apple Silicon only, with the same macOS floor in both binaries.
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release --package maclink-cli \
    --target "$rust_target" --target-dir "$project_root/target"
swiftc -O -swift-version 5 -sdk "$sdk_path" -target arm64-apple-macosx14.0 \
    -framework AppKit -framework Foundation \
    "$project_root/app/MacLink.swift" -o "$staged_bundle/Contents/MacOS/MacLink"
cp "$project_root/target/$rust_target/release/maclink" "$staged_bundle/Contents/Resources/maclink"

cp "$project_root/app/Info.plist" "$staged_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $short_version" "$staged_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacLinkReleaseVersion $release_version" "$staged_bundle/Contents/Info.plist"
chmod +x "$staged_bundle/Contents/MacOS/MacLink" "$staged_bundle/Contents/Resources/maclink"
plutil -lint "$staged_bundle/Contents/Info.plist"

# No identity discovery, credential lookup, or notarization occurs here.
# Explicitly configure an identity only when the signing setup is already in place.
signing_identity="${MACLINK_CODESIGN_IDENTITY:--}"
sign_options=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
    sign_options+=(--options runtime --timestamp)
fi
codesign "${sign_options[@]}" "$staged_bundle/Contents/Resources/maclink"
codesign "${sign_options[@]}" "$staged_bundle"
codesign --verify --deep --strict "$staged_bundle"
for executable in "$staged_bundle/Contents/MacOS/MacLink" "$staged_bundle/Contents/Resources/maclink"; do
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
