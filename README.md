# MacLink releases

Notarized builds of MacLink for Apple silicon Macs (macOS 14 or later), plus the update feed that installed copies follow. The source is kept elsewhere; this repository holds release files only.

## Install

Download the newest `MacLink-…-macos-arm64.zip` from [Releases](https://github.com/kcirtapfromspace/maclink-releases/releases/latest). Check it with `shasum -a 256 -c SHA256SUMS.txt`, then move `MacLink.app` to Applications. Every build is Developer ID signed, notarized and stapled.

## Updates

After that, MacLink updates itself in place. Every four hours it reads `appcast.xml` from the latest release. It installs a new version only if all of these hold:

- the feed carries a valid EdDSA signature;
- the archive matches its own EdDSA signature;
- the new app is signed by the same Developer ID team.

It installs and relaunches only while no MacLink session is connected. Settings, pairings and automatic sharing are kept.

## License

MacLink is MIT licensed. Third-party notices, including Sparkle's, are inside the app under `Contents/Resources`.
