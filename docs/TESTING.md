# Testing the preview on another Mac

Download `MacLink-v0.2.0-preview.3-macos-arm64.zip` and `SHA256SUMS.txt` from the release while signed in to the GitHub account with repository access. MacLink supports Apple silicon only and requires macOS 14 or later. Apple's High Performance mode additionally requires compatible Macs at both ends.

1. In the download directory, verify the ZIP with `shasum -a 256 -c SHA256SUMS.txt`.
2. Quit older MacLink copies. Extract the ZIP and replace `MacLink.app` in Applications. Saved Macs and existing configured preferences are preserved.
3. Open MacLink, choose **Add Mac**, enter the remote hostname or IP, and click **Add & Connect**. The address is the only required field. Name and port are under **More Options**; port defaults to 5900. On the remote Mac, Screen Sharing must be enabled for your account.
4. Choose **Enable & Connect** when asked, then grant the installed MacLink app Accessibility access in macOS. Verify that connection continues automatically after the grant. Alternatively, **Connect Without Automation** should open a manual session. Sign in through Apple Screen Sharing if prompted.
5. On a fresh installation, verify Auto mode and full screen work without opening Settings or marking a home network. Leave the identified session on a healthy direct Wi-Fi/Ethernet path long enough for the 35-second learning span and subsequent mode-policy observations. Confirm Apple's actual mode on both Macs if MacLink requests a High Performance trial; the exported document alone is not proof.
6. Close the managed window and verify that MacLink pauses. Resume when ready. Test sleep/wake and network changes; unrelated Screen Sharing windows must remain untouched. A familiar path still requires healthy checks before automatic opening.
7. For optional overrides, open **Settings** and try Standard or Prefer High Performance. Expand **Advanced** to inspect detailed automation and home controls. Previously configured users should retain their existing choices rather than being reset to new defaults.

The distribution is Developer ID signed, notarized and stapled. macOS may still show its normal first-launch downloaded-app confirmation. If **Apple could not verify MacLink.app** appears, confirm that you opened the extracted preview 3 app rather than an older copy; do not change Gatekeeper settings. Local development builds are ad hoc by default.

## What to report

- Both Mac models, macOS versions and connection type: Ethernet, Wi-Fi, off-site, travel router, Tailscale or WireGuard.
- Whether address-only Add & Connect, permission auto-continuation, saved-Mac persistence and full screen work.
- Whether the default flow avoids Settings; whether existing mode, automation-off and display preferences survive an update.
- Whether Auto requests a suitable mode, Apple's actual mode agrees, and fallback reconnects only the expected session. Include the displayed reason, not private network details.
- Whether closing, pausing, changing networks or waking causes an unexpected reopen, duplicate window or repeated High Performance trial.
- For Apple's session: resolution/scale, typing/scrolling delay, and High Performance success or failure. These are Apple-backend observations, not Rust-renderer benchmarks.

Do not include passwords, clipboard contents, private screen recordings or session keys. RFB timing does not measure bandwidth or video latency, and a travel bridge can make separate locations look like one familiar network.

## Local build and release checks

All compilation, tests, linting, signing, archive creation and Gatekeeper validation run on the local development Mac. Apple scans the signed archive through its notarization service. GitHub stores source and release assets only; Actions remains disabled.

```sh
./scripts/ci-local.sh
MACLINK_CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAM_ID)' \
  MACLINK_NOTARY_PROFILE=MacLink \
  ./scripts/notarize-release.sh 0.2.0-preview.3
```

The local suite includes 67 Rust tests (8 CLI, 41 core, 18 platform), 73 Swift session-parser checks, expanded defaults/home-state regressions and loopback CLI integration. It covers trial eligibility, timing/dwell, migration, disabled preferences, target-isolated familiar paths, stale replies and bounded retries. Published assets include validation output and checksums.

Local tests do not verify live two-Mac negotiation, display behavior or performance. Complete the checks above on the second Apple silicon Mac.
