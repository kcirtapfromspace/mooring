# Testing the preview on another Mac

Download `MacLink-v0.3.0-preview.2-macos-arm64.zip` and `SHA256SUMS.txt` from the release while signed in to the GitHub account with repository access. MacLink supports Apple silicon only and requires macOS 14 or later. Apple's High Performance mode additionally requires compatible Macs at both ends. The experimental native session requires this preview on both Macs.

1. In the download directory, verify the ZIP with `shasum -a 256 -c SHA256SUMS.txt`.
2. Quit older MacLink copies. Extract the ZIP and replace `MacLink.app` in Applications. Saved Macs and existing configured preferences are preserved.

## Apple Screen Sharing

1. Open MacLink, choose **Add Mac**, enter the remote hostname or IP, and click **Add & Connect**. The address is the only required field. Name and port are under **More Options**; port defaults to 5900. On the remote Mac, Screen Sharing must be enabled for your account. Saved Macs now appear under the menu's **Apple Screen Sharing** submenu.
2. Choose **Enable & Connect** when asked, then grant the installed MacLink app Accessibility access in macOS. Verify that connection continues automatically after the grant. Alternatively, **Connect Without Automation** should open a manual session. Sign in through Apple Screen Sharing if prompted.
3. On a fresh installation, verify Auto mode and full screen work without opening Settings or marking a home network. Leave the identified session on a healthy direct Wi-Fi/Ethernet path long enough for the 35-second learning span and subsequent mode-policy observations. Confirm Apple's actual mode on both Macs if MacLink requests a High Performance trial; the exported document alone is not proof.
4. Close the managed window and verify that MacLink pauses. Resume when ready. Test sleep/wake and network changes; unrelated Screen Sharing windows must remain untouched. A familiar path still requires healthy checks before automatic opening.
5. For optional overrides, open **Settings** and try Standard or Prefer High Performance. Expand **Advanced** to inspect detailed automation and home controls. Previously configured users should retain their existing choices rather than being reset to new defaults.

## Experimental native session

1. On the Mac to share, choose **Share This Mac…** and click **Start Sharing**. Grant Screen Recording when macOS asks, then click Start Sharing again if needed. If macOS asks whether MacLink may accept incoming connections, allow it. Click **Copy Pairing Code**.
2. Move the code to the viewing Mac without posting it anywhere shared; it works like a password. On the viewing Mac, choose **Connect with MacLink…**, paste the code and click **Pair & Connect**. Leave **Address** empty on the same local network; enter the sharing Mac's IP address for other paths.
3. Verify the remote display appears and enters full screen, and that the status bar shows frame rate, round-trip time and the sharing Mac's resolution ("screen unchanged" means no new frames were needed). The session is view-only until the sharing Mac clicks **Enable Keyboard & Mouse…** and allows MacLink in Accessibility. Confirm there is exactly one pointer in both view-only and control modes.
4. With control enabled, test typing, repeated shortcuts such as Cmd-Z twice, modifier keys, clicks, double-clicks, drags, right-clicks and trackpad scrolling. Switch away from the viewer mid-drag or mid-keypress and confirm nothing stays pressed on the sharing Mac.
5. Test colored terminal text and small UI text for legibility, window dragging, scrolling and video playback. Note any stalls, stale regions or dropped frames.
6. Close the viewer, then reconnect from the paired Mac's name in the menu and from **Open Connections…**, where pairings are listed with Screen Sharing Macs. Leave a session idle past the sharing Mac's display-sleep time; it should stay connected. Stop sharing, lock the sharing Mac, and put it to sleep; each must end the session with a stated reason and a **Reconnect** button, and unlocking must not resume sharing on its own. After **Reset Pairing**, the old code must fail; **Remove** in Connections must forget a pairing.
7. While scrolling or dragging a window on the sharing Mac, note the frame rate, then use **Save Diagnostics…** in the Share window and **Diagnostics…** in the viewer. Both save measurements only, including per-frame encode and send times, frame sizes and encoder drops. Attach both to your report.

The distribution is Developer ID signed, notarized and stapled. macOS may still show its normal first-launch downloaded-app confirmation. If **Apple could not verify MacLink.app** appears, confirm that you opened the extracted 0.3.0 preview 2 app rather than an older copy; do not change Gatekeeper settings. Local development builds are ad hoc by default.

## What to report

- Both Mac models, macOS versions, display resolutions and scale, and connection type: Ethernet, Wi-Fi, off-site, travel router, Tailscale or WireGuard.
- Apple Screen Sharing: whether address-only Add & Connect, permission auto-continuation, saved-Mac persistence and full screen work; whether the default flow avoids Settings; whether existing preferences survive an update.
- Apple Screen Sharing: whether Auto requests a suitable mode, Apple's actual mode agrees, and fallback reconnects only the expected session. Include the displayed reason, not private network details. Note any unexpected reopen, duplicate window or repeated High Performance trial.
- Native session: pairing and reconnect success, time to first image, displayed frame rate and round-trip time, text legibility, typing/scrolling delay compared with Apple Screen Sharing, stuck keys or buttons, and exactly how any session ended.
- The permission prompts each Mac showed, and whether denying one produced a clear message.

Do not include passwords, pairing codes, clipboard contents, private screen recordings or session keys. RFB timing does not measure bandwidth or video latency, the native session's round-trip time is not display latency, and a travel bridge can make separate locations look like one familiar network.

## Local build and release checks

All compilation, tests, linting, signing, archive creation and Gatekeeper validation run on the local development Mac. Apple scans the signed archive through its notarization service. GitHub stores source and release assets only; Actions remains disabled.

```sh
./scripts/ci-local.sh
MACLINK_CODESIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAM_ID)' \
  MACLINK_NOTARY_PROFILE=MacLink \
  ./scripts/notarize-release.sh 0.3.0-preview.2
```

The local suite includes 128 Rust tests (8 CLI, 41 core, 18 platform, 61 session), 73 Swift session-parser checks, the defaults/home-state regressions, loopback CLI integration, and the native Swift checks: input boundary and Command key-up dispatch, privacy classification, hardware H.264 encode/decode with recovery and the two-frame in-flight bound, session boundary, and an encrypted 1080p loopback stream. Published assets include validation output and checksums.

Local tests do not verify live two-Mac negotiation, a real native session between two Macs, display behavior or performance. Complete the checks above on the second Apple silicon Mac.
