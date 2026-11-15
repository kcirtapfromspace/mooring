# Mooring launch materials

## Direction

**Your Macs, within reach.** Use the Mac at your desk from the Mac in your bag.

Start with people who use a MacBook to reach another desktop. Show both Mac-to-Mac work and Linux: Omarchy/Hyprland is in the public preview, while the X11 implementation is currently local development work. Use separate, clearly labeled films for each platform. Clipboard, sound and trackpad-gesture claims belong to the Mac-to-Mac film. The full-screen notch detail is one visual hook, not the whole product story.

The [recording brief](DEMO-RECORDING.md) requires the normal OS and ordinary graphical apps, with Mooring’s Mac window and connection workflow clearly visible. The terminal-only Linux clips were retired on November 12: they showed input but did not explain the product. A private Omarchy GUI framing draft has been rendered, and a clean X11 graphical scene is prepared. The final app-opening and window-movement take needs real mouse input because the automation does not reliably forward remote clicks. The main public Mac video remains the original 30-second feature edit.

## What to take from FileOctopus

Reviewed November 9, 2026: the [r/macapps introduction](https://www.reddit.com/r/macapps/comments/1xccw6r/fileoctopus_a_file_manager_that_works_like_finder/) and the [current website](https://www.fileoctopus.com/), including its 146-second film.

| Observed pattern | Mooring's application |
| --- | --- |
| The post names a familiar workflow, then a specific frustration. | Explain using a desktop Mac from a laptop before discussing the engine. |
| The site pairs short benefit statements with visible actions. | Show the notch before/after and remote menus; give each shot one caption. |
| Download, compatibility and commercial terms are easy to find. | Put the free preview, Apple silicon, macOS requirement and notarization together. |
| The post states missing features and ends with a focused question. | Explain the VPN requirement and preview status; ask what breaks the reader's workflow. |

These are positioning and presentation observations. The public pages do not establish which element caused downloads or purchases. The current website includes later features and social proof that were not present in the original launch post. Mooring should add customer quotes only after receiving real, attributable feedback. Do not adopt FileOctopus's pricing, customer counts or performance comparisons.

## Delivered demo: 30 seconds

The public file is `site/assets/demo.mp4`. It combines the existing notch before/after recording with the approved earlier sharing recording. It uses the approved Threshold icon, blush background, graphite text and marigold call to action. All captions are burned in, so it works muted. A visual description and VTT description track accompany it on the website.

| Time | Shot | Message |
| --- | --- | --- |
| 0–2 s | Mooring title | Native remote desktop for Mac; free, open-source preview. |
| 2–5 s | Full screen before | The remote desktop stops below the camera. |
| 5–14 s | Full screen after | The remote menu bar and icons make room for the notch. |
| 14–20 s | Menus on both sides | The pointer operates the other Mac's menus. |
| 20–25 s | Connected sharing window | Sharing is explicit; the user can stop it. Earlier UI is labeled. |
| 25–30 s | Download card | Website, platform requirements and preview availability. |

This is a feature demonstration, not a fresh recording of current PIN setup or a latency benchmark. Notch footage runs at its recorded speed. Do not infer measured streaming performance from it. The current release's real two-Mac PIN check remains outstanding in the public notes.

Rebuild locally using a Python environment with Pillow and the Mac's Avenir Next and Palatino fonts:

```sh
python3 scripts/render-demo.py \
  --notch-source /path/to/mooring-notch-demo-cropped.mp4 \
  --sharing-source /path/to/the-original-approved-demo.mp4
```

The second input must be the original 59.3-second setup recording, not the new 30-second output. Source recordings and intermediate frames stay outside Git. Review every shot at full resolution before publication. The output must be H.264, 1440×900, 30 fps, fast-start MP4, no audio, under 5 MB.

## Reddit post draft

Publication status: draft only. No Reddit post or message has been sent.

**Title:** Mooring: reach your other Mac or Omarchy desktop from your MacBook (free, open-source preview)

Hi r/macapps — I'm building Mooring, a native Mac app for reaching another Mac or a Linux desktop.

The idea is simple: use the Mac at your desk from the Mac in your bag, and keep the little things that make it feel like a Mac.

The video shows one of those details. In full screen on a MacBook, the other Mac's menu bar moves up beside the camera notch. Its icons make room, and the menus work on both sides. It's a small thing, but it makes that desktop feel closer.

What is in the preview today:

- A direct, encrypted connection between paired Macs.
- Clipboard sharing in both directions and sound from the other Mac.
- Pinch, rotate and smart zoom, with system shortcuts such as Command-Tab sent to the other Mac once Accessibility is allowed.
- Saved Macs and reconnect behavior, with a separate key for each paired viewing Mac. You can remove access one Mac at a time.

Setup in the current preview uses a six-character PIN: show it on one Mac, choose Pair a Mac on the other, then start sharing and connect. Pairing establishes trust; it doesn't start sharing by itself.

What to know before trying it:

- Apple silicon and macOS 14 or later. Install the current preview on both Macs for PIN pairing.
- Your Macs need a direct network connection. Away from home, bring your own VPN, such as Tailscale. There's no built-in internet relay.
- One Mac viewed at a time and one viewer per sharing Mac.
- This is early software. Reliability testing across real Macs is ongoing, and the current release notes still list real two-Mac PIN pairing as an acceptance check. Keep another way to reach a Mac you depend on.
- The public preview includes experimental Omarchy/Hyprland support through wayvnc over SSH. Large changing desktops currently update slowly. X11 compatibility is in local development, not preview 45; any X11 footage will be labeled as a development build.

The preview is free, the source is MIT-licensed, and no Mooring account is needed. The download is Developer ID signed and notarized.

[Download and demo](https://kcirtapfromspace.github.io/mooring/) · [Source](https://github.com/kcirtapfromspace/mooring) · [Release notes](https://github.com/kcirtapfromspace/mooring/releases/latest)

If you reach another Mac or a Linux desktop from a MacBook, what most often breaks the feeling that you're working on that computer: keyboard shortcuts, display sizing, or something else?

## First launch and follow-up

Check current r/macapps posting rules and the appropriate flair immediately before posting. Attach the MP4 directly so readers can watch inline, with the website link in the body. Post when the developer can answer setup questions. Keep the focus on Mac-to-Mac use and acknowledge alternatives respectfully.

For feedback, ask for Mac model, macOS version, Mooring version, local network versus VPN, and the action that failed. Do not ask people to publish pairing codes or private desktops. Use GitHub issues for reproducible reports.

Before a broader launch, complete the current two-Mac PIN acceptance check and record a 45–60 second daily-use film: pair, connect, type in a blank document in an ordinary app, copy a harmless sentence across Macs, use a trackpad gesture, demonstrate audio if recording sound, then disconnect. Use privacy mode and a clean desktop. The main short film proves the notch detail and sharing state; the replacement Linux films need to establish Mooring’s Mac-to-Linux workflow before showing individual app interactions.

Measure actual release-download counts and useful feedback before and after a post. Release counts are cumulative and include repeat downloads, so they do not establish unique users or conversion rates. Keep the website free of analytics unless that choice changes explicitly.
