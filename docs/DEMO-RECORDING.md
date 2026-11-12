# Clean Mooring recordings

Keep separate scenes for Mac-to-Mac, Omarchy/Hyprland, and X11 Linux. The main public video is a feature edit of older Mac recordings. The Linux clips were captured from real OS sessions on November 12, 2026.

## Current platform status

As checked against the public release on November 12, 2026, preview 45 includes Mac-to-Mac and Omarchy/Hyprland through wayvnc over SSH. X11 compatibility and Tight/JPEG decoding are present as uncommitted work in the separate X11 checkout, with a local development build. Label X11 footage **Development build — not in preview 45** until a public release includes it. Do not put a download CTA beside that footage that implies preview 45 includes these X11 changes.

## Workspace

Use the normal OS and ordinary applications. The user explicitly rejected a fictional demo workspace. Use an empty workspace or an opaque application window that covers background work; preserve existing windows and connections. Do not use replacement desktop images, browser fixtures or a special clone of Mooring.

On the Mac, enable **Hide computer information for demos** in the normal Mooring app. Never copy a personal connection store, pairing keys or Keychain items into the repository. Privacy mode does not hide the contents of the remote desktop. The current mode may substitute generic Mac labels even for Linux targets; use an editorial platform caption rather than exposing a real endpoint.

Connect and complete any authentication before recording. Keep credential prompts, pairing PINs, network menus, system settings and notifications out of the shot. Use a neutral terminal title and prompt, with history disabled. Show only commands whose output is safe, such as `uname -sr` and `/etc/os-release`. Do not record personal clipboard contents.

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
| Omarchy / Hyprland | 24 s | Start connected on the real desktop; open the normal terminal, run `uname -sr` and `uptime -p`, then return to the desktop. Installed Mooring build 50. |
| X11 / Ubuntu | 18 s | Start connected with an opaque normal terminal covering background work; run `uname -sr` and `cat /etc/os-release`; leave full screen using Mooring's window controls. Local development build 50, not preview 45. |

Mac-only clipboard, audio and gestures must not be implied to work on Linux by reusing those captions over Linux footage. Use the same framing, type, background and closing card across films. Any accelerated footage must say so; keep interaction proof at recorded speed.

Render the reviewed Linux takes outside Git before final review:

```sh
uv run --no-project --with pillow python scripts/render-linux-demos.py \
  --omarchy-source /path/outside/repo/omarchy-raw.mp4 \
  --x11-source /path/outside/repo/x11-raw.mp4 \
  --output-directory /path/outside/repo/edited
```

The edit retains recorded speed, removes idle tails, adds a platform/build caption over the diagnostic area, and produces silent H.264 films with fast-start metadata and matching posters. It does not imply that these short keyboard-input scenes test clipboard, audio, system shortcuts or performance.

## Before publication

Watch the complete take, including the first and last frames and every transition. Inspect frames around entering and leaving full screen and disconnecting. Reject any take revealing another window, real name, email, host, address, account, notification or credential. Cropping and masks are a final edit safeguard, not a substitute for a clean recording session.

Raw takes and review images remain outside tracked source. Only the edited, privacy-reviewed final videos and posters belong in `site/assets/`, under the repository's approved demo exception. Encode H.264 at 1440×900, no audio for silent films, with fast-start metadata; verify the actual output and distinguish released features from development footage. Do not publish the new film until the scenes exist and have passed review.
