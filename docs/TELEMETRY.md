# Live telemetry and tuning

While a native MacLink session is connected, each Mac sends the other a small measurement record once a second over the encrypted session. Each running app serves the combined view on an owner-only local socket, `telemetry/telemetry.sock` in `~/Library/Application Support/MacLink` (or `MACLINK_HOME`); the `telemetry` folder is readable only by you. No network port is opened, and telemetry contains measurements only: no screen content, input, addresses or keys.

Run the bundled CLI on either Mac:

```sh
maclink=/Applications/MacLink.app/Contents/Resources/maclink
"$maclink" telemetry              # one JSON line per second until interrupted
"$maclink" telemetry --count 10   # stop after ten snapshots
"$maclink" tune --bitrate-mbps 15 --max-width 2560
"$maclink" tune --fps 30 --in-flight 1
"$maclink" tune --reset           # restore the defaults
```

Tuning typed on the viewing Mac during a session is sent to the sharing Mac; tuning on the sharing Mac applies there, and without a session it is kept for the next time this Mac shares. Settings last until the sharing Mac's app quits, including across reconnects. Changes apply within about a second; a new maximum width restarts capture at that size, which briefly pauses the picture.

## Snapshot

```json
{"t":42.1,"role":"viewer","tuning":{"bitrate_mbps":25.0,"max_width":3840,"fps":60,"in_flight":2,"keyframe_seconds":2},
 "local":{"received_fps":38.0,"rtt_ms":9.0,...},"peer":{"capture_fps":41.0,"encode_ms":24.5,...},"peer_age_s":0.4,"last_end":null}
```

`role` is `host` (this Mac is sharing), `viewer`, or `idle`. `last_end` is `null`, or `{"reason": …, "age_s": …}`: MacLink's reason for the latest session on this Mac ending and how many seconds ago, so a drop can be diagnosed after the fact. `local` holds this Mac's measurements and `peer` the other Mac's latest, `peer_age_s` seconds old. `tuning` is this Mac's own sharing settings; while viewing, the sharing Mac's settings appear in `peer` as `bitrate_mbps`, `fps_cap` and the capture size. Rates are per second over the last interval.

Sharing Mac:

| Field | Meaning |
|---|---|
| `capture_fps` | Complete frames ScreenCaptureKit delivered. Only screen changes produce frames, up to the `fps` cap. |
| `encoded_fps` | Frames the hardware encoder produced. |
| `skipped_fps` | Captured frames refused because the in-flight limit was reached (backpressure). |
| `dropped_fps` | Frames the encoder's real-time rate control skipped. |
| `failed_frames`, `keyframes` | Failed frames (each restarts with a keyframe) and keyframes sent in the interval. |
| `encode_ms`, `encode_ms_max` | Average and maximum hardware encode time. |
| `send_ms`, `send_ms_max` | Time to encrypt a frame and hand it to TCP, including waiting for socket space. |
| `sent_mbps`, `frame_kib` | Video sent and average frame size. |
| `in_flight` | Frames encoding or sending right now (at most `in_flight` tuning). |
| `bitrate_mbps`, `fps_cap`, `pixel_width`, `pixel_height` | Settings in effect and the capture size. |

Viewing Mac:

| Field | Meaning |
|---|---|
| `received_fps`, `received_mbps` | Video arriving. |
| `decode_ms`, `decode_ms_max`, `decoded_fps` | Hardware decode time and rate. |
| `presented_fps` | Frames that reached the display. |
| `rtt_ms` | Ping round trip, including the sharing Mac's send queue. Not display latency. |
| `keyframe_requests`, `decoder_overflows` | Recovery requests, and packets discarded because decoding fell behind. |

## Session log

Session starts and ends, reconnect attempts, automatic sharing, tuning changes and shared-clipboard transfers (their kinds and sizes) are also written to the macOS log with MacLink's reason text; never addresses, names, pairing codes, input or screen content:

```sh
/usr/bin/log show --last 2h --style compact --predicate 'subsystem == "dev.maclink"'
```

In zsh, `log` alone is a shell built-in; use `/usr/bin/log`.

## Reading the numbers

- `capture_fps` near zero while nothing moves is normal.
- `skipped_fps` high with `send_ms` high: the network is the limit. Lower `bitrate_mbps` or `max_width`.
- `skipped_fps` high with `encode_ms` above the frame interval (16.7 ms at 60 fps): the encoder is the limit. Lower `max_width`, or `fps`.
- `in_flight 1` versus `2`: two overlaps encoding with sending for throughput; one lowers latency when the link is fast.
- `decoder_overflows` or `presented_fps` below `decoded_fps`: the viewing Mac is the limit.
- Frequent `keyframes` or `keyframe_requests` means recovery; a larger `keyframe_seconds` reduces periodic keyframes on a stable link.

Bounds: `bitrate_mbps` 1–80, `max_width` 640–3840 and even, `fps` 1–60, `in_flight` 1–2, `keyframe_seconds` 1–10. The app validates every command in Rust and replies with an acknowledgement or an error; the socket accepts at most four clients and 1 KiB per command line.
