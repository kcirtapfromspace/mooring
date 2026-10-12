# Mooring 0.3.0 preview 43 — More than one Mac

Until now, a viewing Mac could in practice reach only the sharing Mac it was showing. While a session was open, **Pair a Mac…** brought that session's window forward instead of opening the pairing form, and choosing another saved Mac in the menu bar or in Connections did the same, though the menu offered to connect to it. Pairing a second Mac meant ending the first session.

The pairing form now opens at any time. While another Mac is on screen, it says that Mac disconnects once the new one connects. That session stays up while the code is tried, so a wrong, used or expired code leaves it running. Once the new Mac connects, the first session ends as if its window were closed, and the new Mac opens. Choosing any saved Mac switches to it the same way, and choosing the Mac on screen returns to it. A choice made while Mooring is reconnecting to a dropped Mac now takes over instead of doing nothing.

Mooring still shows one Mac at a time, and a sharing Mac still takes one viewer at a time: while another Mac is viewing it, a new pairing with it can't finish until that session ends. Only the viewing Mac needs this preview; the protocol is unchanged.

Local validation covers Rust, the native input, media and session suites, encrypted loopback streaming, the packaged CLI and the app build. Pairing a second sharing Mac and switching between them with real Macs remains a separate acceptance check.

Use **Check for Updates…** on each Mac, or download the ZIP. Updates install while idle. Apple silicon and macOS 14 or later; Developer ID signed, notarized and stapled. All tests, builds, signing and packaging run on the local Mac. GitHub Actions remains disabled.
