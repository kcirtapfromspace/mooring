# Mooring 0.3.0 preview 37 — One home

Mooring's source, releases, and signed update feed now share one public [GitHub repository](https://github.com/kcirtapfromspace/mooring). The [Mooring website](https://kcirtapfromspace.github.io/mooring/) introduces the app and links to the latest preview and source.

This preview switches installed apps to the consolidated update channel. Existing release URLs redirect to the same repository, allowing older installations to reach this update. The Developer ID, Sparkle signing key, bundle identifier, preferences, saved Macs, and pairing identities remain compatible.

The static website is prepared and reviewed locally, then served by GitHub Pages with Actions disabled. Builds, tests, signing, and packaging continue to run on the local Apple silicon Mac.

Local validation covers Rust, native media and input, encrypted loopback streaming, the packaged CLI, and app build. The isolated updater test checks the previous app, redirect migration, installation and relaunch, and refusal of tampered archives and altered feeds. Downloaded-app behavior, permissions, and real two-Mac checks remain separate acceptance tests. Native sessions remain experimental.
