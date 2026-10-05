# Verified downloads

The first preview was ad hoc signed and was not notarized, so a downloaded copy triggers macOS's "Apple could not verify" warning. Developer ID signing plus Apple notarization and a stapled ticket is the distribution fix.

Builds, tests, signing, packaging, and validation run on the local Mac. Apple's notary service scans the submitted app archive; that external verification is required for notarization. GitHub Actions stays disabled.

## One-time credential setup

The local Keychain must contain a valid **Developer ID Application** certificate and its private key. An Apple Development or Apple Distribution certificate is not a substitute.

If an existing notarytool Keychain profile is available, use its name. Otherwise run this command yourself in Terminal:

```sh
xcrun notarytool store-credentials MacLink
```

Follow its secure prompts to authenticate using an App Store Connect API key or an Apple Account with an app-specific password. Do not put those secrets in chat, source files, shell command arguments, or GitHub. The profile name is not a secret.

## Build a notarized release

```sh
export MACLINK_CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAM_ID)'
export MACLINK_NOTARY_PROFILE='MacLink'
./scripts/ci-local.sh
./scripts/notarize-release.sh 0.1.0-preview.2
```

The script validates authentication, builds an arm64 app with hardened runtime and a secure timestamp, submits its ZIP to Apple, waits up to five minutes, saves Apple's log, staples the accepted ticket, and assesses both the app and the extracted final archive with Gatekeeper. It does not weaken Gatekeeper or publish a GitHub release automatically.

If Apple is still processing when the wait expires, preserve `dist/notarization` and resume the same submission:

```sh
./scripts/notarize-release.sh --resume 0.1.0-preview.2
```

A completed pending response with a valid submission ID is recovered automatically on resume. An ambiguous submit is retained for inspection instead of being silently retried; inspect `notarytool history` before any resubmission. Per-version locks prevent concurrent workflows. After a forced process termination, confirm the process listed in `workflow.lock/pid` is no longer running before removing that stale lock directory.

The app is reconstructed from the checksum-verified submitted archive before stapling. Review the Apple log before uploading the resulting ZIP and checksum to GitHub. Do not use `package-release.sh` to recreate an already-notarized ZIP: it builds a fresh app without the stapled ticket.

## Publish to the update feed

Installed copies update themselves from the public feed at `kcirtapfromspace/mooring-releases`.

The former `maclink-releases` repository URL redirects to `mooring-releases`, so existing installations still reach the signed feed and archives. Do not reuse the old repository name: GitHub would remove that redirect. New signed builds use the canonical Mooring feed URL. The app bundle identifier, Developer ID and Sparkle key stay the same.

After notarizing and reviewing the Apple log, publish with:

```sh
./scripts/publish-update.sh 0.3.0-preview.6
```

The script only publishes a stapled, Gatekeeper-accepted archive for that version. The build must be signed by team `67C7724279` and must follow this same feed. It signs the archive and the feed with the Sparkle EdDSA key in this Mac's login Keychain (Sparkle account `dev.maclink`), creates the public release and confirms the feed serves the new build.

Only the public key is in the app (`SUPublicEDKey`). To move the private key to another Mac, export it with Sparkle's `generate_keys -x` and import it there with `-f`. Never put it in chat, source files or GitHub.

Before a release that changes the updater, run `./scripts/test-update-local.sh`. It builds ad hoc copies under a separate bundle ID and serves them over loopback only. An old copy must verify, install and relaunch a new one in place, and must refuse both a tampered archive and a feed altered after signing.

The old test copy starts on a legacy feed URL that redirects to the canonical feed. After the update, the installed app must carry the canonical URL. This exercises the redirect migration without reading real connections or changing a running user session.

## Opening the existing preview

For a trusted copy of the first preview, after attempting to open it, use **System Settings → Privacy & Security → Open Anyway**, then confirm **Open**. This records an exception for that app. Do not disable Gatekeeper globally.

Sources: [Apple: safely open apps](https://support.apple.com/en-us/102445), [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [custom workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
