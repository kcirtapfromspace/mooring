# MacLink identity

![MacLink cobalt connection icon](../app/Assets/MacLink.png)

**MacLink** · **Your Macs, within reach.**

MacLink combines a bold identity with a focused native macOS interface. Use direct language about connecting, viewing, controlling, and sharing. Describe actual state: “Sharing is off”, “Connecting…”, or “Session ended”. Reserve “connected” for a live session; a saved Mac or a successful reachability check is not a live session.

## Mark and color

The mark combines two opposed angular paths with a central bridge, representing a connection in both directions. A white mark on a solid cobalt tile appears in the Dock, Cmd+Tab, Finder, About panel, and window headers. Keep the mark geometric, with square ends and consistent stroke weight. The menu bar uses the same geometry as a monochrome template so macOS supplies the correct contrast.

| Role | Color |
| --- | --- |
| Primary action / light appearance accent | `#214FCC` |
| Dark appearance symbols and small labels | `#88AAFF` |
| Icon tile | `#214FCC` |
| Icon mark | `#FFFFFF` |
| Text and window surfaces | Native macOS semantic colors |

Keep white button text on the darker cobalt fill in either appearance. Use system colors for errors, focus rings, selection, and checkboxes. Color always accompanies text or a recognizable symbol.

`app/MacLinkBrand.swift` is the canonical mark and palette. `scripts/render-brand.swift` renders all ten standard macOS icon representations at build time. `scripts/build-app.sh` assembles `MacLink.icns` and embeds it before signing. No downloaded fonts, icon packages, or external artwork are required.

## Native interface

Use the system font: semibold for headings and primary actions, medium for saved Mac names, regular for explanations, and monospaced digits for live telemetry. Window headers use the mark at 48 points; the connection window uses a compact sidebar identity and a larger empty-state mark.

Keep the saved Mac list visible alongside the selected Mac. Separate MacLink pairing from Apple Screen Sharing by name and explanation. Put pairing and sharing in the Connections window as well as the menu bar. Empty lists give a usable next step. Optional address and port controls stay behind disclosure buttons. Pairing codes remain secure text fields, and invalid input produces an inline error.

Settings uses Sharing, Viewing, and General categories. General opens the existing Apple Screen Sharing automation preferences. Sharing and Settings use scrollable content so long explanations and saved-device lists remain reachable. Native keyboard focus, Return, Escape, window controls, and standard menus remain available.

MacLink uses regular application activation and `LSUIElement=false` to participate in Cmd+Tab and the Dock. Closing the last window keeps sharing and automation alive. Clicking the Dock icon when all windows are closed reopens Connections; Open Connections restores a minimized window. Quitting explicitly stops the app's sessions.

## Review

Run `./scripts/ci-local.sh` locally on Apple silicon. Inspect light and dark appearances, the empty list, long saved names, both connection types, pairing validation, address disclosure, Add Mac, the three settings categories, and the sharing window. Verify the icon in Finder, the Dock, and Cmd+Tab, and reopen Connections after closing or minimizing its window.

Use an isolated `MACLINK_HOME` and `MACLINK_DEFAULTS_SUITE` for UI checks. Keep captured screens outside tracked source. A local presentation check does not replace notarized-download verification or the real two-Mac release gate.
