# Mooring identity

**Mooring · Your Macs, within reach.**

The Threshold mark brings two places into reach. The name suggests a dependable place to return. Use these ideas in the identity; use literal verbs in controls. “Pair” establishes trust, “Connect” begins a session, “Share” grants access, and “Return” brings an existing session forward.

## Mark and color

The approved [brand kit](brand-pivot/README.md) uses the exact Threshold silhouette. Marigold `#FFD447` and coral `#FF5277` sit on graphite `#242726`. Turquoise `#1CC9B7` supports the identity; small text and symbols use a darker teal in light appearance for contrast. Light windows use a subtle blush; dark windows use graphite. Primary buttons use graphite text on marigold. macOS supplies semantic selection, warning, error, checkbox, and focus colors.

`app/MooringBrand.swift` renders the same geometry for all app icon sizes and the monochrome menu-bar template. `scripts/render-brand.swift` renders the iconset at build time.

## Words and hierarchy

Lead with the Mac and its next action. Keep the list visible. Pairing uses a code; Apple Screen Sharing uses an address. Name those choices directly. The empty state has one pairing action, an address alternative, and sharing in the top bar. A selected, live native session uses “Return.” A saved Mac uses “Connect.”

Connection explanations sit behind Details. Errors expand details automatically and remain available for keyboard and assistive-technology users. A reachability check does not establish a live session. Use “Ready,” “Connecting…,” and explicit error states according to actual behavior.

Pairing and sharing screens give short, ordered instructions. Keep code privacy, the scope of control, and continued sharing after a window closes explicit. Pairing codes stay in secure text fields. Address and port overrides stay behind disclosures. Settings retains Sharing, Viewing, and General with immediate changes, existing permission boundaries, and scrollable device lists.

Use the native system font and standard keyboard navigation. Avoid making action labels poetic. Meaning belongs in a few durable phrases; operational words should tell people exactly what happens.

## Compatibility and validation

Use Mooring throughout the app, CLI, source, packaging, and release copy. Keep the existing bundle identifier, signing key, Keychain services, saved-data directory for existing installations, and protocol wire constants stable so updates and paired Macs remain compatible. These identifiers are compatibility details, not product names.

Run `./scripts/ci-local.sh` on this Apple silicon Mac. Inspect empty and populated states, Details, errors, pairing, sharing, settings, and light/dark appearance. UI review images use synthetic Macs and stay outside tracked source. Local tests and development builds do not replace notarized-download and real two-Mac release checks.
