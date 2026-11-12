# Clean Mooring recordings

Show Mooring's actual Mac-to-Linux workflow, with separate Omarchy/Hyprland and X11 films. The terminal-only clips were retired on November 12, 2026: they demonstrated text input but did not explain the product. The main public Mac video remains the earlier feature edit. A private 29-second Omarchy GUI framing draft exists; the X11 graphical scene is prepared, with the final mouse-driven take pending.

## What the film must establish

1. Start in Mooring on the Mac. Select a saved Linux desktop and show Connect.
2. Show the real graphical Linux desktop **inside Mooring's native Mac window**. Keep its title bar and window controls visible long enough to establish the relationship.
3. Use an ordinary graphical app: open it, edit a blank document, browse a clean folder, or move its window. Terminal commands are not the central demonstration.
4. Use Mooring's own full-screen control, then return to its Mac window.
5. End the view from Mooring. Keep authentication, private endpoints and personal work out of the final edit.

Editorial crops may explain a detail after the whole viewer has been established. Do not crop away the Mac context for the entire film. Never portray an app launched through a setup script as a mouse action performed through Mooring.

## Current platform status

As checked against the public release on November 12, 2026, preview 45 includes Mac-to-Mac and Omarchy/Hyprland through wayvnc over SSH. X11 compatibility and Tight/JPEG decoding are present as uncommitted work in the separate X11 checkout, with a local development build. Label X11 footage **Development build — not in preview 45** until a public release includes it. Do not put a download CTA beside that footage that implies preview 45 includes these X11 changes.

## Workspace

Use the normal OS and ordinary applications. The user explicitly rejected a fictional demo workspace. Use an empty workspace or an opaque application window that covers background work; preserve existing windows and connections. Do not use replacement desktop images, browser fixtures or a special clone of Mooring.

On the Mac, enable **Hide computer information for demos** in the normal Mooring app. Never copy a personal connection store, pairing keys or Keychain items into the repository. Privacy mode does not hide the contents of the remote desktop. The current mode may substitute generic Mac labels even for Linux targets; use an editorial platform caption rather than exposing a real endpoint.

Capture connection selection separately from authentication. Complete sign-in before recording the viewer. Keep credential prompts, pairing PINs, network menus, system settings and notifications out of the shot. Use a blank graphical document or a clean folder containing only recording material. Do not open personal recent-file views or record personal clipboard contents.

The current automation can type into the remote app and operate Mooring's native controls, but remote clicks, modifiers and function keys are unreliable through it. Capture a person driving the mouse for app opening and window movement. Keep the recording ready before asking the person to act; do not replace genuine interactions with externally injected actions or alter the application to fabricate a better demonstration.

## Capture one window

`scripts/record-demo-window.swift` uses ScreenCaptureKit's independent-window filter. It accepts only an explicitly selected Mooring window ID, captures no audio, never falls back to a whole display, and records for at most 60 seconds. Its window list omits titles so real host names are not printed. Keep the remote workspace clean: filtering the Mac window does not sanitize the remote picture.

Build on this Apple silicon Mac:

```sh
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  scripts/record-demo-window.swift -o /tmp/mooring-record-window
/tmp/mooring-record-window check
/tmp/mooring-record-window list
```

After inspecting the exact window and confirming the scene is clean, record to an untracked location outside the repository:

```sh
/tmp/mooring-record-window record WINDOW_ID 30 /path/outside/repo/omarchy-raw.mp4
```

Screen Recording permission was granted by the user on November 12. `check` only reads permission state; `request-access` explicitly opens the macOS permission request. The recorder was validated with live terminal changes: the final Omarchy take received 1,322 complete samples and the X11 take received 302, both with zero encoder drops. These are capture counters, not remote-desktop FPS claims.

The command initializes AppKit without opening a window. Frame reordering is disabled and the capture queue holds six surfaces to avoid the encoder retaining all available surfaces. The last frame is extended to the actual stop time so a still desktop keeps its elapsed duration.

For full-screen/notch proof, first verify that macOS still identifies the same capture window after the transition. If it does not, end the take and select the new viewer window. Never substitute display capture. Record a short second take for the full-screen state if needed.

## Shot list

| Film | Length | Actual actions to record |
| --- | --- | --- |
| Mac-to-Mac | 35–45 s | Use ordinary apps with blank documents and neutral text; show a supported gesture and full screen. Show PIN setup only in a separate cropped take with live codes masked. The existing public Mac edit remains available; a new Mac session was not captured in this recording run. |
| Omarchy / Hyprland | 25–35 s | Mooring connection selection; the real graphical desktop in its Mac window; ordinary Files/Writer interaction; Mooring full screen and back. Installed build 50. |
| X11 / Ubuntu | 25–35 s | The same Mac-to-Linux sequence, using the normal Ubuntu file manager and text editor. Preserve personal windows underneath the clean recording apps. Local development build 50, not preview 45. |

Mac-only clipboard, audio and gestures must not be implied to work on Linux by reusing those captions over Linux footage. Use the same framing, type, background and closing card across films. Any accelerated footage must say so; keep interaction proof at recorded speed.

Render the reviewed Linux takes outside Git before final review:

```sh
uv run --no-project --with pillow python scripts/render-product-demo.py \
  --connections-source /path/outside/repo/connections-raw.mp4 \
  --desktop-source /path/outside/repo/graphical-desktop-raw.mp4 \
  --plan /path/outside/repo/reviewed-scenes.json \
  --platform 'Omarchy / Hyprland' --status 'Installed build 50' \
  --output /path/outside/repo/edited/omarchy-product-demo.mp4
```

The scene plan is a JSON array. Each entry gives `source` (`connections` or `desktop`), `start`, `duration`, and `heading`; optional `crop` is `[width, height, x, y]` in the 1440×900 capture. `hide_connection_details` hides the endpoint/DNS portion of the connection screen while preserving its actual controls. Verify mask placement against the specific take.

The editor retains recorded speed, labels the Mac-to-Linux relationship and build, and produces silent H.264 films with fast-start metadata and matching posters. Keep drafts private until both the privacy review and the product story pass. These scenes do not establish clipboard, audio, system-shortcut or performance claims.

## Before publication

Watch the complete take, including the first and last frames and every transition. Inspect frames around entering and leaving full screen and disconnecting. Reject any take revealing another window, real name, email, host, address, account, notification or credential. Cropping and masks are a final edit safeguard, not a substitute for a clean recording session.

Raw takes and review images remain outside tracked source. Only the edited, privacy-reviewed final videos and posters belong in `site/assets/`, under the repository's approved demo exception. Encode H.264 at 1440×900, no audio for silent films, with fast-start metadata; verify the actual output and distinguish released features from development footage. Do not publish the new film until the scenes exist and have passed review.
