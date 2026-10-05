# Mooring 0.3.0 preview 6 — Automatic updates

This is the last version you install by hand. From now on Mooring updates itself in place.

## How it works

- **Checks:** every four hours, and at launch, Mooring reads the update feed at [kcirtapfromspace/mooring-releases](https://github.com/kcirtapfromspace/mooring-releases).
- **Download:** a newer version downloads in the background and is verified before anything is installed. The feed and the archive must each carry a valid signature from the Mooring release key, and the new app must be signed by the same Developer ID team.
- **Install:** the update installs and Mooring relaunches only while no session is connected. That means no connect or reconnect under way, and sharing, if on, is set to resume automatically. Settings, pairings and the Keychain are kept, and automatic sharing starts again after the relaunch.
- **Menu:** the menu bar shows **Check for Updates…**, or **Install Update … & Relaunch** when one is waiting.
- **Version mismatch:** if a connection fails because the other Mac runs a different version, Mooring checks for an update right away.

Development builds never update themselves. The updater is [Sparkle](https://sparkle-project.org) 2.10.0 (MIT). It is embedded for Apple silicon only, and its license is included in the app.

## Install this version

Install preview 6 on both Macs, the same way as before. The connection protocol is unchanged from preview 4, so it still connects to previews 4 and 5.

## Validation

- Local validation passed with 153 Rust tests and every native Swift suite.
- A new end-to-end check ran on this Mac over loopback only. An installed copy found a newer build in a signed local feed, then verified, installed and relaunched it in place within 3 seconds of launch.
- The same check confirmed that an archive changed after signing and a feed changed after signing were both refused.
- An update from the public feed between your two Macs has not yet been observed. The first real one will be the next release.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
