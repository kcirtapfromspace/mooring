#!/bin/bash
# Publishes a notarized release to the public update feed that installed copies
# of Mooring follow (default kcirtapfromspace/mooring):
#   scripts/publish-update.sh VERSION
# Run after notarize-release.sh. Only a stapled, Gatekeeper-accepted build
# signed by the Mooring Developer ID team, whose own feed URL is this feed, is
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
repo="${MOORING_UPDATE_REPO:-kcirtapfromspace/mooring}"
team=67C7724279
name="Mooring-v$version-macos-arm64.zip"
archive="$project_root/dist/$name"
notes="$project_root/docs/release-notes-v$version.md"
feed="https://github.com/$repo/releases/latest/download/appcast.xml"
[[ -f "$archive" && -f "$notes" ]] || { printf 'Need %s and %s.\n' "$archive" "$notes" >&2; exit 1; }

state="$project_root/dist/update-feed/v$version"
mkdir -p "$state"
check="$(mktemp -d "$state/.check.XXXXXX")"
trap 'rm -rf "$check"' EXIT
/usr/bin/ditto -x -k "$archive" "$check"
app="$check/Mooring.app"
xcrun stapler validate -q "$app"
spctl --assess --type execute "$app"
codesign --verify --deep --strict "$app"
codesign -dv --verbose=2 "$app" 2> "$check/signature.txt"
/usr/bin/grep -q "^TeamIdentifier=$team$" "$check/signature.txt" \
    || { printf 'The archive is not signed by team %s.\n' "$team" >&2; exit 1; }
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist"; }
[[ "$(value MooringReleaseVersion)" = "$version" ]] || { printf '%s\n' 'The archive is a different release.' >&2; exit 1; }
[[ "$(value SUFeedURL)" = "$feed" ]] || { printf 'The archive follows %s, not this feed.\n' "$(value SUFeedURL)" >&2; exit 1; }
# Never move the feed back: this release becomes the latest, so an older build
# would reach new installs, and copies on the newer build would stop updating.
build="$(value CFBundleVersion)"
current="$(curl -fsSL "$feed" 2>/dev/null | sed -n 's:.*<sparkle\:version>\([0-9][0-9]*\)</sparkle\:version>.*:\1:p' | head -1 || true)"
if [[ -n "$current" ]] && (( current >= build )); then
    printf 'The feed already serves build %s; this archive is build %s.\n' "$current" "$build" >&2
    exit 1
fi

./scripts/make-appcast.sh "$archive" "https://github.com/$repo/releases/download/v$version/$name" "$state"
cp "$archive" "$state/$name"
(cd "$state" && shasum -a 256 "$name" > SHA256SUMS.txt)
gh release create "v$version" --repo "$repo" --title "Mooring $version" --notes-file "$notes" --latest \
    "$state/$name" "$state/appcast.xml" "$state/SHA256SUMS.txt"

# GitHub's latest-download redirect may briefly serve the previous release.
# Poll within a fixed budget; a delayed feed never invites a duplicate publish.
expected="<sparkle:version>$build</sparkle:version>"
feed_ready=false
for attempt in {1..12}; do
    served="$(curl -fsSL --max-time 20 -H 'Cache-Control: no-cache' "$feed" || true)"
    if /usr/bin/grep -Fq "$expected" <<<"$served"; then
        feed_ready=true
        break
    fi
    [[ "$attempt" = 12 ]] || sleep 5
done
if [[ "$feed_ready" != true ]]; then
    printf 'Release v%s is published, but the feed has not caught up. Verify the existing release; do not publish it again.\n' "$version" >&2
    exit 1
fi
printf 'Published Mooring %s to %s; installed copies update within about four hours.\n' "$version" "$feed"
