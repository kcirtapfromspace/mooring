#!/bin/bash
# Writes a signed Sparkle update feed for one Mooring archive:
#   scripts/make-appcast.sh ARCHIVE DOWNLOAD_URL OUTPUT_DIR
# The archive and the feed are signed with the EdDSA key in this Mac's Keychain
# using the existing signing account. Versions come from the archive itself.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# != 3 ]]; then
    printf '%s\n' 'Usage: scripts/make-appcast.sh ARCHIVE DOWNLOAD_URL OUTPUT_DIR' >&2
    exit 1
fi
archive="$1" url="$2" output="$3"
[[ -f "$archive" && "$url" =~ ^https?:// ]] || { printf '%s\n' 'Need an existing archive and an http(s) download URL.' >&2; exit 1; }
sparkle_dir="$("$project_root/scripts/fetch-sparkle.sh")"
# This opaque Keychain account must stay stable for installed-copy signatures.
sparkle_account=dev.maclink
mkdir -p "$output"
inspect="$(mktemp -d "$output/.inspect.XXXXXX")"
trap 'rm -rf "$inspect"' EXIT
/usr/bin/ditto -x -k "$archive" "$inspect"
plist="$inspect/Mooring.app/Contents/Info.plist"
value() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
build="$(value CFBundleVersion)" release="$(value MooringReleaseVersion)" minimum="$(value LSMinimumSystemVersion)"
[[ "$build" =~ ^[0-9]+$ ]] || { printf 'Unexpected build number: %s\n' "$build" >&2; exit 1; }
value SUPublicEDKey >/dev/null

# Prints: sparkle:edSignature="…" length="…"
enclosure="$("$sparkle_dir/bin/sign_update" --account "$sparkle_account" "$archive")"
[[ "$enclosure" =~ ^sparkle:edSignature=\"[A-Za-z0-9+/=]+\"\ length=\"[0-9]+\"$ ]] || { printf '%s\n' 'sign_update failed.' >&2; exit 1; }
published="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > "$output/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Mooring</title>
    <item>
      <title>Mooring $release</title>
      <pubDate>$published</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$release</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <description><![CDATA[<p>Mooring $release for Apple silicon.</p>]]></description>
      <enclosure url="$url" $enclosure type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
# Sign the feed itself; the app requires a signed feed.
"$sparkle_dir/bin/sign_update" --account "$sparkle_account" --disable-signing-warning "$output/appcast.xml" >/dev/null
/usr/bin/grep -q 'sparkle-signatures' "$output/appcast.xml" || { printf '%s\n' 'The feed was not signed.' >&2; exit 1; }
printf 'Signed feed for Mooring %s (build %s): %s/appcast.xml\n' "$release" "$build" "$output"
