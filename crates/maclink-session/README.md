# MacLink session

Experimental C ABI for the direct LAN companion and viewer. Link the static
`libmaclink_session.a` and import `include/maclink_session.h`. Session calls block
and belong on background queues. No service starts without an explicit listen call.

Rust owns the session protocol: sockets, framing, deadlines, typed wire formats and
their validation, per-role direction and rate policy, the host's held-input state,
pairing codes, saved peer metadata, and live telemetry and tuning. Swift converts Apple types to and from the
header's fixed-layout structs, stores secrets in Keychain, drives ScreenCaptureKit,
VideoToolbox and CGEvent, and owns the UI. Struct layouts are asserted at compile
time on both sides of the boundary.

## Pairing

Pairing supplies a pinned responder public key and an independent 32-byte random
PSK out of band. A code is `MLP1.` followed by strict padded base64 of a JSON object
with exactly `version` (1), `address`, `name`, `publicKey` and `secret`. Keychain
credentials hold the same JSON, so pairings saved by earlier builds remain readable.
Addresses use the project's single host rule (`maclink_platform::validate_host`) and
are normalized. Names are 1–160 UTF-8 bytes without control or format characters;
the sharing Mac's own computer name is normalized rather than rejected. A peer ID is
the lowercase hex SHA-256 of the public key. Secrets are never logged, and heap
copies made while encoding or decoding them are zeroized.

Saved peers (`native-peers.json` in `MACLINK_HOME` or Application Support) hold only
ID, name and address, at most 32, most recent first. The file uses the CLI store's
conventions: bounded size, strict validation, owner-only permissions, atomic
replacement and a cross-process lock; an unreadable file is never overwritten. The
earlier preference list is imported once.

## Transport

The protocol is `Noise_NKpsk0_25519_ChaChaPoly_BLAKE2s` with prologue
`MacLink direct session v1`. Each handshake payload is `maclink-session/3`, which
names the application message formats; mismatched builds fail the handshake. Both
peers then confirm fresh transport keys with encrypted `client-ready/1` and
`server-ready/1` records at directional nonce zero. Session handles are published
only after confirmation. Application record nonces begin at one, and logical
message sequences begin at zero.

Each TCP record has a two-byte big-endian ciphertext length, bounded to 65535.
Receivers authenticate before interpreting any application metadata. Application
plaintext contains version byte 1, type byte, two reserved zero bytes, big-endian
u64 message sequence, u32 total payload length and u32 chunk offset, followed by at
most 65499 payload bytes. Every chunk authenticates the same type, sequence and
total, and must have the expected next offset. Video messages are bounded to 12 MiB,
input to 256 bytes, control to 1 KiB and telemetry to 512 bytes. TCP_NODELAY is enabled.

## Messages and policy

An accepted session is the sharing host; a connected session is the viewer.

- **Video** (host → viewer): one H.264 access unit, `MLV1` header with dimensions,
  sequence and capture timestamp, then SPS, PPS and an AVCC bitstream. Dimensions
  are even, 16–4096, at most 3840×2160 pixels. Only slice, IDR, SEI, AUD and filler
  NAL units are allowed: in-band parameter sets are rejected. The keyframe flag must
  match the presence of an IDR slice.
- **Input** (viewer → host): 44 bytes. Key events carry key codes 0–127 and only
  non-modifier key-downs may repeat; pointer events carry normalized coordinates,
  buttons 0–2 and click counts 1–3; scrolls are bounded to ±1200. Release-all
  carries nothing.
- **Control**: 52 bytes. Hosts send geometry (with input permission), input state
  and pong; viewers send ping and keyframe requests.
- **Telemetry**: stats (up to 32 distinct metric IDs with finite values from 0 to
  1e9) from either side about once a second, and tuning from the viewer only:
  bitrate 1–80 Mbps, maximum capture width 640–3840 (even), frame rate 1–60,
  frames in flight 1–2 and keyframe interval 1–10 s, where zero means unchanged.

Fields a kind does not use must be zero. Invalid or misdirected sends return
`INVALID` before any byte is written and leave the session open. On receive, a
viewer needs geometry before video; hosts accept at most 1000 messages and viewers
32 control and telemetry messages per second (`RATE_LIMITED`); hosts skip pings under 250 ms and
keyframe requests under 500 ms apart (viewers retry at 750 ms); ten seconds without
a complete message ends the session (`STALLED`). Any peer violation closes the
session and clears the rejected plaintext.

The host's input state releases only keys and buttons the connection pressed,
bounds autorepeat to 120 Hz, and releases ordinary keys before modifiers and then
buttons at the latest position. `accept` stages a transition; the caller commits
after posting the returned events.

## Local telemetry

Each app serves an owner-only (0600) Unix socket, `telemetry/telemetry.sock`, in an
owner-only (0700) folder of the MacLink data directory. Clients read one JSON snapshot per line (this Mac's measurements,
the peer's latest, and the sharing settings) and write `{"tune": {...}}` lines,
which are validated, acknowledged and merged into one pending update the app takes
each second. At most four clients are served; a slow client or a command line over
1 KiB disconnects that client. A second running copy leaves the socket to the
first, and a non-socket file at that path is never replaced. No network port is
opened. See `docs/TELEMETRY.md` and the CLI's `telemetry` and `tune` commands.

## Protocol versions and capabilities

Builds speak protocol versions 4–5, and each connection negotiates the highest
version both sides support. The initiator offers `maclink-session/5`. The
responder answers with the lower of that and its own highest version. A host
from before version 5 closes the connection when offered 5, so the initiator
retries once, offering 4, within the same deadline.

Version 5 sessions start with each side's `Hello` control message: capability
bits in the `ping_id` field, sent automatically by Rust, received at most once.
Unknown bits are kept, so later builds can add capabilities without breaking
earlier ones. `ml_capabilities_set` fixes this process's bits for sessions
started afterwards.

`ML_CAPABILITY_HEVC_444` means "this side decodes HEVC 4:4:4 in hardware".
Rust refuses to send HEVC video unless the peer announced it, and treats HEVC
arriving without the local capability as a protocol violation. H.264 packets
keep the `MLV1` format. HEVC uses `MLV2`, which adds a VPS. Both are checked for
parameter sets, NAL types and a keyframe flag that matches the picture type.
`ml_video_hevc_chroma_format` reads `chroma_format_idc` from an SPS, so
MacLink can confirm the encoder really produced 4:4:4.

## Shared clipboard

Either side may send a clipboard message: one to three representations of one
copied item (UTF-8 text, RTF, PNG) in ascending kind order, each non-empty and
carrying its format's signature, at most 4 MiB in total. Rust validates it before
sending and after receiving, and at most four arrive per second. Received
representations land in the caller's large-message buffer, so hosts now pass a
buffer of at least `ML_CLIPBOARD_MAX_MESSAGE` bytes.

## Viewer shortcuts and reconnects

`ml_input_keeps_local` names the chords that stay on the viewing Mac while it
captures system shortcuts such as ⌘-Tab for the remote Mac: Force Quit, Lock
Screen and full screen. `ml_reconnect_delay_ms` is the viewer's bounded
automatic-reconnect backoff: five attempts, 0.5 s to 8 s apart, with a fresh
budget after a session stays connected for 20 s.

## Lifecycle

Deadlines are absolute across each operation, 1–30000 ms, with two graces: a
connection accepted near the end of an accept window gets up to 1 s to
authenticate, and a message whose first byte has arrived gets 10 s to finish even
past the receive deadline, which bounds only the wait for a new message. An idle
receive timeout is retryable. A message still incomplete after its grace
(`STALLED`), malformed input, an authentication failure or a failed send closes
the session. Each direction has independent counters and a
separate operation lock; a video writer cannot hold the input reader's lock. Close
removes the numeric handle and shuts down sockets; in-flight calls keep Arc
ownership rather than dereferencing freed handles. IDs are not reused. The registry
holds at most 128 handles, and at most four bounded-wait DNS workers can be
outstanding.

## Dependencies and verification

snow 0.10.0, getrandom 0.4.3, sha2 0.10.9, serde and serde_json are permissively
licensed; versions and checksums are in the workspace Cargo.lock and notices ship
with the app. Upstream [snow](https://github.com/mcginty/snow) explicitly states
that it has not received a formal audit. This session crate and the assembled
prototype are not audited. Crypto primitives come from snow's selected providers;
this crate implements framing, validation and lifecycle, not cryptographic
primitives.

Run `cargo test -p maclink-session` for loopback authentication, duplex transfer,
tamper/replay, framing, direction and rate policy, idle limits, typed wire formats,
input state, pairing, the peer store, telemetry and its local socket, and the C ABI. `scripts/test-native.sh` covers
the Swift side of the boundary and a hardware-codec loopback stream. These tests do
not establish real-network performance or streaming quality.
