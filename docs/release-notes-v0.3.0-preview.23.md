# MacLink 0.3.0 preview 23 — Reach your Mac from anywhere you can reach it

Installed copies of preview 6 or later update to this version by themselves when no session is connected. Update both Macs before pairing anew: earlier versions can't read the new pairing codes.

## What went wrong

Away from home, MacLink on the MacBook said "Operation timed out" while Apple Screen Sharing connected fine. A pairing code carried one address, the Mac Studio's local name `thinkstudio.local`, which only resolves on the home network. Screen Sharing was reaching the Mac Studio over Tailscale. MacLink never tried that route, and its attempts never reached the Mac Studio at all.

## What changes

- **Pairing codes list every address of the sharing Mac:** its local name, its IP address on the home network, and its addresses on tunnels such as Tailscale or another VPN. At most eight in all.
- **The viewing Mac tries them all at once:**
  - It starts with the address that worked last time, then the others a fifth of a second apart.
  - The first that completes the secure handshake wins.
  - An address that leads to some other machine, or nowhere, doesn't hold up the rest. Each gets at most 2 seconds while others are waiting.
- **The address that connected is tried first next time.** At home that's usually the local name or the home IP; away, the VPN address.
- **"Refused" means refused.** The viewing Mac stops reconnecting and asks you to pair again only when every address that answered refused it. One stale address that leads elsewhere no longer reads as being removed.

Settings shows each paired Mac's main address, and how many others it has; hover to see them all. The **Address** field in **Connect with MacLink** is now rarely needed. An address typed there is tried first, along with the code's own.

## Your existing pairing

A Mac paired before preview 23 knows only the address it paired with. To give it the full list, pair it once more with a new code from the sharing Mac, after both Macs have preview 23. From away from home, copy the code through Screen Sharing, as before.

## Validation

Local validation passed with the full suite, including 150 Rust session tests. Over loopback, with the sharing Mac on one address and a stand-in on another:

- **A stand-in that never answers:** the real Mac still connects within the time limit.
- **A stand-in that closes at once:** no refusal is reported.
- **Every address refuses:** a refusal.
- **No address answers:** not a refusal.
- **An older sharing Mac:** moving over falls back on the address that reached it.

Three mutations were caught:
- every handshake waiting out the whole time limit;
- a stand-in's close ending the attempt;
- an address that waited its turn being used without reconnecting.

The last is needed because a sharing Mac drops a connection that stays idle for about a second.

This Mac Studio lists `thinkstudio.local`, `192.168.25.201` and `100.122.9.8`. Connecting from away over Tailscale is checked between the two Macs: step 3 in TESTING.md.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
