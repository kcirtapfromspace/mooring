#!/bin/bash
# Publishes a notarized release to the public update feed that installed copies
# of MacLink follow (default kcirtapfromspace/maclink-releases):
#   scripts/publish-update.sh VERSION
# Run after notarize-release.sh. Only a stapled, Gatekeeper-accepted build
# signed by the MacLink Developer ID team, whose own feed URL is this feed, is
# published. The archive and the feed are EdDSA-signed with the Sparkle key in
# this Mac's Keychain. No GitHub Actions are involved.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
version="${1:-}"; version="${version#v}"
if [[ $# != 1 || ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    printf '%s\n' 'Usage: scripts/publish-update.sh VERSION' >&2
    exit 1
fi
repo="${MACLINK_UPDATE_REPO:-kcirtapfromspace/maclink-releases}"
team=67C7724279
name="MacLink-v$version-macos-arm64.zip"
archive="$project_root/dist/$name"
notes="$project_root/docs/release-notes-v$version.md"
feed="https://github.com/$repo/releases/latest/download/appcast.xml"
[[ -f "$archive" && -f "$notes" ]] || { printf 'Need %s and %s.\n' "$archive" "$notes" >&2; exit 1; }

state="$project_root/dist/update-feed/v$version"
mkdir -p "$state"
check="$(mktemp -d "$state/.check.XXXXXX")"
trap 'rm -rf "$check"' EXIT
/usr/bin/ditto -x -k "$archive" "$check"
app="$check/MacLink.app"
xcrun stapler validate -q "$app"
spctl --assess --type execute "$app"
codesign --verify --deep --strict "$app"
codesign -dv --verbose=2 "$app" 2> "$check/signature.txt"
/usr/bin/grep -q "^TeamIdentifier=$team$" "$check/signature.txt" \
    || { printf 'The archive is not signed by team %s.\n' "$team" >&2; exit 1; }
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist"; }
[[ "$(value MacLinkReleaseVersion)" = "$version" ]] || { printf '%s\n' 'The archive is a different release.' >&2; exit 1; }
[[ "$(value SUFeedURL)" = "$feed" ]] || { printf 'The archive follows %s, not this feed.\n' "$(value SUFeedURL)" >&2; exit 1; }

./scripts/make-appcast.sh "$archive" "https://github.com/$repo/releases/download/v$version/$name" "$state"
cp "$archive" "$state/$name"
(cd "$state" && shasum -a 256 "$name" > SHA256SUMS.txt)
gh release create "v$version" --repo "$repo" --title "MacLink $version" --notes-file "$notes" --latest \
    "$state/$name" "$state/appcast.xml" "$state/SHA256SUMS.txt"

# Confirm what installed copies will read.
served="$(curl -fsSL "$feed")"
/usr/bin/grep -q "<sparkle:version>$(value CFBundleVersion)</sparkle:version>" <<<"$served" \
    || { printf '%s\n' 'The public feed does not serve this build yet.' >&2; exit 1; }
printf 'Published MacLink %s to %s; installed copies update within about four hours.\n' "$version" "$feed"
