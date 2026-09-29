# Testing the preview on another Mac

Download the release ZIP and its SHA-256 checksum file while signed in to the GitHub account that can access this repository. This app supports Apple silicon (arm64) only and requires macOS 14 or later. Apple's High Performance sharing requires supported Apple silicon Macs at both ends.

1. Verify the downloaded ZIP against `SHA256SUMS.txt` with `shasum -a 256 -c SHA256SUMS.txt` in the download directory.
2. Extract the ZIP, then move `MacLink.app` to Applications or run it from the extracted folder.
3. Add the remote Mac's hostname or IP. Use the normal Screen Sharing port, 5900, unless your setup uses another port.
4. Use **Check Connection**. A successful check confirms only an RFB service responds; the TCP time is not desktop latency or a throughput test.
5. Click **Connect** and complete sign-in in Apple Screen Sharing. Choose High Performance there if supported.

This preview is signed ad hoc for integrity, not with a Developer ID certificate, and is not notarized. macOS may require approval for a downloaded app. It does not contain a custom video engine or automatically change Apple's sharing mode.

If the first preview shows **Apple could not verify MacLink.app**, after attempting to open it go to **System Settings → Privacy & Security → Open Anyway**, then confirm **Open**. This adds an exception for that app. Future verified builds use the [Developer ID and notarization workflow](NOTARIZATION.md).

## What to report

- Both Mac models, macOS versions, and connection type (Ethernet, Wi-Fi, or off-site).
- Whether saved Macs persist after quitting and reopening MacLink.
- Whether Check Connection succeeds, fails clearly, or reaches its deadline.
- Whether Connect opens the right destination in Apple Screen Sharing.
- Any clipped controls or text, unexpected exits, or input problems.
- For Apple's session: display resolution/scale, perceived typing/scrolling delay, and whether High Performance works. These observations establish the baseline for the future Rust renderer; they are not MacLink streaming results.

Do not include passwords, clipboard contents, private screen recordings, or session keys in reports.

## Local build and release checks

All compilation, tests, linting, signing, and archive creation run on the local development Mac. There are no GitHub Actions workflows. GitHub stores source code and downloadable release assets only.

```sh
./scripts/ci-local.sh
./scripts/package-release.sh v0.1.0-preview.1
```

The published release includes local validation output and checksums. Testing on the second Apple silicon Mac is still required to validate the remote connection and user experience.
