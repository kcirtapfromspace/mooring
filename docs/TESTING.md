# Testing the preview on another Mac

Download the release ZIP and its SHA-256 checksum file while signed in to the GitHub account that can access this repository. This app supports Apple silicon (arm64) only and requires macOS 14 or later. Apple's High Performance sharing requires supported Apple silicon Macs at both ends.

1. Verify the downloaded ZIP against `SHA256SUMS.txt` with `shasum -a 256 -c SHA256SUMS.txt` in the download directory.
2. Quit any older MacLink copy. Extract the ZIP, then replace the previous `MacLink.app` in Applications (or run the new copy from its extracted folder). Saved connections remain in Application Support.
3. MacLink now lives in the menu bar. Use **Open Connections** to add the remote Mac's hostname or IP. The default port is 5900.
4. Open **Settings**, choose the Mac, and use **Detect Network → Use This Network as Home** while at home. The remote Mac can be offline during home setup. Repeat for Ethernet and Wi-Fi if you use both. Confirm High Performance support on both Macs, then enable automation and full screen. A successful RFB check alone does not establish that support or measure bandwidth.
5. Grant the installed MacLink app Accessibility access using its Settings button. Optionally enable Launch MacLink at Login. Save. Automatic home opening waits for 35 seconds of healthy checks; sign in through Apple if prompted.
6. Use the menu's **Mode Preference** to try Standard, Auto and Prefer High Performance. A mode change reconnects; it can change between the physical and a virtual desktop. Confirm Apple's actual mode and full-screen state on both Macs. The URL adapter is experimental.
7. Close the managed window, then check that MacLink pauses. Resume when ready. Test a network change and sleep/wake; confirm that unrelated Screen Sharing windows are left alone.

The automation preview is signed with Developer ID and notarized by Apple. Its ticket is stapled to the app and validated after extracting the final ZIP. macOS may still show its normal first-launch downloaded-app confirmation. The app requests modes through undocumented, Apple-generated URL options and supervises matching windows with Accessibility. It does not contain a custom video engine, and actual two-Mac behavior is not yet verified by the local tests.

If you still see **Apple could not verify MacLink.app**, confirm you downloaded `MacLink-v0.2.0-preview.2-macos-arm64.zip` and are opening the extracted new app. The first foundation preview was not notarized. Use the signed download instead of changing Gatekeeper settings.

## What to report

- Both Mac models, macOS versions, and connection type (Ethernet, Wi-Fi, or off-site).
- Whether saved Macs persist after quitting and reopening MacLink.
- Whether Check Connection succeeds, fails clearly, or reaches its deadline.
- Whether Connect opens the right destination in Apple Screen Sharing.
- Any clipped controls or text, unexpected exits, or input problems.
- Whether the requested mode agrees with Apple's actual session, full screen succeeds, and switching reconnects only the expected window.
- Whether home Wi-Fi/Ethernet, Ubiquiti travel-router, Tailscale and WireGuard transitions choose sensible modes. Include the displayed reason, not private network details.
- For Apple's session: display resolution/scale, perceived typing/scrolling delay, and whether High Performance works. These observations establish the baseline for the future Rust renderer; they are not MacLink streaming results.

Do not include passwords, clipboard contents, private screen recordings, or session keys in reports.

## Local build and release checks

All compilation, tests, linting, signing, archive creation, and Gatekeeper validation run on the local development Mac. Apple scans the submitted signed archive through its notarization service. There are no GitHub Actions workflows. GitHub stores source code and downloadable release assets only.

```sh
./scripts/ci-local.sh
MACLINK_CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAM_ID)' \
  MACLINK_NOTARY_PROFILE=MacLink \
  ./scripts/notarize-release.sh v0.2.0-preview.2
```

The published release includes local validation output and checksums. Testing on the second Apple silicon Mac is still required to validate the remote connection and user experience.
