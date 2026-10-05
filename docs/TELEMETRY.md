# Live telemetry and tuning

While a native Mooring session is connected, each Mac sends the other a small measurement record once a second over the encrypted session. Each running app serves the combined view on an owner-only local socket, `telemetry/telemetry.sock` in `~/Library/Application Support/Mooring` (or `MOORING_HOME`); the `telemetry` folder is readable only by you. No network port is opened, and telemetry contains measurements only: no screen content, input, addresses or keys.

Run the bundled CLI on either Mac:

```sh
mooring=/Applications/Mooring.app/Contents/Resources/mooring
"$mooring" telemetry              # one JSON line per second until interrupted
"$mooring" telemetry --count 10   # stop after ten snapshots
"$mooring" tune --bitrate-mbps 15 --max-width 2560
"$mooring" tune --fps 30 --in-flight 1
"$mooring" tune --reset           # restore the defaults
```

Tuning typed on the viewing Mac during a session is sent to the sharing Mac; tuning on the sharing Mac applies there, and without a session it is kept for the next time this Mac shares. Settings last until the sharing Mac's app quits, including across reconnects. Changes apply within about a second; a new maximum width restarts capture at that size, which briefly pauses the picture.

## Snapshot

```json
{"t":42.1,"role":"viewer","tuning":{"bitrate_mbps":25.0,"max_width":3840,"fps":60,"in_flight":2,"keyframe_seconds":0},
 "local":{"received_fps":38.0,"rtt_ms":9.0,...},"peer":{"capture_fps":41.0,"encode_ms":24.5,...},"peer_age_s":0.4,"last_end":null}
```

`role` is `host` (this Mac is sharing), `viewer`, or `idle`. `last_end` is `null`, or `{"reason": …, "age_s": …}`: Mooring's reason for the latest session on this Mac ending and how many seconds ago, so a drop can be diagnosed after the fact. `local` holds this Mac's measurements and `peer` the other Mac's latest, `peer_age_s` seconds old. `tuning` is this Mac's own sharing settings; while viewing, the sharing Mac's settings appear in `peer` as `bitrate_mbps`, `fps_cap` and the capture size. Rates are per second over the last interval.

Sharing Mac:

| Field | Meaning |
|---|---|
| `capture_fps` | Complete frames ScreenCaptureKit delivered. Only screen changes produce frames, up to the `fps` cap. |
| `encoded_fps` | Frames the hardware encoder produced. |
| `skipped_fps` | Captured frames never encoded: a newer frame replaced them while the encoder or the connection was busy. The newest always goes out once they allow (preview 18 and later). |
| `dropped_fps` | Frames the encoder's real-time rate control skipped. |
| `failed_frames`, `keyframes` | Failed frames (each restarts with a keyframe) and keyframes sent in the interval. |
| `encode_ms`, `encode_ms_max` | Average and maximum hardware encode time. |
| `send_ms`, `send_ms_max` | Time to encrypt a frame and hand it to TCP, including waiting for socket space. |
| `sent_mbps`, `frame_kib` | Video sent and average frame size. |
| `in_flight` | Frames encoding or sending right now (at most `in_flight` tuning). |
| `bitrate_mbps`, `fps_cap`, `pixel_width`, `pixel_height` | Settings in effect and the capture size. |
| `capture_ms` | Average time from a screen change reaching this Mac's display to ScreenCaptureKit delivering it (preview 14 and later). |
| `bitrate_mbps` | The bitrate in use: the tuned one, or less while pacing has lowered it (preview 18 and later). |
| `send_queue_kib`, `queue_wait_ms` | Most video held in this Mac's network send buffer in the interval, and milliseconds frames waited for it to drain. This Mac only; not sent to the viewer. |
| `link_mbps` | The link's rate, measured while video waited in the send buffer; present only in seconds when it did. Pacing cuts to three quarters of it, and climbs back to nine tenths of the rate where the link last ran out. This Mac only. |

Viewing Mac:

| Field | Meaning |
|---|---|
| `received_fps`, `received_mbps` | Video arriving. |
| `decode_ms`, `decode_ms_max`, `decoded_fps` | Hardware decode time and rate. |
| `presented_fps` | Frames that reached the display. |
| `rtt_ms` | Ping round trip, including the sharing Mac's send queue. Not display latency. |
| `latency_ms`, `latency_ms_p95` | Median and 95th percentile time from a screen change on the sharing Mac to that frame appearing on this Mac's display, over the last second. Absent when no frame reached the screen in that second, as while the window is hidden (preview 19 and later). Needs preview 14 on both Macs. |
| `to_viewer_ms` | Median part of that until this Mac starts decoding: capture, encode, sending and the network. |
| `display_wait_ms` | Median time from decoded to on screen: queueing for the next display refresh and drawing. |
| `clock_error_ms` | How far off the two Macs' clocks could be placed, half the fastest recent ping round trip. Latency figures are accurate to about this much. |
| `keyframe_requests`, `decoder_overflows` | Recovery requests, and packets discarded because decoding fell behind. |

## Session log

Session starts and ends, reconnect attempts, automatic sharing, tuning changes and shared-clipboard transfers (their kinds and sizes) are also written to the macOS log with Mooring's reason text; never addresses, names, pairing codes, input or screen content:

```sh
/usr/bin/log show --last 2h --style compact --predicate 'subsystem == "dev.mooring"'
```

In zsh, `log` alone is a shell built-in; use `/usr/bin/log`.

## Reading the numbers

- `capture_fps` near zero while nothing moves is normal.
- `skipped_fps` high with `send_ms` high: the network is the limit. Lower `bitrate_mbps` or `max_width`.
- `skipped_fps` high with `encode_ms` above the frame interval (16.7 ms at 60 fps): the encoder is the limit. Lower `max_width`, or `fps`.
- `in_flight 1` versus `2`: two overlaps encoding with sending for throughput; one lowers latency when the link is fast.
- `decoder_overflows` or `presented_fps` below `decoded_fps`: the viewing Mac is the limit.
- Keyframes come only when needed (`keyframe_seconds` 0, the default): at the start, when the screen size changes, and when the viewer asks. Frequent `keyframes` or `keyframe_requests` means recovery. `keyframe_seconds` 1–10 asks for one every N seconds instead. Each costs a burst, which on a slow link means skipped frames.

Bounds: `bitrate_mbps` 1–80, `max_width` 640–3840 and even, `fps` 1–60, `in_flight` 1–2, `keyframe_seconds` 0–10 (0: only when needed). The app validates every command in Rust and replies with an acknowledgement or an error; the socket accepts at most four clients and 1 KiB per command line.

## Viewer stats

In a native viewer, **View → Stats for Nerds** (⌃⌘I) shows streamed measurements over the picture. Receive, decode, presentation and audio events, and arriving peer telemetry, push changes to the overlay. The UI has no repeating refresh timer or socket polling. Bursts are coalesced into at most 10 display updates per second; local frame rates and throughput cover a rolling second. The host still sends the protocol's one-second samples. Two bounded one-shot expiry events clear idle rates and stale host data when producers go quiet, then stop. A disconnect cancels pending deliveries. The overlay also shows the actual received codec, verified hardware decode, viewer size, session totals, and audio buffer/recovery counters. It distinguishes network RTT from synchronized screen-to-display latency and the host's bitrate target from the video rate received here. Host measurements expire after three seconds. **—** means unavailable; zero FPS is valid for a still picture. Audio gaps count packets the host did not send, and decode overflows count recovery events, not a number of dropped frames or network packet loss.

**View → Diagnostic Footer** (⌃⌘D) hides or restores the compact footer. This preference is also in **Settings → Viewing** and is remembered. The two shortcuts stay on the viewing Mac when other shortcuts are forwarded to the remote Mac. Stats and their Save Diagnostics action remain available with the footer hidden.
