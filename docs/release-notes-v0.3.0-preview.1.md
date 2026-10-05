# Mooring 0.3.0 preview 1 — Experimental native session

Mooring can now connect two Macs directly, as an experimental option alongside Apple Screen Sharing. On the Mac you want to share, choose **Share This Mac… → Start Sharing**, then **Copy Pairing Code**. On the other Mac, choose **Connect with Mooring…**, paste the code and click **Pair & Connect**. Paired Macs then appear in the menu for one-click reconnection. Apple Screen Sharing and your saved Macs and preferences are unchanged under **Apple Screen Sharing**.

The sharing Mac captures its main display with ScreenCaptureKit and encodes it with the hardware H.264 encoder. The viewer decodes it in hardware and enters full screen after the first frame. The connection is encrypted and authenticated. Keyboard and mouse control works once the sharing Mac allows Mooring in Accessibility; otherwise the session is view-only. The sharing Mac also asks for Screen Recording permission.

Nothing listens until you click **Start Sharing**. Sharing stops when you close the Share window, click **Stop Sharing**, or the sharing Mac locks, sleeps or switches user; it never resumes on its own.

## Pairing and privacy

The pairing code carries the sharing Mac's pinned public key and a random 32-byte secret (Noise NKpsk0). Treat it like a password. **Reset Pairing** invalidates every earlier code. Secrets stay in the Keychain of each Mac; the saved list of paired Macs holds only names and addresses. Diagnostics contain measurements only. The Noise library (snow) reports no formal audit, and Mooring's session has not been audited either.

## Under the hood

The session protocol, message validation, direction and rate limits, held-key tracking, pairing codes and the saved peer list are implemented in Rust; Swift is limited to Apple media, input and interface APIs. Review fixes in this preview: repeated Command shortcuts such as Cmd-Z no longer lose key presses, lost video frames recover without long stalls, and a viewer connecting at the end of the host's accept window is no longer dropped mid-handshake.

Local validation passed: 127 Rust tests (60 for the session), Swift boundary checks, hardware H.264 encode/decode, and an encrypted 1080p loopback stream at 60 fps. Loopback timing is synthetic and is not display or input latency.

## Limitations

- Not yet tested between two Macs. Both Macs must run this preview; earlier builds cannot pair with it.
- One display, SDR H.264 over TCP, keyboard and mouse only. No audio, clipboard, file transfer or automatic reconnection.
- Intended for the local network. The code names the Mac by its `.local` address; enter an IP address in **Address** for other paths. Mooring opens no router ports and uses no relay. If macOS asks whether Mooring may accept incoming connections, allow it on the sharing Mac.
- No claim of performance parity with Apple Screen Sharing.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. All CI and builds run on the local host; GitHub Actions is disabled.
