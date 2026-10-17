# Experimental Linux host for Mooring

This prototype lets an existing Mac Mooring native viewer pair with a Linux host.
The initial desktop target is **Omarchy/Hyprland**, including ARM64 Linux on Apple
silicon. It is a source build, not a published Linux release. There are no changes
to the existing Mac app or Apple Screen Sharing backend.

## Status and scope

Implemented: one selected output, continuous H.264 video, encrypted one-time
pairing, persistent host identity and approved viewer keys, reconnection with an
approved key, normalized pointer positioning, physical keyboard positions,
mouse buttons, wheel scrolling, ping replies, and authenticated pairing revocation.
One viewer is served at a time. Sharing is foreground-only and starts explicitly.

The baseline uses `wf-recorder` (wlr-screencopy) and software `libx264`, with
access-unit delimiters and a keyframe every second. Raw video remains in a private
FIFO and memory; it is not saved as a recording. The adapter extracts SPS/PPS and
converts Annex B video to the existing Mooring AVCC wire format. Audio, clipboard,
trackpad gestures, hardware encoding, remote login/unlock, suspend/wake support,
virtual displays and adaptive bitrate/tuning are not implemented. The default
encoded size is 1280x720 at 30 FPS; this is configuration, not a measured rate.
Choose a size matching the monitor's aspect ratio to avoid stretching.

Local verification on macOS covers compilation, strict Clippy, workspace tests,
and a synthetic x264 stream crossing the encrypted session, with one-time device
pairing, approved-key reconnect and return input. **A Linux native build and real
Omarchy capture/input have not been verified.** Run the Linux installer and the
hardware checks below before treating this as working remote access. No Linux
binary is provided from the macOS build.

## Build on Omarchy

Extract the supplied source archive into a new directory, or apply the supplied
patch to its recorded upstream base. Run as the logged-in desktop user:

```sh
sudo pacman -S --needed base-devel rust wf-recorder ffmpeg acl
./scripts/install-linux-host.sh
```

Rust 1.89 or newer is required. The installer runs host tests, builds a native
release binary and installs `~/.local/bin/mooring-linux-host`. It does not modify
Hyprland configuration, services, firewall rules or input permissions. Runtime
dependencies are `wf-recorder` built with `libx264`, `hyprctl`, and `/dev/uinput`.
The host does not embed external capture or input implementation code.

Asahi is not necessarily an Arch-based distribution. These `pacman` instructions
are for Omarchy; Fedora Asahi needs equivalent packages and a compositor supporting
wlr-screencopy. GNOME/KDE screen capture is outside this prototype's scope.

## Allow the virtual input device

From the Linux terminal, grant only your desktop account access for this boot:

```sh
sudo modprobe uinput
sudo setfacl -m "u:$(id -un):rw" /dev/uinput
```

Run Mooring as your normal user, **not root**. `/dev/uinput` creates a virtual
keyboard/mouse; the host cannot control Linux without that access. These commands
are explicit machine setup, not something the installer does automatically.
The ACL typically needs repeating after reboot/device recreation. To remove it:

```sh
sudo setfacl -x "u:$(id -un)" /dev/uinput
```

Use `--view-only` to test video without granting input access. In control mode a
failure opening the virtual device ends the session instead of claiming control
works. Destroying the virtual device releases its held keys and buttons, including
when the host exits unexpectedly. The session core additionally filters duplicate
key/button transitions and stages release-all events.

## Start sharing

Run inside the active Omarchy Hyprland session:

```sh
hyprctl monitors
ip -brief address
~/.local/bin/mooring-linux-host --address 192.168.1.50 --output eDP-1
```

Replace the example IP with a Linux address reachable from the viewing Mac, and
`eDP-1` with the actual output name. A VPN address is also possible. `--address`
is advertised in the pairing code; `--bind` selects a local listen address (IPv4
`0.0.0.0` by default). The host uses TCP **45900**, which must be reachable through
the Linux firewall. Use a trusted network or VPN; no public port forwarding is
needed. If using an IPv6-only address, set the appropriate IPv6 `--bind` too.

For a 16:10 panel, for example:

```sh
~/.local/bin/mooring-linux-host --address 192.168.1.50 --output eDP-1 --size 1280x800 --fps 30
```

On the second Mac, open Mooring, choose **Pair a Mac**, and paste the printed code.
The UI still uses Mac-oriented labels. Use Mooring's native paired connection,
rather than adding Linux through Apple Screen Sharing.

The one-time code approves one device and expires after ten minutes. It is printed
only in the local terminal; keep that terminal private and do not save it to shared
logs. Restart the host to issue a fresh code. Existing approved Macs reconnect
without a new code. Ctrl+C ends sharing; no background service is installed.

State is stored in `$XDG_STATE_HOME/mooring` (default `~/.local/state/mooring`),
separately from macOS connections. The folder is 0700; the 96-byte identity file is
0600. The host refuses malformed or non-private identity files rather than silently
replacing them. `--data-dir PATH` selects a separate state directory. The host lock
prevents two processes using the same identity simultaneously. Do not copy identity
or pairing data into a bug report.

Input maps Apple physical key positions to Linux evdev positions: Command becomes
Super, Option becomes Alt, Control stays Control. Linux chooses the keyboard
layout; this does not translate Mac text shortcuts into Linux equivalents. A
monitor layout change terminates streaming; restart the host after changing outputs,
scale, position or rotation. Only the selected active desktop output is shared.

## Hardware acceptance checklist

1. Run the installer on Omarchy and record architecture and Rust version.
2. Pair from the second Mac. Confirm the selected output is visible and its aspect
   ratio is correct. Watch host stderr for encoder/capture errors.
3. Test pointer at all four corners, clicks, dragging, scrolling, letters, Enter,
   Backspace, arrows, Shift, Control, Alt and Super. Confirm physical Linux input
   continues to work. Test the actual Linux keyboard layout.
4. Hold a remote key, disconnect the viewer and confirm it is released. Repeat
   while stopping the host with Ctrl+C. Confirm no wf-recorder child remains.
5. Reconnect the saved Mac without a pairing code; restart the host and reconnect
   again. Confirm an unrelated Mac cannot reuse an already-consumed code.
6. Remove the pairing on the connected Mac. Confirm a new code is needed.
7. Test a still desktop, continuous window movement, 15/30 FPS, and the intended
   Wi-Fi/VPN link. Record CPU use, heat, responsiveness and visual quality.
8. Change scale or disconnect the selected display. Confirm the session ends and
   that input is released. Resume only after restarting sharing for the new layout.

A stalled capture stops after five seconds. Child processes are killed and reaped
on errors/normal shutdown. If power loss or SIGKILL leaves `capture.fifo`, stop all
host processes before removing only that stale FIFO from the state directory.
Do not delete `host.identity` to fix capture: that would invalidate saved pairings.

## Local development checks

```sh
cargo fmt --all -- --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

The H.264 fixture is a generated 64x64 FFmpeg `testsrc2` pattern, not captured screen
content. Its encrypted loopback test exercises the same session engine as the Mac
viewer; it does not establish actual VideoToolbox decoding, Linux input delivery,
network performance or successful two-machine operation.
