# MacLink session

Experimental C ABI for the direct LAN companion and viewer. Link the static
`libmaclink_session.a` and import `include/maclink_session.h`. Session calls block
and belong on background queues. No service starts without an explicit listen call.

Rust owns the session protocol: sockets, framing, deadlines, typed wire formats and
their validation, per-role direction and rate policy, the host's held-input state,
pairing codes, and saved peer metadata. Swift converts Apple types to and from the
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
`MacLink direct session v1`. Each handshake payload is `maclink-session/2`, which
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
input to 256 bytes and control to 1 KiB. TCP_NODELAY is enabled.

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

Fields a kind does not use must be zero. Invalid or misdirected sends return
`INVALID` before any byte is written and leave the session open. On receive, a
viewer needs geometry before video; hosts accept at most 1000 messages and viewers
32 control messages per second (`RATE_LIMITED`); hosts skip pings under 250 ms and
keyframe requests under 500 ms apart (viewers retry at 750 ms); ten seconds without
a complete message ends the session (`STALLED`). Any peer violation closes the
session and clears the rejected plaintext.

The host's input state releases only keys and buttons the connection pressed,
bounds autorepeat to 120 Hz, and releases ordinary keys before modifiers and then
buttons at the latest position. `accept` stages a transition; the caller commits
after posting the returned events.

## Lifecycle

Deadlines are absolute across each operation, 1–30000 ms, except that a connection
accepted near the end of an accept window gets up to 1 s to authenticate. An idle
receive timeout
is retryable. A timeout after any frame bytes, malformed or authentication failure,
or failed send closes the session. Each direction has independent counters and a
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
input state, pairing, the peer store and the C ABI. `scripts/test-native.sh` covers
the Swift side of the boundary and a hardware-codec loopback stream. These tests do
not establish real-network performance or streaming quality.
