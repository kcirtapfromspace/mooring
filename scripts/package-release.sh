#!/bin/bash
set -euo pipefail

# This entire build, packaging and verification pipeline runs on the local Mac.
# It never publishes a release, starts hosted CI, or connects to a remote Mac.
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_version="${1:-0.1.0-preview.1}"
release_version="${release_version#v}"
if [[ $# -gt 1 || ! "$release_version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    printf '%s\n' 'Usage: scripts/package-release.sh [0.1.0-preview.1]' >&2
    exit 1
fi

release_bundle="$project_root/dist/release/Mooring.app"
MOORING_RELEASE_VERSION="$release_version" \
    MOORING_APP_OUTPUT="$release_bundle" "$project_root/scripts/build-app.sh"

archive_name="Mooring-v$release_version-macos-arm64.zip"
archive_path="$project_root/dist/$archive_name"
package_root="$(mktemp -d "$project_root/dist/.mooring-package.XXXXXX")"
trap 'rm -rf "$package_root"' EXIT
staged_archive="$package_root/$archive_name"

# Preserve the Mooring.app parent directory so Finder extraction is directly usable.
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$release_bundle" "$staged_archive"
/usr/bin/ditto -x -k "$staged_archive" "$package_root/verify"
extracted_bundle="$package_root/verify/Mooring.app"
codesign --verify --deep --strict "$extracted_bundle"
for executable in "$extracted_bundle/Contents/MacOS/Mooring" "$extracted_bundle/Contents/Resources/mooring"; do
    if [[ "$(lipo -archs "$executable")" != arm64 ]]; then
        printf 'Expected an Apple Silicon executable in the archive: %s\n' "$executable" >&2
        exit 1
    fi
done
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$extracted_bundle/Contents/Info.plist")"
packaged_version="$(/usr/libexec/PlistBuddy -c 'Print :MooringReleaseVersion' "$extracted_bundle/Contents/Info.plist")"
if [[ "$minimum_system" != 14.0 || "$packaged_version" != "$release_version" ]]; then
    printf '%s\n' 'Packaged version or minimum macOS version did not match the requested release.' >&2
    exit 1
fi

mv "$staged_archive" "$archive_path"
(
    cd "$project_root/dist"
    shasum -a 256 "$archive_name" > "$archive_name.sha256"
    shasum -a 256 -c "$archive_name.sha256"
)
printf '\nRelease archive: %s\n' "$archive_path"
printf 'SHA-256 file: %s.sha256\n' "$archive_path"
printf '%s\n' 'Requires Apple Silicon and macOS 14 or newer.'
printf '%s\n' 'Not notarized. Default signing is ad hoc; this is a developer preview.'
