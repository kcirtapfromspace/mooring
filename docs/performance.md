# Performance and reliability acceptance plan

**Status: proposed two-Mac targets, not comparative measured results.** MacLink has both an Apple Screen Sharing launcher/automation route and a native ScreenCaptureKit, VideoToolbox, encrypted Rust transport, decoder, input, audio, clipboard and Metal presentation route. Local synthetic hardware-codec and encrypted-loopback tests demonstrate that the native engine works; they do not establish physical two-Mac latency, throughput, fidelity or superiority over Apple Screen Sharing.

The native flow policy uses live TCP send-queue and throughput observations to pace frames and adapt bitrate. The separate adaptive-quality policy below is still tested with simulated samples. The Apple-route TCP/RFB checks measure reachability and service readiness, not bandwidth, loss or video latency. Keep those three sources of evidence distinct.

## What to prove

Use the same two Macs, displays, scaling, macOS versions, network path, and workloads for MacLink and Apple Screen Sharing High Performance. Do not compare a lower-resolution MacLink picture with a native-resolution Apple picture. Record physical pixels and logical desktop dimensions separately.

| Acceptance gate | Proposed initial target | Measurement |
| --- | --- | --- |
| Click-to-photon on healthy home LAN | p50 ≤ 35 ms; p95 ≤ 60 ms at native capture, 60 Hz presentation | External high-speed video; host-generated visual response to a client click |
| Apple parity | Both p50 and p95 no more than 10% slower than Apple under the same workload, while also meeting the absolute LAN targets | Alternate Apple/MacLink runs; report both results, not only a ratio |
| Frame pacing | ≥ 58 presented fresh frames/sec during a 60 fps moving workload; p95 presentation interval ≤ 25 ms | Instrument actual presentation; exclude repeated frames from the count |
| Backlog | One pending raw frame per capture/render handoff; no sustained application video queue exceeding one frame interval | Queue age and depth histogram; track decoder and GPU queues separately |
| Usability | Already paired, awake Mac: p95 first usable frame ≤ 2 s after Connect | 30 cold and 30 warm application runs; separate authentication time |
| Brief network interruption | Following a 1–3 s interruption, p95 recovery ≤ 5 s after reachability returns, within the retry budget | 30 interrupted sessions; verify working input as well as picture |
| Long disconnect | Stop at the native retry budget: five ordinary retries, or forty attempts three seconds apart while the host updates or awaits unlock; explicit Disconnect cancels pending work immediately | Deterministic policy test plus integrated fault injection |
| Extended session | Eight-hour active session without crash, stuck modifiers, accumulating frame backlog, or unbounded memory growth | Per-minute memory/resource counters and input/stream health checks |
| Desktop continuity | Zero changes to logical desktop dimensions during automatic quality adaptation | Log dimensions before and after every profile change |

These numbers are product gates to validate and adjust against evidence. A 60 Hz display alone quantizes presentation; encoder latency or ping measurements are not click-to-photon measurements. Baseline Apple under both wired Ethernet and the user's normal home Wi-Fi. Internet tests must be reported separately; the LAN latency target does not apply unchanged to a distant network.

## Measurement procedure

1. Record Mac model, chip, RAM, macOS build, physical display resolution, scaling, refresh rate, color/HDR settings, wired/Wi-Fi path, access point, channel, signal strength, and battery/power state. Use identical host and viewer workloads for both implementations.
2. Disable unrelated downloads for the clean baseline. Warm each client for 30 seconds, run five 60-second trials per workload, and alternate client order. Repeat 300 input/visual-response events per condition, using a test app that changes an obvious rectangle when it receives input.
3. Film both the input indicator and the displayed response with at least a 240 fps camera. Report camera time resolution with p50/p95/p99. A local cursor moving ahead of the remote desktop must not count as a host response. For more precise work, use a physical input/LED and photodiode rig.
4. Add per-frame capture, encode, send, receive, decode, and presented timestamps, plus a sequence identifier. Report per-stage distributions and clock assumptions. Use same-machine monotonic durations where possible; do not subtract unsynchronized host and viewer clocks to invent one-way latency.
5. Use typing and cursor movement in a terminal, colored small text, code editing, browser scrolls, a moving window, video playback, static desktop, and rapid multi-monitor transitions. Record native screenshots at stable points for fidelity review.
6. Report bitrate, dropped raw frames, decoder recovery events, encode/decode CPU/GPU load, memory, power/thermal state, actual codec/profile/pixel format, native physical dimensions, and presented frame rate alongside latency. Keep raw trials and publish failed runs too.

## Text fidelity and 4:4:4 feasibility

The checked-in [local capability probe](local-codec-capabilities.json) created hardware-required 3840×2160 VideoToolbox compression sessions and queried advertised profiles. It did **not** encode frames. Normal-session results advertised H.264 High 4:4:4 Predictive and HEVC Main 4:4:4 profile names. Low-latency-requested results advertised H.264 names for both requested codecs. That discrepancy must be investigated by inspecting actual output; successful property/session calls do not prove a working 4:4:4 low-latency hardware path.

Before selecting a production codec:

- Encode/decode real frames on every supported host/viewer chip family. Inspect the encoded bitstream's actual codec, chroma format, dimensions, profile, and reordering behavior. Verify actual hardware use and decoder capability; do not infer them from advertised names.
- Test 4:4:4 at 3840×2160 and 60 fps while measuring encode/decode latency, sustained frame rate, bitrate, power, and thermal throttling. If it fails, document the exact unsupported combination and evaluate a feasible fallback before promising equivalent Apple fidelity.
- Use small colored monospace text, single-pixel chroma edges, colored line art, scrolling, and grayscale text at matching Retina scale. Compare lossless host captures, decoded captures, and Apple's viewer output without resizing the comparison images.
- Inspect crop magnifications and quantify edge/chroma error against the source. A broad perceptual image score can hide colored-text damage. Have the user review native-size text on the actual viewer display.
- Treat the policy's `prefer_chroma_444` as a requested preference requiring negotiation. It is not proof that 4:4:4 is supported, selected, or necessarily the fastest configuration.

The `Sharpest` policy retains full physical capture scale while reducing frame rate under constraints. `Auto` and `Fastest` can reduce capture pixel density while keeping the logical desktop size fixed. Adapting capture density must not move windows, resize the remote desktop, or change coordinate mapping.

## Wi-Fi and failure matrix

Use a controlled router or isolated network impairment tool to introduce delays and loss. Separately test real Wi-Fi contention and roaming; an artificial packet-loss test does not reproduce radio behavior.

| Condition | Test values | Expected behavior |
| --- | --- | --- |
| Sustainable video bandwidth | 100, 50, 20, 8, 2 Mbps; abrupt and gradual transitions | Reduce demands promptly; preserve a responsive UI; no queue growth |
| RTT | Baseline, 20, 60, 120 ms | Report real input delay; no false LAN classification |
| Jitter | 0, 5, 15, 30 ms | Avoid quality oscillation; bound frame age |
| Packet loss | 0, 0.1, 1, 3, 5%; burst loss as well as independent loss | Recover decodable video; request clean recovery frames when needed |
| Outage | 0.2, 1, 3, 10, 60 seconds | Reconnect within budget; show actionable exhausted state |
| Network changes | Ethernet → Wi-Fi, AP roam, host address change | Preserve verified peer identity; revalidate the connection |
| Permissions/session | Capture denied, input denied, lock, sleep/wake, display unplug/replug | Explain required action; release input state; do not blindly retry permanent failures |
| Bad telemetry | Missing, NaN/infinity, negative values, future/stale/duplicate samples, clock regression | Conservative bounded behavior; never infer healthy network state |

Never discard arbitrary interdependent compressed packets to imitate a latest-frame policy. Bound raw frames before encoding and complete decoded frames before display. Compressed-video congestion handling needs codec-aware frame dependency management, keyframe/recovery strategy, transport congestion control, and an input path that cannot be starved by video.

## Current policy contract

`QualityController` accepts monotonic session-relative milliseconds and synthetic or measured `NetworkSample` values. Thresholds are deliberately provisional and require tuning from the benchmark data above. They do not account for desktop resolution, content complexity, codec capability, or thermal state yet.

- Start at Balanced. A fresh adverse sample immediately lowers the level.
- Upgrade one level only after at least five consecutive fresh samples spanning two seconds and a three-second cooldown since the previous level change. A gap longer than 1.5 seconds resets upgrade evidence.
- Ignore invalid, future, duplicate, and out-of-order samples. Samples older than 1.5 seconds are stale. After 2.5 seconds without a valid observation, fall back to Survival and a conservative bitrate cap.
- Reject backward clock readings without changing controller history. Use an `Instant`-derived clock in an integration, not wall time.
- Limit requested video bitrate to 70% of estimated sustainable available bandwidth. This is policy headroom, not a congestion controller or guaranteed achieved bitrate. At insufficient bandwidth a target frame rate is best effort.
- The one-slot `LatestFrameMailbox` releases superseded raw/decoded frames; application-held frames and in-flight GPU work still need their own budgets.
- `ReconnectPolicy` starts at 250 ms, doubles delays, applies deterministic injected jitter within ±20%, clips actual delay at 8 seconds, and stops after eight failed attempts. Pending scheduling is idempotent. A successful connection resets the budget; explicit user Disconnect cannot be undone by a late success callback. Authentication and permission denials require a different path.
- `PeerContext` keeps network path and pairing trust separate. A private IP, Bonjour name, or fast response never establishes identity. This metadata type does not implement pairing, credential verification or encryption; the native session crate implements those boundaries separately.

Run `cargo test -p maclink-core` for policy, mailbox and retry tests, and `cargo run -p maclink-cli -- simulate` for serializable synthetic scenarios. These verify deterministic behavior only. Native scripted tests cover additional codec, encrypted-loopback and lifecycle boundaries; acceptance remains open until matched real two-Mac trials measure the native pipeline.
