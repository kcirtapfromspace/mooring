#!/bin/bash
# End-to-end in-place update on this Mac, over loopback only: builds an "old"
# and a "new" ad hoc MacLink under a separate bundle ID, serves the new one
# from a signed local feed, launches the old one, and waits for Sparkle to
# verify, install and relaunch the new build in place. The test copy uses its
# own data folder and preferences at first launch; the relaunched copy is
# closed as soon as it is found. Then a tampered archive and an altered feed
# must both be refused. Nothing is published.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
root="$project_root/target/update-test"
port=$((47000 + RANDOM % 1000))
identifier=dev.maclink.updatetest
feed="http://127.0.0.1:$port/appcast.xml"
[[ ! -e "$root" ]] || mv "$root" "$(mktemp -d "$project_root/target/update-test-old.XXXXXX")"
mkdir -p "$root/feed" "$root/home"
server=""
cleanup() {
    pkill -f "$root/installed/MacLink.app/Contents/MacOS/MacLink" 2>/dev/null || true
    [[ -z "$server" ]] || kill "$server" 2>/dev/null || true
}
trap cleanup EXIT

build() {
    MACLINK_BUNDLE_IDENTIFIER=$identifier MACLINK_BUNDLE_VERSION="$1" MACLINK_UPDATE_FEED="$feed" \
        MACLINK_APP_OUTPUT="$2" ./scripts/build-app.sh >/dev/null
}
build 9000 "$root/installed/MacLink.app"
build 9001 "$root/new/MacLink.app"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$root/new/MacLink.app" "$root/feed/MacLink-9001.zip"
./scripts/make-appcast.sh "$root/feed/MacLink-9001.zip" "http://127.0.0.1:$port/MacLink-9001.zip" "$root/feed" >/dev/null
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$root/feed" >"$root/server.log" 2>&1 &
server=$!
sleep 1

version() { /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$root/installed/MacLink.app/Contents/Info.plist"; }
[[ "$(version)" = 9000 ]]
started="$(date '+%Y-%m-%d %H:%M:%S')" launched=$SECONDS
open -n --env MACLINK_HOME="$root/home" --env MACLINK_DEFAULTS_SUITE="$identifier.suite" "$root/installed/MacLink.app"
deadline=$((SECONDS + 90))
until [[ "$(version)" = 9001 ]] && pgrep -f "$root/installed/MacLink.app/Contents/MacOS/MacLink" >/dev/null; do
    if (( SECONDS > deadline )); then
        printf '%s\n' 'Update test failed: the installed copy was not replaced and relaunched within 90 s.' >&2
        /usr/bin/log show --start "$started" --style compact \
            --predicate 'subsystem == "dev.maclink" OR process CONTAINS "Autoupdate" OR subsystem CONTAINS "sparkle"' >&2 || true
        exit 1
    fi
    sleep 1
done
codesign --verify --deep --strict "$root/installed/MacLink.app"
/usr/bin/grep -q 'GET /MacLink-9001.zip' "$root/server.log"
printf 'In-place update passed: build 9000 verified, installed and relaunched build 9001 within %s s of launch.\n' "$((SECONDS - launched))"

# Refusals. A newer build whose archive changed after signing, then a feed
# changed after signing, must never be installed.
pkill -f "$root/installed/MacLink.app/Contents/MacOS/MacLink" || true
build 9002 "$root/newer/MacLink.app"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$root/newer/MacLink.app" "$root/feed/MacLink-9002.zip"
./scripts/make-appcast.sh "$root/feed/MacLink-9002.zip" "http://127.0.0.1:$port/MacLink-9002.zip" "$root/feed" >/dev/null
cp "$root/feed/MacLink-9002.zip" "$root/good-9002.zip"
python3 - "$root/feed/MacLink-9002.zip" <<'PY'
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
    open -n --env MACLINK_HOME="$root/home" --env MACLINK_DEFAULTS_SUITE="$identifier.suite" "$root/installed/MacLink.app"
    sleep 20
    pkill -f "$root/installed/MacLink.app/Contents/MacOS/MacLink" || true
    sleep 1
    tail -n +"$((lines + 1))" "$root/server.log" > "$root/requests.log"
    [[ "$(version)" = 9001 ]] || { printf 'Update test failed: %s was installed.\n' "$1" >&2; exit 1; }
}
attempt "a tampered archive"
/usr/bin/grep -q 'GET /MacLink-9002.zip' "$root/requests.log" \
    || { printf '%s\n' 'Update test failed: the tampered archive was never fetched, so its rejection was not exercised.' >&2; exit 1; }
cp "$root/good-9002.zip" "$root/feed/MacLink-9002.zip"
sed -i '' 's#MacLink 0.3.0 for Apple silicon.#Altered after signing.#' "$root/feed/appcast.xml"
attempt "an altered feed"
/usr/bin/grep -q 'GET /appcast.xml' "$root/requests.log" \
    || { printf '%s\n' 'Update test failed: the altered feed was never read.' >&2; exit 1; }
if /usr/bin/grep -q 'GET /MacLink-9002.zip' "$root/requests.log"; then
    printf '%s\n' 'Update test failed: an archive was fetched from a feed altered after signing.' >&2; exit 1
fi
printf '%s\n' 'Refusals passed: a tampered archive and an altered feed were not installed.'
