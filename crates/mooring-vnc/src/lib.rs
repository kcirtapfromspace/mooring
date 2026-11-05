//! A VNC (RFB) client for Mooring's own viewer, for servers that are not
//! Macs, such as wayvnc on Linux.
//!
//! - Sign-in: RSA-AES (security types 129 and 5, as wayvnc and TigerVNC
//!   implement them), or none when the server asks for none. Apple
//!   Diffie-Hellman (30) is never chosen: it only protects the password, and
//!   wayvnc 0.10.2 with neatvnc 1.0.3 aborts when a client selects it.
//! - The password is used once, for the attempt the person started, and is
//!   wiped from memory afterwards. It is never stored or logged, and a failed
//!   attempt is never retried automatically. [`SignInGuard`] stops further
//!   attempts after repeated failures: a brake on guessing that stays below
//!   common account lockouts.
//! - Picture: Raw, CopyRect and ZRLE into a 32-bit BGRX framebuffer, plus
//!   desktop resizes. Input: X keysyms, pointer buttons and scrolling, with
//!   every held key and button released when the session ends.
//! - Every length the server sends is bounded before memory is allocated.
//!
//! Mooring only connects this client through its SSH tunnel, which
//! authenticates the host and encrypts the connection.

pub mod auth;
pub mod framebuffer;
pub mod guard;
pub mod keysym;
pub mod proto;
pub mod session;
pub mod stream;
pub mod zrle;

#[cfg(test)]
mod fake_server;

pub use auth::{Credentials, SecurityKind};
pub use framebuffer::{Framebuffer, Rect};
pub use guard::{SignInDecision, SignInGuard};
pub use session::{Session, SessionConfig, SessionError, SessionErrorKind, SessionEvent};
