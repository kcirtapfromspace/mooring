# Synthetic HEVC encoding feasibility

This probe encodes six generated 1280×720 BGRA frames per case using public VideoToolbox APIs. The images contain colored small text, one-pixel color edges, and a moving rectangle. It captures no screen, sends no remote input, requires no screen-recording permission, and downloads nothing.

The checked-in [local findings](local-encode-feasibility.json) establish a limited but useful result: on this Mac, normal-session HEVC Main444 produced actual 4:4:4 output while VideoToolbox reported hardware encoding. Low-latency-session profile advertisement and successful property setters did **not** establish the requested chroma format.

| Request | Actual output inspected by ffprobe | Frames | Hardware query |
| --- | --- | --- | --- |
| Normal HEVC Main | HEVC Main, `yuv420p` | 6/6 | `true` |
| Normal HEVC Main444 | HEVC Rext, `yuv444p` | 6/6 | `true` |
| Low-latency HEVC, default profile | HEVC Main, `yuv420p` | 3/6 | Unsupported property, status `-12900` |
| Low-latency HEVC Main | HEVC Main, `yuv420p` | 3/6 | Unsupported property, status `-12900` |
| Low-latency HEVC Main444 | HEVC Main, `yuv420p` despite accepted Main444 request | 3/6 | Unsupported property, status `-12900` |

All cases required a hardware encoder at session creation, set RealTime to true, and disabled frame reordering. The normal cases reported Apple's `ave.hevc` encoder; the low-latency cases reported `hevc.rtvc`. The latter's hardware-query error is preserved rather than interpreted as either true or false. ffprobe found no B frames in these tiny samples.

The low-latency cases advertised HEVC profiles at 720p. The separate [4K session-only probe](local-codec-capabilities.json) returned different advertised profiles, including H.264 names for a requested HEVC low-latency session. Capability results must therefore remain tied to the tested dimensions and configuration; the session-only report does not establish the actual 4K output codec.

Frames are submitted in a burst with 60 fps timestamps; they are not paced at wall-clock 60 fps. Three dropped-frame callbacks in the low-latency cases are recorded as partial output. This does not prove that paced streaming would drop half its frames, and the timestamps do not prove 60 fps throughput. The probe neither measures latency nor compares text fidelity, power, thermals, sustained 4K performance, hardware decoding, or Apple Screen Sharing parity.

## Reproduce

From the repository root:

```sh
./scripts/run-encode-probe.sh
```

The runner needs the macOS developer tools, `/usr/bin/python3`, and the already installed `/opt/homebrew/bin/ffprobe`. It compiles with warnings treated as errors, limits compilation to 90 seconds and execution to 60 seconds, and kills the subprocess group on timeout. No dependency installation is attempted. A missing ffprobe is reported in the findings; the encoder output can still be saved.

By default it atomically updates `docs/local-encode-feasibility.json` and stores the executable plus small Annex B bitstreams under ignored `target/encode-probe/`. Optional arguments override the report and artifact directory:

```sh
./scripts/run-encode-probe.sh /tmp/my-report.json /tmp/my-bitstreams
```

The Swift script selects a requested profile only when that exact value was returned by the session's public supported-property dictionary. An absent profile, rejected setter, failed preparation, encode failure, dropped callback, or malformed output is reported. It never silently switches requested profiles. The actual format-description codec determines how parameter sets and length-prefixed NAL units are converted to Annex B. ffprobe then independently reads and decodes those generated files to report codec, profile, pixel format, dimensions, B-frame presence, and frame count.

A complete synthetic encode is one feasibility step. The next acceptance gate is sustained native-resolution encode/decode with verified bitstream chroma, frame pacing, hardware use, and end-to-end input measurements on both Macs, as specified in [the performance plan](performance.md).
