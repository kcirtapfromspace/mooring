#!/bin/bash
# End-to-end update on this Mac: copies preview 35 under an isolated bundle
# ID, builds a new ad hoc Mooring, and serves the new one over loopback only
# from a signed local feed, launches the old one, and waits for Sparkle to
# verify, install and relaunch the new build in place. The test copy uses its
# own data folder and preferences at first launch; the relaunched copy is
# closed as soon as it is found. Then a tampered archive and an altered feed
# must both be refused. Nothing is published.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
root="$project_root/target/update-test"
installed="$root/installed/Previous.app"
port=$((47000 + RANDOM % 1000))
identifier=dev.mooring.updatetest
feed="http://127.0.0.1:$port/appcast.xml"
legacy_feed="http://127.0.0.1:$port/legacy-appcast.xml"
[[ ! -e "$root" ]] || mv "$root" "$(mktemp -d "$project_root/target/update-test-old.XXXXXX")"
mkdir -p "$root/feed" "$root/home"
server=""
cleanup() {
    pkill -f "$installed/Contents/MacOS/" 2>/dev/null || true
    [[ -z "$server" ]] || kill "$server" 2>/dev/null || true
}
trap cleanup EXIT

build() {
    MOORING_BUNDLE_IDENTIFIER=$identifier MOORING_BUNDLE_VERSION="$1" MOORING_UPDATE_FEED="${3:-$feed}" \
        MOORING_APP_OUTPUT="$2" ./scripts/build-app.sh >/dev/null
}
# An existing installation follows its old repository URL through a redirect;
# the installed update must then carry the new canonical feed URL.
# Exercise the actual previous app, including its previous executable/CLI
# names and updater. Use a separate identity, data directory and preferences.
legacy_apps=("$project_root/dist/notarization/v0.3.0-preview.35/"*.app)
if [[ ! -d "${legacy_apps[0]}" ]]; then
    mkdir -p "$root/legacy-download" "$root/legacy"
    gh release download v0.3.0-preview.35 --repo kcirtapfromspace/mooring \
        --pattern '*-macos-arm64.zip' --dir "$root/legacy-download"
    archives=("$root/legacy-download/"*.zip)
    /usr/bin/ditto -x -k "${archives[0]}" "$root/legacy"
    legacy_apps=("$root/legacy/"*.app)
fi
[[ ${#legacy_apps[@]} = 1 && -d "${legacy_apps[0]}" ]] || { printf '%s\n' 'Need exactly one previous-preview app.' >&2; exit 1; }
mkdir -p "$root/installed"
/usr/bin/ditto "${legacy_apps[0]}" "$installed"
plist="$installed/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $identifier" "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 9000' "$plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $legacy_feed" "$plist"
sparkle="$installed/Contents/Frameworks/Sparkle.framework"
for nested in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle" "$installed"/Contents/Resources/*; do
    [[ -d "$nested" || -x "$nested" ]] || continue
    codesign --force --sign - "$nested"
done
codesign --force --sign - "$installed"
codesign --verify --deep --strict "$installed"
build 9001 "$root/new/Mooring.app"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$root/new/Mooring.app" "$root/feed/Mooring-9001.zip"
./scripts/make-appcast.sh "$root/feed/Mooring-9001.zip" "http://127.0.0.1:$port/Mooring-9001.zip" "$root/feed" >/dev/null
python3 - "$port" "$root/feed" >"$root/server.log" 2>&1 <<'PY' &
import functools
import http.server
import sys
from urllib.parse import urlsplit

class FeedHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if urlsplit(self.path).path == '/legacy-appcast.xml':
            self.send_response(301)
            self.send_header('Location', '/appcast.xml')
            self.end_headers()
            return
        super().do_GET()

handler = functools.partial(FeedHandler, directory=sys.argv[2])
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), handler).serve_forever()
PY
server=$!
sleep 1

version() { /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$installed/Contents/Info.plist"; }
[[ "$(version)" = 9000 ]]
started="$(date '+%Y-%m-%d %H:%M:%S')" launched=$SECONDS
open -n --env MACLINK_HOME="$root/home" --env MACLINK_DEFAULTS_SUITE="$identifier.suite" \
    --env MOORING_HOME="$root/home" --env MOORING_DEFAULTS_SUITE="$identifier.suite" "$installed"
deadline=$((SECONDS + 90))
until [[ "$(version)" = 9001 ]] && pgrep -f "$installed/Contents/MacOS/Mooring" >/dev/null; do
    if (( SECONDS > deadline )); then
        printf '%s\n' 'Update test failed: the installed copy was not replaced and relaunched within 90 s.' >&2
        /usr/bin/log show --start "$started" --style compact \
            --predicate 'subsystem == "dev.mooring" OR subsystem == "dev.maclink" OR process CONTAINS "Autoupdate" OR subsystem CONTAINS "sparkle"' >&2 || true
        exit 1
    fi
    sleep 1
done
codesign --verify --deep --strict "$installed"
/usr/bin/grep -q 'GET /legacy-appcast.xml' "$root/server.log"
/usr/bin/grep -q 'GET /appcast.xml' "$root/server.log"
/usr/bin/grep -q 'GET /Mooring-9001.zip' "$root/server.log"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$installed/Contents/Info.plist")" = "$feed" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$installed/Contents/Info.plist")" = Mooring ]]
[[ -x "$installed/Contents/Resources/mooring" ]]
"$installed/Contents/Resources/mooring" --config-dir "$root/home" list >/dev/null
printf 'In-place update passed: the legacy feed redirected, build 9000 verified, installed and relaunched build 9001 with the canonical feed within %s s of launch.\n' "$((SECONDS - launched))"

# Refusals. A newer build whose archive changed after signing, then a feed
# changed after signing, must never be installed.
pkill -f "$installed/Contents/MacOS/" || true
build 9002 "$root/newer/Mooring.app"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$root/newer/Mooring.app" "$root/feed/Mooring-9002.zip"
./scripts/make-appcast.sh "$root/feed/Mooring-9002.zip" "http://127.0.0.1:$port/Mooring-9002.zip" "$root/feed" >/dev/null
cp "$root/feed/Mooring-9002.zip" "$root/good-9002.zip"
python3 - "$root/feed/Mooring-9002.zip" <<'PY'
import sys
path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
data[len(data) // 2] ^= 0xFF  # same length, different bytes
open(path, 'wb').write(data)
PY
# Launches the installed copy for 20 s; the requests it made land in $root/requests.log.
attempt() {
    local lines
    lines=$(wc -l < "$root/server.log")
    open -n --env MACLINK_HOME="$root/home" --env MACLINK_DEFAULTS_SUITE="$identifier.suite" \
    --env MOORING_HOME="$root/home" --env MOORING_DEFAULTS_SUITE="$identifier.suite" "$installed"
    sleep 20
    pkill -f "$installed/Contents/MacOS/" || true
    sleep 1
    tail -n +"$((lines + 1))" "$root/server.log" > "$root/requests.log"
    [[ "$(version)" = 9001 ]] || { printf 'Update test failed: %s was installed.\n' "$1" >&2; exit 1; }
}
attempt "a tampered archive"
/usr/bin/grep -q 'GET /Mooring-9002.zip' "$root/requests.log" \
    || { printf '%s\n' 'Update test failed: the tampered archive was never fetched, so its rejection was not exercised.' >&2; exit 1; }
cp "$root/good-9002.zip" "$root/feed/Mooring-9002.zip"
sed -i '' 's#Mooring 0.3.0 for Apple silicon.#Altered after signing.#' "$root/feed/appcast.xml"
attempt "an altered feed"
/usr/bin/grep -q 'GET /appcast.xml' "$root/requests.log" \
    || { printf '%s\n' 'Update test failed: the altered feed was never read.' >&2; exit 1; }
if /usr/bin/grep -q 'GET /Mooring-9002.zip' "$root/requests.log"; then
    printf '%s\n' 'Update test failed: an archive was fetched from a feed altered after signing.' >&2; exit 1
fi
printf '%s\n' 'Refusals passed: a tampered archive and an altered feed were not installed.'
