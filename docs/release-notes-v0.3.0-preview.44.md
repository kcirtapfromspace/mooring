# Mooring 0.3.0 preview 44 — Pair with a PIN

Pairing no longer means copying a long code from one Mac to the other, and it no longer depends on screen sharing.

On the Mac to pair with, choose **Show Pairing PIN…** in the menu bar, or **Show PIN…** in the Share window. It shows six characters, such as `K7Q M2P`, whether or not that Mac is sharing, and even while another Mac is viewing it. On the other Mac, choose **Pair a Mac…**. Macs nearby that are showing a PIN appear by name; choose one, or enter its address, and type the PIN. Case, spaces and dashes don't matter. That Mac is added to your list and nothing else changes: no session opens, and a session you have open stays as it is. **Connect** opens it then or later. One Mac can pair with as many Macs as you like, one PIN each.

A PIN works once, for ten minutes and five tries. It stops when its window closes, or when that Mac locks or sleeps. The PIN window says when a wrong PIN was tried and how many tries are left. Six characters are too few to protect a connection on their own: anyone who watched one attempt could try every PIN offline. So Mooring runs the PIN through SPAKE2, a password-authenticated key exchange (RustCrypto's `spake2`, MIT OR Apache-2.0). Each side ends up with a full-strength key only if both used the same PIN, so each guess needs a live attempt, and the sharing Mac allows five. That key then approves the viewing Mac's own key exactly as a one-time code does, so connecting afterwards works as before. The first time, macOS asks to allow Local Network access on the viewing Mac, for finding Macs nearby.

The long code still works, under **Use a pairing code instead**, for pairing over a VPN or with a Mac on preview 43 or earlier. Pairing with a code still connects at once, switching Macs as in preview 43.

Both Macs need this preview to pair with a PIN. Mooring still shows one Mac at a time, and a sharing Mac still takes one viewer at a time.

Local validation covers Rust, including PIN pairing, wrong and abandoned tries, expiry, and a PIN-approved key connecting over loopback; the native input, media and session suites, including the Swift PIN wrappers over loopback; encrypted loopback streaming; the packaged CLI; and the app build. Bonjour discovery, the Local Network prompt and PIN pairing between real Macs remain separate acceptance checks.

Use **Check for Updates…** on each Mac, or download the ZIP. Updates install while idle. Apple silicon and macOS 14 or later; Developer ID signed, notarized and stapled. All tests, builds, signing and packaging run on the local Mac. GitHub Actions remains disabled.
