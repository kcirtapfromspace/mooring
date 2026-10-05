# Mooring 0.3.0 preview 9 — Sharper text

Installed copies of preview 6 or later update to this version by themselves when no session is connected.

## Full colour detail for text

The picture used H.264 with 4:2:0 colour, which stores colour at a quarter of the resolution. That blurs coloured and small text: terminals, syntax highlighting, thin UI lines.

Apple silicon can encode and decode HEVC with full 4:4:4 colour in hardware. When both Macs support it, Mooring now streams HEVC 4:4:4 at the same resolution and frame rate.

At launch, each Mac encodes and decodes one small HEVC 4:4:4 frame in hardware and reads back the colour format it actually produced. Only a Mac that passes announces the capability. The sharing Mac streams HEVC 4:4:4 only to a viewer that announced it, and otherwise uses H.264 as before.

The session log says which codec is in use:

- **Sharing Mac:** "streaming HEVC 4:4:4 at 1920×1080, 4:4:4 chroma confirmed".
- **Both Macs:** whether the launch self-test passed.

## Mixed versions keep connecting

The connection protocol now negotiates a version. At the start of a session, each Mac announces what it supports, and new features switch on only when both sides support them. A Mac on preview 9 still connects to one on previews 4–8, which falls back to H.264. Later features can be added the same way without breaking connections between Macs that update at different times.

## Menu

**Check for Updates…** now sits at the bottom of the menu, just above **Quit Mooring**, with the installed version on the line above it.

## Validation

Local validation passed with Rust session tests covering:

- version negotiation, including falling back to a host that accepts only version 4;
- the capability Hello (once only, version 5 only, unknown bits kept);
- HEVC packets and each malformed variant;
- reading 4:4:4 from an SPS;
- HEVC refused to a viewer that didn't announce it.

On this Mac (M1 Ultra), the hardware HEVC 4:4:4 path handled 120 paced 1080p frames at 60 fps:

- **Encode:** 10.4 ms mean, 11.5 ms at the 95th percentile. H.264 averages about 10.6 ms.
- **Decode:** 3.4 ms mean.
- **Independent check:** ffprobe reads the stream as HEVC Rext `yuv444p` with no B-frames.

Over the encrypted loopback, both sides negotiated version 5, exchanged capabilities, and the viewer decoded HEVC 4:4:4 frames from the host.

The viewing MacBook Pro's hardware support for HEVC 4:4:4 decoding hasn't been confirmed yet. Its launch self-test decides automatically, and its log reports the result.

Apple silicon and macOS 14 or later. Developer ID signed, notarized and stapled. Published to the public update feed. All CI and builds run on the local host; GitHub Actions is disabled on both repositories.
