# MacLink 0.3.0 preview 20 — A key for each Mac

Installed copies of preview 6 or later update to this version by themselves when no session is connected. Update both Macs before pairing a new one: earlier versions can't read the new pairing codes.

## What changes

Until now, every Mac you paired used the same secret, copied from the sharing Mac in its pairing code. Anyone with that code could connect until you reset pairing, and a reset cut off every Mac at once.

Now each viewing Mac has its own key, kept in its Keychain, and the sharing Mac keeps a list of the Macs it approved:

- **Pairing codes work once.** **Copy Pairing Code** makes a code that pairs one Mac, within 10 minutes, while sharing stays on. Copying another code replaces an unused one. A code that leaked after use, or sat in a chat, lets no one in.
- **You can see and remove each Mac.** On the sharing Mac, **Settings → Sharing this Mac → Macs that can connect to this Mac** lists each approved Mac by name, when it paired and when it last connected. **Remove…** stops that Mac from connecting until it pairs again, and ends its session now if it's connected.
- **Reset Pairing** still starts over: no Mac can connect until it pairs again.

## Existing pairings move over by themselves

You don't need to pair again. With both Macs on preview 20, the next time a paired Mac connects, it uses the old code one last time to get its own key approved, and saves the new pairing in its Keychain. It then shows up in the sharing Mac's list.

The old code keeps working for a week after the first Mac moves over, so every Mac paired the old way can follow. The Settings row for it shows when it stops and when it was last used. **Stop Now…** ends it early, and disconnects a Mac still using it. **Another Week** gives stragglers more time. Once it has stopped, a Mac that didn't move over needs a new code.

During that week, a Mac holding the old code can still get its own key approved, at most eight in all. Check that every Mac in the list is yours, and remove any you don't recognize.

A sharing Mac set up fresh on preview 20, or after **Reset Pairing**, never accepts the old kind of code.

## If a connection is refused

A sharing Mac that doesn't accept a Mac closes the connection without saying why, so nothing can probe it. The viewing Mac says what it knows:

- **A pasted code:** it was used, it expired, or a newer one replaced it. Copy a new code.
- **A saved pairing:** the Mac was removed on the sharing Mac, or the sharing Mac's pairing was reset. Pair again. Reconnecting stops, rather than retrying.

A connection dropped at exactly that moment reads the same way. If you didn't remove the Mac, click **Reconnect**.

## How it works

The handshake is Noise IK: the viewing Mac proves its own key, and the sharing Mac refuses an unknown key before it answers. Pairing and moving over use Noise IKpsk1, which also mixes in the one-time or old secret, so a wrong code is refused on the first message. The sharing Mac records an approval only after the viewing Mac proves fresh session keys, and before its last answer. So a Mac that finished connecting was approved, and a failed attempt approves no one and doesn't use up the code.

The list holds public keys and names only, never a secret, in `native-devices.json` in MacLink's Application Support folder. It's owner-only, and holds at most 32 Macs.

## Validation

Local validation passed with 139 Rust session tests and the native suites. The pairing tests run over loopback:

- Pairing with a one-time code, then connecting with the saved pairing.
- A used, replaced, guessed or expired code, a removed Mac, and a copied pairing on another Mac's key, each refused before the sharing Mac answers.
- An old viewer with the old code, until the sharing Mac stops accepting it.
- Moving an old pairing over once.
- Falling back to the old handshake with a sharing Mac on an earlier version.
- The mode can't be changed in transit.
- Reset Pairing approves no one.

Two mutation checks confirmed the tests catch a mode that isn't bound into the handshake and a code that never expires. The Swift session suite pairs over loopback with a temporary list, never the real one.

A security-focused review of the change ran before release. It found nothing critical or high, and these fixes went in:

- A move-over the sharing Mac already answered no longer falls back to the old handshake if the connection drops. The viewing Mac keeps what was approved.
- A Mac removed, or an old code stopped, while a connection was still being set up is turned away before its session starts.
- Moving over checks, at the moment of approval, that the old code is still accepted.
- A lost list never reopens the old code, since the sharing Mac's identity notes that it keeps one.
- **Another Week** can't revive an old code that already stopped, and Settings says when it stopped.
- A full disk no longer turns away an approved Mac.

The Settings section was rendered off-screen in light and dark appearance.

Moving over between two real Macs is the first check to run after both update. See TESTING.md.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
