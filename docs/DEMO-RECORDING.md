# Clean Mooring recordings

Record three separate scenes: Mac-to-Mac, Omarchy/Hyprland, and X11 Linux. The existing public video is a feature edit of older recordings; it is not the new clean-workspace campaign film.

## Current platform status

As checked against the public release on November 9, 2026, preview 45 includes Mac-to-Mac and Omarchy/Hyprland through wayvnc over SSH. X11 compatibility and Tight/JPEG decoding are present as uncommitted work in the separate X11 checkout, with a local development build. Label X11 footage **Development build — not in preview 45** until a public release includes it. Do not put a download CTA beside that footage that implies preview 45 includes these X11 changes.

## Workspace

Use a separate demo session or disposable machine. Do not clean up a personal desktop by closing its work. The local page at `demo/workspace/index.html` contains synthetic text and tasks, no network requests, no accounts, and no persistent storage. Open it in a fresh, unsynchronized browser profile in app mode so there are no tabs, bookmarks, history suggestions, extensions or account avatars. Keep only that window in the remote demo session.

On the Mac, use a separate Mooring configuration (`MOORING_HOME`) and defaults suite (`MOORING_DEFAULTS_SUITE`) with **Hide computer information for demos** enabled. Never copy a personal connection store, pairing keys or Keychain items into the demo repository. Demo mode does not hide the contents of the remote desktop. Use neutral labels such as **Studio Mac**, **Omarchy Desktop**, and **X11 Desktop**; keep real targets in local configuration only. The current privacy mode may substitute generic Mac labels even for Linux targets; use an editorial platform caption rather than exposing a real endpoint.

Connect and complete any authentication before recording. Keep credential prompts, pairing PINs, network menus, system settings, notifications and diagnostics out of the shot. Do not record actual clipboard contents. For a clipboard scene, copy only the synthetic sentence in this page.

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

This process currently does not have Screen Recording permission. No new recording has been captured. The check intentionally stops without requesting or changing permission. Enable recording access for the responsible terminal/app in macOS System Settings and relaunch it before capture. A successful compile is not capture validation.

For full-screen/notch proof, first verify that macOS still identifies the same capture window after the transition. If it does not, end the take and select the new viewer window. Never substitute display capture. Record a short second take for the full-screen state if needed.

## Shot list

| Film | Length | Actual actions to record |
| --- | --- | --- |
| Mac-to-Mac | 35–45 s | Select a saved demo Mac; connect; edit synthetic notes; copy the synthetic sentence between Macs; use one supported trackpad gesture; show full screen; disconnect. Show current PIN setup only in a separate, cropped setup take with all live codes masked in the final edit. |
| Omarchy / Hyprland | 20–25 s | Start already connected; title the platform; type **The other desktop is right here.** in the synthetic document; select text and scroll; show full-screen fit and a remote shortcut; disconnect before showing any local desktop. |
| X11 / Ubuntu | 20–25 s | Start already connected; label the development build; edit the same synthetic document; move its window to demonstrate updates; show screen fit; disconnect. No invented FPS, latency or codec claims. |

Mac-only clipboard, audio and gestures must not be implied to work on Linux by reusing those captions over Linux footage. Use the same framing, type, background and closing card across films. Any accelerated footage must say so; keep interaction proof at recorded speed.

## Before publication

Watch the complete take, including the first and last frames and every transition. Inspect frames around entering and leaving full screen and disconnecting. Reject any take revealing another window, real name, email, host, address, account, notification or credential. Cropping and masks are a final edit safeguard, not a substitute for a clean recording session.

Raw takes and review images remain outside tracked source. Only the edited, privacy-reviewed final videos and posters belong in `site/assets/`, under the repository's approved demo exception. Encode H.264 at 1440×900, no audio for silent films, with fast-start metadata; verify the actual output and distinguish released features from development footage. Do not publish the new film until the scenes exist and have passed review.
