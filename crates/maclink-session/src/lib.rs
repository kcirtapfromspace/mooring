//! Experimental authenticated duplex session for the MacLink LAN prototype.
//!
//! Noise IK pins the responder identity and proves each viewer's own key, which
//! the host approves once with a one-time secret (IKpsk1). Hosts that shared
//! before per-device keys also accept, for a while, the older NKpsk0 handshake
//! with its long-lived 32-byte pairing secret. `snow` is MIT OR Apache-2.0 and explicitly reports no
//! formal audit: https://github.com/mcginty/snow. This crate is not an audited
//! transport. No cryptographic primitives are implemented here.
//!
//! Rust owns the session protocol: sockets, framing, deadlines, typed wire
//! formats and their validation, per-role direction and rate policy, the host's
//! held-input state, shared-clipboard validation, pairing codes, saved peer
//! metadata, and the host's approved devices. Swift owns Apple media/input/pasteboard APIs, Keychain storage,
//! caller buffers and the UI. Nothing listens automatically.

mod audio;
mod clipboard;
mod clock;
mod control;
mod cursor;
mod devices;
pub mod ffi;
mod files;
mod flow;
mod input;
mod pairing;
mod peers;
mod policy;
mod telemetry;
mod transport;
mod video;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub(crate) enum Error {
    Invalid = -1,
    Io = -2,
    Timeout = -3,
    Auth = -4,
    Protocol = -5,
    Closed = -6,
    Buffer = -7,
    Busy = -8,
    Internal = -9,
    RateLimited = -10,
    Stalled = -11,
    Storage = -12,
}
pub(crate) type Result<T> = std::result::Result<T, Error>;

#[cfg(test)]
mod tests;
