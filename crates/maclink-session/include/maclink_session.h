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
enum { ML_SESSION_VIDEO = 1, ML_SESSION_INPUT = 2, ML_SESSION_CONTROL = 3 };
enum {
    ML_CONTROL_GEOMETRY = 1, ML_CONTROL_INPUT_STATE = 2, ML_CONTROL_PING = 3,
    ML_CONTROL_PONG = 4, ML_CONTROL_KEYFRAME = 5
};
enum {
    ML_INPUT_KEY_DOWN = 1, ML_INPUT_KEY_UP = 2, ML_INPUT_POINTER_MOVE = 3,
    ML_INPUT_POINTER_DOWN = 4, ML_INPUT_POINTER_UP = 5, ML_INPUT_SCROLL = 6,
    ML_INPUT_RELEASE_ALL = 7
};
enum {
    ML_MODIFIER_SHIFT = 1 << 0, ML_MODIFIER_CONTROL = 1 << 1, ML_MODIFIER_OPTION = 1 << 2,
    ML_MODIFIER_COMMAND = 1 << 3, ML_MODIFIER_CAPS_LOCK = 1 << 4, ML_MODIFIER_FUNCTION = 1 << 5
};
#define ML_SESSION_MAX_VIDEO 12582912u /* 12 MiB; a literal so Swift imports it */
#define ML_SESSION_DEFAULT_PORT 45900u
#define ML_VIDEO_HEADER_BYTES 44u
#define ML_INPUT_MAX_EVENTS 131u
#define ML_TEXT_CAPACITY 256u
#define ML_PEER_ID_CAPACITY 65u
#define ML_PAIRING_CODE_CAPACITY 2049u
#define ML_CREDENTIAL_CAPACITY 1024u
#define ML_PEERS_MAX 32u

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
    uint8_t reserved[7];
} MLVideoHeader;

/* One H.264 access unit to send: SPS and PPS parameter sets and an AVCC
 * bitstream with four-byte NAL lengths and no in-band configuration. */
typedef struct {
    MLVideoHeader header;
    const uint8_t *sps; size_t sps_length;
    const uint8_t *pps; size_t pps_length;
    const uint8_t *avcc; size_t avcc_length;
} MLVideoFrame;

/* A validated received packet; components are ranges in the caller's buffer. */
typedef struct {
    MLVideoHeader header;
    size_t sps_offset, sps_length;
    size_t pps_offset, pps_length;
    size_t avcc_offset, avcc_length;
} MLVideoPacket;

/* kind selects the one populated member. */
typedef struct {
    uint8_t kind;
    uint8_t reserved[7];
    MLVideoPacket video;
    MLInputEvent input;
    MLControlMessage control;
} MLSessionMessage;

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
_Static_assert(sizeof(MLVideoFrame) == 80, "MLVideoFrame layout");
_Static_assert(offsetof(MLVideoFrame, sps) == 32, "MLVideoFrame.sps layout");
_Static_assert(offsetof(MLVideoFrame, pps) == 48, "MLVideoFrame.pps layout");
_Static_assert(offsetof(MLVideoFrame, avcc_length) == 72, "MLVideoFrame.avcc_length layout");
_Static_assert(sizeof(MLVideoPacket) == 80, "MLVideoPacket layout");
_Static_assert(offsetof(MLVideoPacket, sps_offset) == 32, "MLVideoPacket.sps_offset layout");
_Static_assert(offsetof(MLVideoPacket, avcc_length) == 72, "MLVideoPacket.avcc_length layout");
_Static_assert(sizeof(MLSessionMessage) == 192, "MLSessionMessage layout");
_Static_assert(offsetof(MLSessionMessage, video) == 8, "MLSessionMessage.video layout");
_Static_assert(offsetof(MLSessionMessage, input) == 88, "MLSessionMessage.input layout");
_Static_assert(offsetof(MLSessionMessage, control) == 136, "MLSessionMessage.control layout");
_Static_assert(sizeof(MLPairingCode) == 641, "MLPairingCode layout");
_Static_assert(offsetof(MLPairingCode, name) == 256, "MLPairingCode.name layout");
_Static_assert(offsetof(MLPairingCode, peer_id) == 512, "MLPairingCode.peer_id layout");
_Static_assert(offsetof(MLPairingCode, public_key) == 577, "MLPairingCode.public_key layout");
_Static_assert(offsetof(MLPairingCode, secret) == 609, "MLPairingCode.secret layout");
_Static_assert(sizeof(MLPeer) == 577, "MLPeer layout");
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
/* Viewers pass an ML_SESSION_MAX_VIDEO buffer; hosts may pass NULL and 0.
 * TIMEOUT is retryable when no frame bytes were read. Rust enforces direction,
 * geometry before video, rate limits and a 10 s idle limit (STALLED); hosts
 * silently skip pings under 250 ms and keyframe requests under 500 ms apart.
 * Any peer violation closes the session and clears rejected plaintext. */
int32_t ml_session_receive(uint64_t session, uint8_t *video_buffer, size_t capacity, MLSessionMessage *out, uint32_t timeout_ms);

/* Validation for values built before sending. */
int32_t ml_display_geometry_validate(const MLDisplayGeometry *geometry);
int32_t ml_video_dimensions_validate(uint32_t width, uint32_t height);
int32_t ml_video_frame_validate(const MLVideoFrame *frame);
int32_t ml_input_event_validate(const MLInputEvent *event);

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

#ifdef __cplusplus
}
#endif
#endif
