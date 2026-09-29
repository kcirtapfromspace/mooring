#!/bin/bash
# Build locally, ask Apple's notary service to verify, then staple and package.
# No GitHub Actions, credentials in source, or Gatekeeper overrides.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

resume=false
if [[ "${1:-}" = "--resume" ]]; then
    resume=true
    shift
fi
release_version="${1:-}"
release_version="${release_version#v}"
if [[ $# != 1 || ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    printf '%s\n' 'Usage: scripts/notarize-release.sh [--resume] VERSION' >&2
    exit 1
fi
if [[ "$(uname -s)" != Darwin || "${GITHUB_ACTIONS:-false}" = true ]]; then
    printf '%s\n' 'Notarization must be initiated from the local development Mac.' >&2
    exit 1
fi
profile="${MACLINK_NOTARY_PROFILE:-}"
if [[ -z "$profile" ]]; then
    printf '%s\n' 'Set MACLINK_NOTARY_PROFILE to an existing notarytool Keychain profile name.' >&2
    printf '%s\n' 'For first-time setup, run: xcrun notarytool store-credentials MacLink' >&2
    exit 1
fi

state="$project_root/dist/notarization/v$release_version"
bundle="$state/MacLink.app"
submission="$state/submission.json"
input_archive="$state/submitted.zip"
mkdir -p "$state"
if ! mkdir "$state/workflow.lock" 2>/dev/null; then
    printf 'Workflow is locked at %s/workflow.lock. Check for another running notarization before removing a stale lock.\n' "$state" >&2
    exit 1
fi
printf '%s\n' "$$" > "$state/workflow.lock/pid"
verification=""
cleanup() {
    [[ -z "$verification" ]] || rm -rf "$verification"
    rm -f "$state/workflow.lock/pid"
    rmdir "$state/workflow.lock"
}
trap cleanup EXIT

if [[ "$resume" = true ]]; then
    if [[ ! -f "$submission" && -f "$state/submission-pending.json" ]]; then
        pending_id="$(plutil -extract id raw -o - "$state/submission-pending.json" 2>/dev/null || true)"
        if [[ "$pending_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
            mv "$state/submission-pending.json" "$submission"
        fi
    fi
    if [[ ! -f "$submission" || ! -f "$input_archive" ]]; then
        printf '%s\n' 'No complete saved submission exists for this version.' >&2
        printf '%s\n' 'If submission-pending.json is incomplete, inspect notarytool history before retrying.' >&2
        exit 1
    fi
    (cd "$state" && shasum -a 256 -c submitted.sha256)
else
    identity="${MACLINK_CODESIGN_IDENTITY:-}"
    if [[ -z "$identity" || "$identity" = - ]]; then
        printf '%s\n' 'Set MACLINK_CODESIGN_IDENTITY to a valid Developer ID Application identity.' >&2
        exit 1
    fi
    if [[ -e "$submission" || -e "$state/submission-pending.json" ]]; then
        printf '%s\n' 'A submission was already attempted. Resume it or inspect Apple history before submitting again.' >&2
        exit 1
    fi
    # Validate the named credential without printing or reading its secret value.
    xcrun notarytool history --keychain-profile "$profile" --output-format json >/dev/null
    mkdir -p "$state"
    MACLINK_CODESIGN_IDENTITY="$identity" MACLINK_RELEASE_VERSION="$release_version" \
        MACLINK_APP_OUTPUT="$bundle" ./scripts/build-app.sh
    codesign -dv --verbose=4 "$bundle" 2> "$state/signature.txt"
    if ! /usr/bin/grep -q '^Authority=Developer ID Application:' "$state/signature.txt"; then
        printf '%s\n' 'The app must be signed with Developer ID Application before submission.' >&2
        exit 1
    fi
    COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$bundle" "$input_archive"
    (cd "$state" && shasum -a 256 submitted.zip > submitted.sha256)
    # Keep an ambiguous failed attempt visible; do not silently resubmit it.
    xcrun notarytool submit "$input_archive" --keychain-profile "$profile" \
        --no-wait --output-format json > "$state/submission-pending.json"
    mv "$state/submission-pending.json" "$submission"
fi

submission_id="$(plutil -extract id raw -o - "$submission")"
if [[ ! "$submission_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    printf '%s\n' 'The saved submission does not contain a valid Apple submission ID.' >&2
    exit 1
fi
printf 'Apple notarization submission: %s\n' "$submission_id"
xcrun notarytool wait "$submission_id" --keychain-profile "$profile" \
    --timeout 5m --output-format json > "$state/result.json" || true
status="$(plutil -extract status raw -o - "$state/result.json" 2>/dev/null || true)"
if [[ "$status" != Accepted && "$status" != Invalid && "$status" != Rejected ]]; then
    printf 'Submission preserved. Resume with: scripts/notarize-release.sh --resume %s\n' "$release_version" >&2
    exit 1
fi
xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$state/notary-log.json"
if [[ "$status" != Accepted ]]; then
    printf 'Apple returned %s. Inspect %s/notary-log.json. No release archive was published.\n' "$status" "$state" >&2
    exit 1
fi

# Reconstruct from the exact archive submitted to Apple, never a mutable build.
(cd "$state" && shasum -a 256 -c submitted.sha256)
verification="$(mktemp -d "$state/verify.XXXXXX")"
/usr/bin/ditto -x -k "$input_archive" "$verification"
bundle="$verification/MacLink.app"
xcrun stapler staple "$bundle"
xcrun stapler validate "$bundle"
codesign --verify --deep --strict "$bundle"
spctl --assess --type execute --verbose=2 "$bundle"

archive_name="MacLink-v$release_version-macos-arm64.zip"
staged_archive="$state/notarized.zip"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$bundle" "$staged_archive"
/usr/bin/ditto -x -k "$staged_archive" "$verification/final"
xcrun stapler validate "$verification/final/MacLink.app"
codesign --verify --deep --strict "$verification/final/MacLink.app"
spctl --assess --type execute --verbose=2 "$verification/final/MacLink.app"
mv "$staged_archive" "$project_root/dist/$archive_name"
(cd "$project_root/dist" && shasum -a 256 "$archive_name" > "$archive_name.sha256")
printf 'Notarized release ready: %s/dist/%s\n' "$project_root" "$archive_name"
printf 'Review Apple warnings, if any, in: %s/notary-log.json\n' "$state"
