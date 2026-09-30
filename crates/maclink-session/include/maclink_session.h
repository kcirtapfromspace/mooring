#ifndef MACLINK_SESSION_H
#define MACLINK_SESSION_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Experimental session: upstream snow has not received a formal audit.
 * Rust owns wire formats, validation, per-role policy, host input state,
 * pairing codes and saved peer metadata. Swift converts Apple types to and
 * from these structs, stores secrets in Keychain, and owns the UI.
 * Pairing is out of band: pin the public key and protect the random PSK in
 * Keychain. No secrets are logged. Session calls block; use background queues.
 * Pointers must remain valid for the call. Keys are exactly 32 bytes. Numeric
 * handles are safe to close while another thread is using them. No listener
 * starts until listen is called. Port 0 is useful for tests. Outputs are
 * cleared before work begins; a failed call leaves no partial result.
 */
enum {
    ML_SESSION_OK = 0, ML_SESSION_INVALID = -1, ML_SESSION_IO = -2,
    ML_SESSION_TIMEOUT = -3, ML_SESSION_AUTH = -4, ML_SESSION_PROTOCOL = -5,
    ML_SESSION_CLOSED = -6, ML_SESSION_BUFFER = -7, ML_SESSION_BUSY = -8,
    ML_SESSION_INTERNAL = -9, ML_SESSION_RATE_LIMITED = -10,
    ML_SESSION_STALLED = -11, ML_SESSION_STORAGE = -12
};
enum { ML_SESSION_VIDEO = 1, ML_SESSION_INPUT = 2, ML_SESSION_CONTROL = 3, ML_SESSION_TELEMETRY = 4, ML_SESSION_CLIPBOARD = 5, ML_SESSION_CURSOR = 6, ML_SESSION_AUDIO = 7 };
/* Clipboard representations: UTF-8 plain text, Rich Text Format, PNG. */
enum { ML_CLIPBOARD_TEXT = 1, ML_CLIPBOARD_RTF = 2, ML_CLIPBOARD_PNG = 3 };
enum { ML_TELEMETRY_STATS = 1, ML_TELEMETRY_TUNING = 2 };
enum { ML_ROLE_IDLE = 0, ML_ROLE_HOST = 1, ML_ROLE_VIEWER = 2 };
/* Measurement IDs; the local JSON uses the lowercase names after ML_METRIC_. */
enum {
    ML_METRIC_CAPTURE_FPS = 1,
    ML_METRIC_ENCODED_FPS = 2,
    ML_METRIC_SKIPPED_FPS = 3,
    ML_METRIC_DROPPED_FPS = 4,
    ML_METRIC_FAILED_FRAMES = 5,
    ML_METRIC_KEYFRAMES = 6,
    ML_METRIC_ENCODE_MS = 7,
    ML_METRIC_ENCODE_MS_MAX = 8,
    ML_METRIC_SEND_MS = 9,
    ML_METRIC_SEND_MS_MAX = 10,
    ML_METRIC_SENT_MBPS = 11,
    ML_METRIC_FRAME_KIB = 12,
    ML_METRIC_IN_FLIGHT = 13,
    ML_METRIC_BITRATE_MBPS = 14,
    ML_METRIC_PIXEL_WIDTH = 15,
    ML_METRIC_PIXEL_HEIGHT = 16,
    ML_METRIC_FPS_CAP = 17,
    ML_METRIC_CAPTURE_MS = 18, /* host: screen update to the encoder */
    ML_METRIC_SEND_QUEUE_KIB = 19, /* host, local only: most queued in the send buffer */
    ML_METRIC_QUEUE_WAIT_MS = 20, /* host, local only: milliseconds frames waited for the send buffer */
    ML_METRIC_RECEIVED_FPS = 32,
    ML_METRIC_RECEIVED_MBPS = 33,
    ML_METRIC_DECODE_MS = 34,
    ML_METRIC_DECODE_MS_MAX = 35,
    ML_METRIC_DECODED_FPS = 36,
    ML_METRIC_PRESENTED_FPS = 37,
    ML_METRIC_RTT_MS = 38,
    ML_METRIC_KEYFRAME_REQUESTS = 39,
    ML_METRIC_DECODER_OVERFLOWS = 40,
    /* Viewer, with ML_CAPABILITY_LATENCY: host screen update to this Mac's
     * display, the part until decoding starts, and waiting to be shown. */
    ML_METRIC_LATENCY_MS = 41,
    ML_METRIC_LATENCY_MS_P95 = 42,
    ML_METRIC_TO_VIEWER_MS = 43,
    ML_METRIC_DISPLAY_WAIT_MS = 44,
    ML_METRIC_CLOCK_ERROR_MS = 45
};
enum {
    ML_CONTROL_GEOMETRY = 1, ML_CONTROL_INPUT_STATE = 2, ML_CONTROL_PING = 3,
    ML_CONTROL_PONG = 4, ML_CONTROL_KEYFRAME = 5,
    ML_CONTROL_HELLO = 6, /* protocol 5: capabilities in ping_id, sent automatically */
    /* Protocol 5, viewer to host: share a display of geometry.width x height
     * points and pixel_width x pixel_height pixels (scale 1 or 2); all zero
     * means the host's own display. Needs ML_CAPABILITY_VIRTUAL_DISPLAY. */
    ML_CONTROL_DISPLAY_REQUEST = 7,
    /* protocol 5, host to a viewer with ML_CAPABILITY_LATENCY: a pong carrying
     * ping_id and the host's time in microseconds of CoreMedia host time, as
     * geometry.pixel_width (high 32 bits) and pixel_height (low 32 bits). */
    ML_CONTROL_CLOCK = 8
};
enum {
    ML_INPUT_KEY_DOWN = 1, ML_INPUT_KEY_UP = 2, ML_INPUT_POINTER_MOVE = 3,
    ML_INPUT_POINTER_DOWN = 4, ML_INPUT_POINTER_UP = 5, ML_INPUT_SCROLL = 6,
    ML_INPUT_RELEASE_ALL = 7,
    /* Protocol 5, to hosts announcing ML_CAPABILITY_GESTURES: phase in button
     * (ML_GESTURE_PHASE_*), magnification or degrees in delta_x. */
    ML_INPUT_MAGNIFY = 8, ML_INPUT_ROTATE = 9, ML_INPUT_SMART_MAGNIFY = 10
};
enum {
    ML_GESTURE_PHASE_BEGAN = 1, ML_GESTURE_PHASE_CHANGED = 2,
    ML_GESTURE_PHASE_ENDED = 4, ML_GESTURE_PHASE_CANCELLED = 8
};
enum {
    ML_MODIFIER_SHIFT = 1 << 0, ML_MODIFIER_CONTROL = 1 << 1, ML_MODIFIER_OPTION = 1 << 2,
    ML_MODIFIER_COMMAND = 1 << 3, ML_MODIFIER_CAPS_LOCK = 1 << 4, ML_MODIFIER_FUNCTION = 1 << 5
};
#define ML_SESSION_MAX_VIDEO 12582912u /* 12 MiB; a literal so Swift imports it */
#define ML_SESSION_DEFAULT_PORT 45900u
#define ML_VIDEO_HEADER_BYTES 44u
#define ML_INPUT_MAX_EVENTS 132u
#define ML_TEXT_CAPACITY 256u
#define ML_PEER_ID_CAPACITY 65u
#define ML_PAIRING_CODE_CAPACITY 2049u
#define ML_CREDENTIAL_CAPACITY 1024u
#define ML_PEERS_MAX 32u
#define ML_TELEMETRY_MAX_METRICS 32u
#define ML_REASON_CAPACITY 160u
#define ML_CLIPBOARD_MAX_ITEMS 3u
#define ML_CLIPBOARD_MAX_BYTES 4194304u /* 4 MiB of representation bytes per message */
#define ML_CLIPBOARD_MAX_MESSAGE 4194332u /* the smallest receive buffer for a host */
#define ML_RECONNECT_ATTEMPTS 5u
enum { ML_CODEC_H264 = 1, ML_CODEC_HEVC = 2 };
/* Capability bits announced in protocol 5 sessions. */
#define ML_CAPABILITY_HEVC_444 1ull
#define ML_CAPABILITY_VIRTUAL_DISPLAY 2ull
#define ML_CAPABILITY_CURSOR 4ull /* the viewer draws the host's pointer shape */
#define ML_CAPABILITY_GESTURES 8ull /* the host injects trackpad gestures */
#define ML_CAPABILITY_AUDIO 16ull /* this Mac encodes and decodes Opus; a viewer plays the host's sound */
#define ML_CAPABILITY_LATENCY 32ull /* clock replies and latency metrics; peers without it never receive them */
#define ML_AUDIO_MAX_PAYLOAD 1500u /* bytes in one Opus packet */
#define ML_AUDIO_SAMPLE_RATE 48000u
#define ML_RECONNECT_STABLE_SECONDS 20u

/* Logical CoreGraphics display bounds plus encoded pixel dimensions. */
typedef struct {
    double x, y, width, height;
    uint32_t pixel_width, pixel_height;
} MLDisplayGeometry;

/* Fields a kind does not use must be zero. Geometry and input state carry
 * input_enabled (0/1); ping and pong carry ping_id; geometry carries geometry. */
typedef struct {
    MLDisplayGeometry geometry;
    uint64_t ping_id;
    uint8_t kind;
    uint8_t input_enabled;
    uint8_t reserved[6];
} MLControlMessage;

/* Pointer coordinates are normalized 0...1 with a top-left origin in the
 * displayed image. Key events use key_code 0...127; button events use button
 * 0...2 and click_count 1...3; scroll deltas are bounded to +/-1200. Fields a
 * kind does not use must be zero. */
typedef struct {
    double x, y, delta_x, delta_y;
    uint32_t modifiers;
    uint16_t key_code;
    uint8_t kind;
    uint8_t button;
    uint8_t click_count;
    uint8_t is_repeat;
    uint8_t reserved[6];
} MLInputEvent;

typedef struct {
    uint64_t sequence;
    uint64_t timestamp_us;
    uint32_t width, height;
    uint8_t keyframe;
    uint8_t codec; /* ML_CODEC_H264 (or 0) or ML_CODEC_HEVC */
    uint8_t reserved[6];
} MLVideoHeader;

/* One access unit to send: parameter sets (VPS only for HEVC) and a bitstream
 * with four-byte NAL lengths and no in-band configuration. HEVC is refused
 * unless the viewer announced ML_CAPABILITY_HEVC_444. */
typedef struct {
    MLVideoHeader header;
    const uint8_t *sps; size_t sps_length;
    const uint8_t *pps; size_t pps_length;
    const uint8_t *avcc; size_t avcc_length;
    const uint8_t *vps; size_t vps_length;
} MLVideoFrame;

/* A validated received packet; components are ranges in the caller's buffer. */
typedef struct {
    MLVideoHeader header;
    size_t sps_offset, sps_length;
    size_t pps_offset, pps_length;
    size_t avcc_offset, avcc_length;
    size_t vps_offset, vps_length;
} MLVideoPacket;

/* One measurement: finite and 0 to 1e9. */
typedef struct {
    uint8_t metric;
    uint8_t reserved[7];
    double value;
} MLMetric;

/* Zero fields mean "unchanged". Bounds: bitrate 1000-80000 kbps, max_width
 * 640-3840 and even, fps 1-60, in_flight 1-2, keyframe_seconds 1-10. */
typedef struct {
    uint32_t bitrate_kbps;
    uint32_t max_width;
    uint8_t fps;
    uint8_t in_flight;
    uint8_t keyframe_seconds;
    uint8_t reserved[5];
} MLTuning;

/* Stats carry `count` distinct metrics; tuning carries `tuning` and count 0. */
typedef struct {
    uint8_t kind;
    uint8_t count;
    uint8_t reserved[6];
    MLTuning tuning;
    MLMetric metrics[ML_TELEMETRY_MAX_METRICS];
} MLTelemetryMessage;

/* One representation to send: 1-3 per message, kinds strictly ascending,
 * each non-empty with its format's signature, 4 MiB in total. */
typedef struct {
    const uint8_t *bytes;
    size_t length;
    uint8_t kind;
    uint8_t reserved[7];
} MLClipboardItem;

/* One received representation at `offset` in the caller's receive buffer. */
typedef struct {
    size_t offset;
    size_t length;
    uint8_t kind;
    uint8_t reserved[7];
} MLClipboardRange;

typedef struct {
    uint8_t count;
    uint8_t reserved[7];
    MLClipboardRange items[ML_CLIPBOARD_MAX_ITEMS];
} MLClipboardMessage;

/* A received pointer image: size and hotspot in points (at most 256), the
 * PNG at png_offset in the caller's buffer. */
typedef struct {
    uint16_t width, height, hotspot_x, hotspot_y;
    size_t png_offset, png_length;
} MLCursorMessage;

/* The kernel's view of a session's sending side: bytes in the send buffer
 * (unsent, or sent and unacknowledged), smoothed round trip, and totals. */
typedef struct {
    uint32_t queued_bytes, round_trip_ms;
    uint64_t sent_bytes, retransmitted_bytes;
} MLSendQueue;

/* Pacing history kept by the host between bitrate updates; start zeroed. */
typedef struct {
    uint32_t recent, clear_seconds;
} MLFlowState;

/* One clock reply, in microseconds of CoreMedia host time: when this viewer
 * sent the ping and received the reply, and the host's time in the reply. */
typedef struct {
    uint64_t sent_us, received_us, host_us;
} MLClockSample;
/* Host time minus viewer time, and its error bound, in microseconds. */
typedef struct {
    int64_t offset_us;
    uint64_t error_us;
} MLClockEstimate;

/* A received Opus packet (codec 1) at payload_offset in the caller's buffer:
 * its sequence number, duration in 48 kHz frames (240, 480 or 960) and
 * channel count (1 or 2). */
typedef struct {
    uint32_t sequence;
    uint16_t frames;
    uint8_t channels;
    uint8_t codec;
    size_t payload_offset, payload_length;
} MLAudioMessage;

/* kind selects the one populated member. */
typedef struct {
    uint8_t kind;
    uint8_t reserved[7];
    MLVideoPacket video;
    MLInputEvent input;
    MLControlMessage control;
    MLTelemetryMessage telemetry;
    MLClipboardMessage clipboard;
    MLCursorMessage cursor;
    MLAudioMessage audio;
} MLSessionMessage;

/* One local snapshot. peer_age_seconds is negative before peer stats arrive.
 * last_end is MacLink's own printable reason for the latest session end on
 * this Mac, NUL terminated and empty when none has ended. */
typedef struct {
    uint8_t role;
    uint8_t local_count;
    uint8_t peer_count;
    uint8_t reserved[5];
    double session_seconds;
    double peer_age_seconds;
    MLTuning tuning;
    MLMetric local[ML_TELEMETRY_MAX_METRICS];
    MLMetric peer[ML_TELEMETRY_MAX_METRICS];
    double last_end_age_seconds;
    char last_end[ML_REASON_CAPACITY];
} MLTelemetrySnapshot;

/* Strings are NUL-terminated UTF-8. peer_id is lowercase hex SHA-256 of the
 * public key, recomputed whenever a code crosses back into Rust. */
typedef struct {
    char address[ML_TEXT_CAPACITY];
    char name[ML_TEXT_CAPACITY];
    char peer_id[ML_PEER_ID_CAPACITY];
    uint8_t public_key[32];
    uint8_t secret[32];
} MLPairingCode;

typedef struct {
    char id[ML_PEER_ID_CAPACITY];
    char name[ML_TEXT_CAPACITY];
    char address[ML_TEXT_CAPACITY];
} MLPeer;

typedef struct MLInputState MLInputState;

/* Layout contract, asserted identically in Rust (src/ffi.rs). */
_Static_assert(sizeof(MLDisplayGeometry) == 40, "MLDisplayGeometry layout");
_Static_assert(offsetof(MLDisplayGeometry, pixel_width) == 32, "MLDisplayGeometry.pixel_width layout");
_Static_assert(sizeof(MLControlMessage) == 56, "MLControlMessage layout");
_Static_assert(offsetof(MLControlMessage, ping_id) == 40, "MLControlMessage.ping_id layout");
_Static_assert(offsetof(MLControlMessage, kind) == 48, "MLControlMessage.kind layout");
_Static_assert(offsetof(MLControlMessage, input_enabled) == 49, "MLControlMessage.input_enabled layout");
_Static_assert(sizeof(MLInputEvent) == 48, "MLInputEvent layout");
_Static_assert(offsetof(MLInputEvent, modifiers) == 32, "MLInputEvent.modifiers layout");
_Static_assert(offsetof(MLInputEvent, key_code) == 36, "MLInputEvent.key_code layout");
_Static_assert(offsetof(MLInputEvent, kind) == 38, "MLInputEvent.kind layout");
_Static_assert(offsetof(MLInputEvent, button) == 39, "MLInputEvent.button layout");
_Static_assert(offsetof(MLInputEvent, click_count) == 40, "MLInputEvent.click_count layout");
_Static_assert(offsetof(MLInputEvent, is_repeat) == 41, "MLInputEvent.is_repeat layout");
_Static_assert(sizeof(MLVideoHeader) == 32, "MLVideoHeader layout");
_Static_assert(offsetof(MLVideoHeader, width) == 16, "MLVideoHeader.width layout");
_Static_assert(offsetof(MLVideoHeader, keyframe) == 24, "MLVideoHeader.keyframe layout");
_Static_assert(offsetof(MLVideoHeader, codec) == 25, "MLVideoHeader.codec layout");
_Static_assert(sizeof(MLVideoFrame) == 96 && offsetof(MLVideoFrame, vps) == 80, "MLVideoFrame layout");
_Static_assert(offsetof(MLVideoFrame, sps) == 32, "MLVideoFrame.sps layout");
_Static_assert(offsetof(MLVideoFrame, pps) == 48, "MLVideoFrame.pps layout");
_Static_assert(offsetof(MLVideoFrame, avcc_length) == 72, "MLVideoFrame.avcc_length layout");
_Static_assert(sizeof(MLVideoPacket) == 96 && offsetof(MLVideoPacket, vps_offset) == 80, "MLVideoPacket layout");
_Static_assert(offsetof(MLVideoPacket, sps_offset) == 32, "MLVideoPacket.sps_offset layout");
_Static_assert(offsetof(MLVideoPacket, avcc_length) == 72, "MLVideoPacket.avcc_length layout");
_Static_assert(sizeof(MLSessionMessage) == 872, "MLSessionMessage layout");
_Static_assert(sizeof(MLClockSample) == 24 && offsetof(MLClockSample, host_us) == 16, "MLClockSample layout");
_Static_assert(sizeof(MLSendQueue) == 24 && offsetof(MLSendQueue, sent_bytes) == 8, "MLSendQueue layout");
_Static_assert(sizeof(MLFlowState) == 8, "MLFlowState layout");
_Static_assert(sizeof(MLClockEstimate) == 16 && offsetof(MLClockEstimate, error_us) == 8, "MLClockEstimate layout");
_Static_assert(offsetof(MLSessionMessage, audio) == 848, "MLSessionMessage.audio layout");
_Static_assert(sizeof(MLAudioMessage) == 24 && offsetof(MLAudioMessage, frames) == 4
               && offsetof(MLAudioMessage, codec) == 7 && offsetof(MLAudioMessage, payload_offset) == 8, "MLAudioMessage layout");
_Static_assert(offsetof(MLSessionMessage, cursor) == 824, "MLSessionMessage.cursor layout");
_Static_assert(sizeof(MLCursorMessage) == 24 && offsetof(MLCursorMessage, png_offset) == 8, "MLCursorMessage layout");
_Static_assert(offsetof(MLSessionMessage, clipboard) == 744, "MLSessionMessage.clipboard layout");
_Static_assert(sizeof(MLClipboardItem) == 24 && offsetof(MLClipboardItem, kind) == 16, "MLClipboardItem layout");
_Static_assert(sizeof(MLClipboardRange) == 24 && offsetof(MLClipboardRange, kind) == 16, "MLClipboardRange layout");
_Static_assert(sizeof(MLClipboardMessage) == 80 && offsetof(MLClipboardMessage, items) == 8, "MLClipboardMessage layout");
_Static_assert(offsetof(MLSessionMessage, video) == 8, "MLSessionMessage.video layout");
_Static_assert(offsetof(MLSessionMessage, input) == 104, "MLSessionMessage.input layout");
_Static_assert(offsetof(MLSessionMessage, control) == 152, "MLSessionMessage.control layout");
_Static_assert(sizeof(MLPairingCode) == 641, "MLPairingCode layout");
_Static_assert(offsetof(MLPairingCode, name) == 256, "MLPairingCode.name layout");
_Static_assert(offsetof(MLPairingCode, peer_id) == 512, "MLPairingCode.peer_id layout");
_Static_assert(offsetof(MLPairingCode, public_key) == 577, "MLPairingCode.public_key layout");
_Static_assert(offsetof(MLPairingCode, secret) == 609, "MLPairingCode.secret layout");
_Static_assert(sizeof(MLPeer) == 577, "MLPeer layout");
_Static_assert(sizeof(MLMetric) == 16, "MLMetric layout");
_Static_assert(offsetof(MLMetric, value) == 8, "MLMetric.value layout");
_Static_assert(sizeof(MLTuning) == 16, "MLTuning layout");
_Static_assert(offsetof(MLTuning, fps) == 8, "MLTuning.fps layout");
_Static_assert(sizeof(MLTelemetryMessage) == 536, "MLTelemetryMessage layout");
_Static_assert(offsetof(MLTelemetryMessage, tuning) == 8, "MLTelemetryMessage.tuning layout");
_Static_assert(offsetof(MLTelemetryMessage, metrics) == 24, "MLTelemetryMessage.metrics layout");
_Static_assert(sizeof(MLTelemetrySnapshot) == 1232, "MLTelemetrySnapshot layout");
_Static_assert(offsetof(MLTelemetrySnapshot, last_end_age_seconds) == 1064, "MLTelemetrySnapshot.last_end_age_seconds layout");
_Static_assert(offsetof(MLTelemetrySnapshot, last_end) == 1072, "MLTelemetrySnapshot.last_end layout");
_Static_assert(offsetof(MLTelemetrySnapshot, tuning) == 24, "MLTelemetrySnapshot.tuning layout");
_Static_assert(offsetof(MLTelemetrySnapshot, local) == 40, "MLTelemetrySnapshot.local layout");
_Static_assert(offsetof(MLTelemetrySnapshot, peer) == 552, "MLTelemetrySnapshot.peer layout");
_Static_assert(offsetof(MLSessionMessage, telemetry) == 208, "MLSessionMessage.telemetry layout");
_Static_assert(offsetof(MLPeer, name) == 65, "MLPeer.name layout");
_Static_assert(offsetof(MLPeer, address) == 321, "MLPeer.address layout");

/* Identity and connection lifecycle. An accepted session is the sharing host;
 * a connected session is the viewer. */
int32_t ml_session_generate_identity(uint8_t private_out[32], uint8_t public_out[32], uint8_t psk_out[32]);
int32_t ml_session_listen(const char *bind_host, uint16_t port, const uint8_t private_key[32], const uint8_t psk[32], uint64_t *out_listener);
uint16_t ml_session_listener_port(uint64_t listener);
/* timeout_ms must be 1..30000 and bounds the wait for a connection. A
 * connection accepted near that deadline still gets up to 1 s to authenticate,
 * so accept can return up to 1 s late. A bad peer fails that accept only;
 * explicitly call accept again if desired. Closing the listener cancels both. */
int32_t ml_session_accept(uint64_t listener, uint32_t timeout_ms, uint64_t *out_session);
int32_t ml_session_connect(const char *host, uint16_t port, const uint8_t pinned_public[32], const uint8_t psk[32], uint32_t timeout_ms, uint64_t *out_session);
int32_t ml_session_close(uint64_t handle);
const char *ml_session_error_string(int32_t status);

/* Typed messages. Hosts send video, geometry, input state and pong; viewers
 * send input, ping and keyframe. Invalid or misdirected messages return
 * INVALID before any byte is written and leave the session open. A failed
 * write closes the session. One writer and one reader may run concurrently. */
int32_t ml_session_send_video(uint64_t session, const MLVideoFrame *frame, uint32_t timeout_ms);
int32_t ml_session_send_input(uint64_t session, const MLInputEvent *event, uint32_t timeout_ms);
int32_t ml_session_send_control(uint64_t session, const MLControlMessage *message, uint32_t timeout_ms);
/* Both sides may send stats; only the viewer may send tuning. */
int32_t ml_session_send_telemetry(uint64_t session, const MLTelemetryMessage *message, uint32_t timeout_ms);
/* Either side may send a clipboard; at most four arrive per second. */
int32_t ml_session_send_clipboard(uint64_t session, const MLClipboardItem *items, size_t count, uint32_t timeout_ms);
/* Hosts only, to viewers that announced ML_CAPABILITY_CURSOR, at most 20 per
 * second: the pointer as a PNG (64 KiB at most), size and hotspot in points. */
int32_t ml_session_send_cursor(uint64_t session, uint16_t width, uint16_t height, uint16_t hotspot_x,
                               uint16_t hotspot_y, const uint8_t *png, size_t png_length, uint32_t timeout_ms);
/* Hosts only, to viewers that announced ML_CAPABILITY_AUDIO: one Opus packet
 * of `frames` 48 kHz frames. Viewers drop sound beyond 400 packets a second. */
int32_t ml_session_send_audio(uint64_t session, uint32_t sequence, uint16_t frames, uint8_t channels,
                              const uint8_t *payload, size_t length, uint32_t timeout_ms);
/* The viewer's playout rule, after each decoded packet is buffered: playback
 * starts at 40 ms buffered; beyond 150 ms, drop_out oldest frames bring it
 * back to 40 ms. The player sets playing to 0 itself when it runs dry. */
int32_t ml_audio_playout(uint32_t buffered_frames, uint8_t playing, uint8_t *playing_out, uint32_t *drop_out);
/* The best host-minus-viewer clock offset from up to 32 recent clock replies:
 * the shortest round trip wins, and its half is the error bound. INVALID when
 * no sample is usable (round trips over 1 s are ignored). */
int32_t ml_clock_estimate(const MLClockSample *samples, size_t count, MLClockEstimate *out);
/* Host pacing. Video in the kernel's send buffer can't be replaced by a newer
 * frame, so a host starts a frame only while the buffer holds at most the
 * queue limit: 1.5 times the bytes sent per fastest recent round trip, from
 * 128 KiB to 4 MiB. Once a second it adapts its bitrate from how long frames
 * waited: a second with 150 ms or more of waiting is congested; two such
 * seconds of the last four lower the bitrate to three quarters, and each
 * three clear seconds raise it 10% (at least 500 kbps), between 4 Mbps (or a
 * lower ceiling) and the tuned ceiling. */
int32_t ml_session_send_queue(uint64_t session, MLSendQueue *out);
uint32_t ml_flow_queue_limit(uint32_t min_round_trip_ms, uint64_t sent_bytes_per_second);
int32_t ml_flow_admits_frame(uint32_t queued_bytes, uint32_t limit);
int32_t ml_flow_next_bitrate(uint32_t current_kbps, uint32_t ceiling_kbps, uint32_t waited_ms, MLFlowState *state,
                             uint32_t *kbps_out);
/* Pass an ML_SESSION_MAX_VIDEO buffer: video, pointers and sound (to viewers)
 * and clipboard (to either side) arrive in it. TIMEOUT is retryable when no message bytes were
 * read; the deadline bounds only the wait for a new message, and a message
 * that has started gets 10 s to finish (else STALLED). Rust enforces direction,
 * geometry before video, rate limits and a 10 s idle limit (STALLED); hosts
 * silently skip pings under 250 ms and keyframe requests under 500 ms apart.
 * Any peer violation closes the session and clears rejected plaintext. */
int32_t ml_session_receive(uint64_t session, uint8_t *video_buffer, size_t capacity, MLSessionMessage *out, uint32_t timeout_ms);

/* Validation for values built before sending. */
int32_t ml_display_geometry_validate(const MLDisplayGeometry *geometry);
int32_t ml_video_dimensions_validate(uint32_t width, uint32_t height);
int32_t ml_video_frame_validate(const MLVideoFrame *frame);
int32_t ml_input_event_validate(const MLInputEvent *event);
int32_t ml_clipboard_validate(const MLClipboardItem *items, size_t count);
/* 1 when a key stays on the viewing Mac while system shortcuts such as ⌘-Tab
 * are captured for the remote Mac: Force Quit (⌘⌥Esc, optionally ⇧), Lock
 * Screen (⌃⌘Q) and full screen (⌃⌘F or Globe-F); otherwise 0. */
int32_t ml_input_keeps_local(uint16_t key_code, uint32_t modifiers);

/* Automatic viewer reconnects after an unexpected end: milliseconds to wait
 * before attempt 1...ML_RECONNECT_ATTEMPTS, then ML_SESSION_INVALID. A session
 * that stayed connected ML_RECONNECT_STABLE_SECONDS starts a new budget. */
int32_t ml_reconnect_delay_ms(uint32_t attempt);

/* Protocol negotiation: builds speak versions 4-5 and agree on the highest
 * both support; version 5 sessions start with each side's Hello. Set this
 * process's capabilities once at launch; sessions started later announce them. */
void ml_capabilities_set(uint64_t capabilities);
int32_t ml_session_protocol_version(uint64_t session);
int32_t ml_session_peer_capabilities(uint64_t session, uint64_t *out);
/* chroma_format_idc of an HEVC SPS: 1 is 4:2:0, 3 is 4:4:4. */
int32_t ml_video_hevc_chroma_format(const uint8_t *sps, size_t length);

/* Host held-input state; calls are serialized internally. accept stages one
 * event and returns what to post; call commit after posting, and any other
 * call discards the stage. Output capacity must be ML_INPUT_MAX_EVENTS. */
MLInputState *ml_input_state_new(void);
void ml_input_state_free(MLInputState *state);
/* held_buttons (nullable) receives the buttons held after the staged
 * transition, bit n for button n: nonzero makes a pointer move a drag. */
int32_t ml_input_state_accept(MLInputState *state, const MLInputEvent *event, double now, MLInputEvent *out, size_t capacity, size_t *count, uint8_t *held_buttons);
int32_t ml_input_state_commit(MLInputState *state);
int32_t ml_input_state_release_all(MLInputState *state, MLInputEvent *out, size_t capacity, size_t *count);
int32_t ml_input_state_stop(MLInputState *state, MLInputEvent *out, size_t capacity, size_t *count);

/* Pairing. Addresses use the project's shared host rule and are normalized. */
int32_t ml_address_normalize(const char *address, char *out, size_t capacity);
int32_t ml_pairing_code_for_host(const char *address, const char *computer_name, const uint8_t public_key[32], const uint8_t secret[32], MLPairingCode *out);
int32_t ml_pairing_code_encode(const MLPairingCode *code, char *out, size_t capacity);
int32_t ml_pairing_code_parse(const char *text, MLPairingCode *out);
int32_t ml_pairing_credential_encode(const MLPairingCode *code, uint8_t *out, size_t capacity, size_t *length);
int32_t ml_pairing_credential_decode(const uint8_t *data, size_t length, MLPairingCode *out);

/* Saved peer metadata (never secrets). NULL directory selects MACLINK_HOME or
 * ~/Library/Application Support/MacLink. Most recent first; at most 32. */
int32_t ml_peers_load(const char *directory, MLPeer *out, size_t capacity, size_t *count);
int32_t ml_peers_remember(const char *directory, const MLPairingCode *code, const char *address, MLPeer *out);
int32_t ml_peers_forget(const char *directory, const char *id);
int32_t ml_peers_import_legacy(const char *directory, const uint8_t *json, size_t length, size_t *imported);

/* Local telemetry: an owner-only Unix socket, telemetry.sock, in the MacLink
 * data directory (NULL selects MACLINK_HOME or Application Support). Clients
 * read one JSON snapshot per line and write {"tune": {...}} lines. No network
 * port is opened. start is a no-op when already serving; BUSY means another
 * MacLink serves it. take_tuning returns 1 with a pending command, 0 without. */
int32_t ml_telemetry_start(const char *directory);
int32_t ml_telemetry_stop(void);
int32_t ml_telemetry_publish(const MLTelemetrySnapshot *snapshot);
int32_t ml_telemetry_take_tuning(MLTuning *out);
int32_t ml_tuning_defaults(MLTuning *out);
int32_t ml_tuning_merge(const MLTuning *current, const MLTuning *update, MLTuning *out);

#ifdef __cplusplus
}
#endif
#endif
