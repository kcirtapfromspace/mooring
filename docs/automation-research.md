# Apple Screen Sharing automation evidence

Inspected 2026-09-28: macOS 26.6.2 (25G83), Screen Sharing 6.1 (764.2). This is a compatibility investigation, not proof of a successful remote session. No saved connection database, credentials, user preferences, or active session was changed during this investigation.

## Concrete mode request

Apple's installed app **generates mode-bearing VNC URLs itself** when exporting a connection. This improves on the earlier `GetURL`-only finding: the public scripting dictionary still exposes no mode argument, but static disassembly establishes an undocumented native URL format.

The exact generated queries are:

| Intended connection | Query |
| --- | --- |
| High Performance, one virtual display | `quality=high&numVirtualDisplays=1` |
| High Performance, two virtual displays | `quality=high&numVirtualDisplays=2` |
| Standard, adaptive quality | `quality=adaptive&numVirtualDisplays=0` |
| Standard, full quality | `quality=full&numVirtualDisplays=0` |

MacLink implements only one virtual display for High Performance and the adaptive variant for Standard. It validates the host separately and appends a fixed query selected by a Rust enum. User-provided URLs, query parameters, usernames, and passwords remain rejected.

This is an **experimental compatibility adapter**, not a documented Apple API. It requests a mode for a new connection; it does not prove the mode was negotiated or turn an existing session into a different session in place. Apple may reuse a session, reject High Performance, or ask the user to make a choice. Actual mode changes require cross-Mac validation and independently observed results.

### Reproducible static evidence

The binary is `/System/Applications/Utilities/Screen Sharing.app/Contents/MacOS/Screen Sharing`. Inspect it without launching it:

```sh
xcrun llvm-objdump --macho --arch=x86_64 --disassemble --symbolize-operands \
  '/System/Applications/Utilities/Screen Sharing.app/Contents/MacOS/Screen Sharing'
```

In this binary's x86_64 slice:

- `0x100010ebd–0x100010ee2` appends `?%@=%@&%@=%d`, with `quality`, `high`, and `numVirtualDisplays` as the format arguments.
- `0x100010f3f–0x100010f93` chooses `full` or `adaptive` and appends `?%@=%@&%@=0` with `quality` and `numVirtualDisplays`.
- `0x100010fbe–0x100010fed` stores the result under the property-list `URL` key and invokes `writeDictionary:toFileWithHiddenExtension:`.

The arm64e slice corroborates this at `0x10000f008–0x10000f138`: it reads restoration `quality` and `displayType`, and emits the high/virtual or adaptive/full/zero-display query. Separate Swift configuration code logs `Switching displayType to compatibilityMode` and `Switching displayType to virtualDisplays`; the latter sets its quality value to 5.

The app imports the private framework class `SSConnectionOptions`, and its launch path passes options to `connectToURL:withOptions:`. The framework implements part of URL parsing. The export path proves these are real Apple-generated parameters; static inspection alone does **not** establish precedence over a remembered connection, remote compatibility, or successful Standard negotiation. In particular, `quality=adaptive` by itself is a quality setting; the zero virtual-display parameter is part of the native Standard-style export and must not be omitted.

## Public interfaces and saved connections

The bundled `ScreenSharing.sdef` defines only `GetURL` with a text VNC URL. `Info.plist` registers VNC URLs and `.vncloc` files. No public full-screen URL parameter or saved-connection-ID URL scheme was found.

Apple documents that a successful connection is saved, and that a user-created connection's Screen Sharing Type can be edited in Window → Connections → All Connections → Info. [Connection settings](https://support.apple.com/en-sa/guide/mac-help/mchl67d5398b/mac), [connection persistence](https://support.apple.com/en-il/guide/mac-help/mchl89584923/mac).

Static strings identify a private `com.apple.screensharing.configuration` domain, `UserDefaultsBackedKeyValueStorage`, connection/session metadata, and `displayConfiguration`. These are not a supported persistence API. MacLink must not edit Apple's stored connection dictionaries or manufacture private saved IDs. An app-owned, credential-free `.vncloc` can carry a native-generated URL, but whether Apple preserves that document's identity on the resulting window still needs a live test.

Apple's supported device-management declarations offer `Virtual1` and `Virtual2`, not an ordinary application's per-launch mode setter. [Display configuration declaration](https://developer.apple.com/documentation/devicemanagement/screensharingconnectiondisplayconfigurationobject). Enrollment is not part of this consumer workflow.

## Safe session ownership and full screen

Accessibility is the practical public mechanism for observing and operating another application's windows. The app needs user-granted Accessibility access; use an AX client in the signed MacLink app, bounded messaging timeouts, and state-based actions. [Apple AX API](https://developer.apple.com/documentation/applicationservices/axuielement_h).

Do not identify an owned session only by a new window appearing. Another connection can appear concurrently. Require a unique correlation to the requested endpoint and retain the AX window identity for that one session. If correlation is absent or ambiguous, stop automatic closing/switching and request user attention. Never close every Screen Sharing window or terminate Screen Sharing to switch modes.

Useful static evidence and limits:

- The session-window proxy path invokes `writeVNCFileToPath:alwaysWriteFile:`, converts the resulting `.vncloc` path with `fileURLWithPath:`, and calls `setRepresentedURL:` (`0x1000049cd–0x100004a7e`, x86_64). Consequently, `AXDocument`, if exposed, may contain a local file URL rather than a VNC endpoint. Do not assume it is a host URL.
- English `ScreenSharing.loctable` defines subtitles `Display %lu` and `Locked, Display %lu`. These do not uniquely identify a host.
- No stable, endpoint-bearing session-window AX identifier was confirmed by static inspection. Observe the real accessibility tree before declaring an automatic ownership strategy verified.
- `Switch to Hardware Display` and `Switch to Virtual Display` occur in resources. They describe display selection; they must not be treated as a confirmed Standard/High Performance switch.
- Public SDK headers define `AXFullScreenButton`. Runtime `AXFullScreen` support must be queried before setting it; read the value first to avoid toggling an already-fullscreen window. A verified local View → Enter Full Screen menu action is another candidate. Never send a global keyboard shortcut into a remote desktop to control the local viewer.
- Authentication or connection sheets are not session windows. Wait for the owned session and completed connection; do not type credentials or approve unexpected connection/security dialogs.

## Home/travel policy

SSID and RFC1918 addresses cannot establish that this user's path is local: Ubiquiti extension, subnet routes, Tailscale, and WireGuard can preserve familiar addressing away from home. Evaluate the actual resolved target route and repeated measurements. A tunnel interface is evidence of a tunnel, not proof of poor performance; a low TCP-connect time is evidence of low handshake latency, not available video bandwidth.

Use hysteresis and minimum residence times. Evaluate before connecting; re-evaluate after network changes and sleep/wake. An automatic mid-session mode change is a disconnect/reconnect action and must be limited to a positively owned session. Preserve the user's manual choice, and avoid oscillation or reconnecting during authentication. Show requested mode separately from observed mode until read-back is proven.

## Validation still required

On the user's two authorized test Macs, test both URLs from a fresh connection and from opposite remembered modes; confirm real screen-sharing type and physical/virtual display behavior. Test Apple reusing an existing session, unavailable High Performance, simultaneous unrelated sessions, localized UI, full-screen already active, authentication delays, Accessibility denial/revocation, and network transitions. Confirm that Standard uses physical display behavior and that fallback does not unexpectedly expose the remote desktop after a private virtual-display session.

Current unit tests prove safe URL construction, exact query spelling, fixed display count, host rejection, and launch timeout behavior. They do not prove Apple honors these mode requests on any particular remote Mac or macOS release.
