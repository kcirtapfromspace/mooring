//! C ABI for Mooring's VNC viewer (`mooring-vnc`), for servers that are not
//! Macs. See the `ml_vnc_*` section of `include/mooring_session.h`.
//!
//! - The viewer connects only to 127.0.0.1: the local end of Mooring's SSH
//!   tunnel. No address is accepted from the caller. The caller says where the
//!   tunnel ends on the SSH host; only an end at that host's loopback address
//!   lets a server sign in with no password or the VNC password.
//! - The caller's password buffer is wiped before `ml_vnc_open` returns, on
//!   every path. The password lives only in the session until it has been
//!   sent once, and is never logged or stored.
//! - Failed sign-ins are counted per saved connection, in memory, and a new
//!   attempt is refused while the budget is spent: a brake on guessing that
//!   stays below common account lockouts.

use crate::{Error, Result};
use mooring_vnc::auth::{Route, choose_security};
use mooring_vnc::guard::{SignInDecision, SignInGuard, SignInLimits};
use mooring_vnc::session::Copied;
use mooring_vnc::{
    Credentials, Session, SessionConfig, SessionErrorKind, SessionEvent, SignInNeeds,
};
use std::collections::BTreeMap;
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::Instant;
use zeroize::Zeroizing;

const MAX_SESSIONS: usize = 4;
const MAX_KEY_TEXT: usize = 256;
/// Event JSON is far smaller; callers pass at least this much room.
pub const ML_VNC_EVENT_CAPACITY: usize = 4096;

pub const ML_VNC_COPIED: i32 = 0;
pub const ML_VNC_UNCHANGED: i32 = 1;
pub const ML_VNC_RESIZED: i32 = 2;
pub const ML_VNC_NOT_READY: i32 = 3;

pub const ML_VNC_NEEDS_NOTHING: i32 = 0;
pub const ML_VNC_NEEDS_PASSWORD: i32 = 1;
pub const ML_VNC_NEEDS_ACCOUNT: i32 = 2;
/// Host names beyond this are refused.
const MAX_HOST_TEXT: usize = 255;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MLVncRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MLVncStats {
    pub updates: u64,
    pub rectangles: u64,
    pub bytes: u64,
}

struct Entry {
    session: Session,
    host_key: String,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn sessions() -> &'static Mutex<BTreeMap<u64, Arc<Entry>>> {
    static SESSIONS: OnceLock<Mutex<BTreeMap<u64, Arc<Entry>>>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

fn guard() -> &'static Mutex<SignInGuard> {
    static GUARD: OnceLock<Mutex<SignInGuard>> = OnceLock::new();
    GUARD.get_or_init(|| Mutex::new(SignInGuard::new(SignInLimits::default())))
}

fn now_ms() -> u64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_millis() as u64
}

fn entry(id: u64) -> Result<Arc<Entry>> {
    lock(sessions()).get(&id).cloned().ok_or(Error::Closed)
}

fn ffi(action: impl FnOnce() -> Result<i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(action)) {
        Ok(Ok(status)) => status,
        Ok(Err(error)) => error as i32,
        Err(_) => Error::Internal as i32,
    }
}

/// # Safety
/// A non-null pointer must be a valid NUL-terminated string.
unsafe fn text(pointer: *const c_char, limit: usize) -> Result<String> {
    if pointer.is_null() {
        return Err(Error::Invalid);
    }
    // SAFETY: forwarded caller contract.
    let value = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|_| Error::Invalid)?;
    if value.len() > limit {
        return Err(Error::Invalid);
    }
    Ok(value.to_owned())
}

/// Whether a sign-in to `host_key` may be attempted now. Returns 0, or
/// `ML_SESSION_RATE_LIMITED` with the wait in `retry_after_ms`.
///
/// # Safety
/// `host_key` must be a valid string; non-null outputs must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_vnc_sign_in_check(
    host_key: *const c_char,
    retry_after_ms: *mut u64,
    remaining: *mut u32,
) -> i32 {
    ffi(|| {
        // SAFETY: caller contract.
        unsafe {
            if let Some(out) = retry_after_ms.as_mut() {
                *out = 0;
            }
            if let Some(out) = remaining.as_mut() {
                *out = 0;
            }
        }
        // SAFETY: caller contract.
        let host_key = unsafe { text(host_key, MAX_KEY_TEXT)? };
        match lock(guard()).check(&host_key, now_ms()) {
            SignInDecision::Allow {
                remaining: left, ..
            } => {
                // SAFETY: caller contract.
                if let Some(out) = unsafe { remaining.as_mut() } {
                    *out = left;
                }
                Ok(0)
            }
            SignInDecision::Wait {
                retry_after_ms: wait,
            } => {
                // SAFETY: caller contract.
                if let Some(out) = unsafe { retry_after_ms.as_mut() } {
                    *out = wait;
                }
                Err(Error::RateLimited)
            }
        }
    })
}

/// What signing in will ask of the person, from the security types the
/// tunnel's check read and the host its SSH tunnel ends at: writes
/// `ML_VNC_NEEDS_NOTHING`, `_PASSWORD` or `_ACCOUNT` to `needs`. Returns
/// `ML_SESSION_AUTH` (and `needs` -1) when Mooring would use none of the types.
///
/// # Safety
/// `remote_host` must be a valid string, `types` readable for `count` bytes
/// (or null with 0), and `needs` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_vnc_sign_in_needs(
    remote_host: *const c_char,
    types: *const u8,
    count: usize,
    needs: *mut i32,
) -> i32 {
    ffi(|| {
        // SAFETY: caller contract.
        let needs = unsafe { needs.as_mut() }.ok_or(Error::Invalid)?;
        *needs = -1;
        if (types.is_null() && count != 0) || count > usize::from(u8::MAX) {
            return Err(Error::Invalid);
        }
        // SAFETY: caller contract.
        let route = Route::ssh_tunnel_to(&unsafe { text(remote_host, MAX_HOST_TEXT)? });
        let offered = if count == 0 {
            &[][..]
        } else {
            // SAFETY: caller contract: readable for `count` bytes.
            unsafe { std::slice::from_raw_parts(types, count) }
        };
        let kind = choose_security(offered, route).ok_or(Error::Auth)?;
        *needs = match kind.needs() {
            SignInNeeds::Nothing => ML_VNC_NEEDS_NOTHING,
            SignInNeeds::Password => ML_VNC_NEEDS_PASSWORD,
            SignInNeeds::Account => ML_VNC_NEEDS_ACCOUNT,
        };
        Ok(0)
    })
}

/// Start one sign-in attempt to the VNC server at 127.0.0.1:`port`, the
/// local end of the SSH tunnel to `remote_host` (as the SSH host sees it).
/// The `password_length` bytes at `password` are copied and then overwritten
/// with zeros before this returns, whatever the result. With no password
/// (null and 0), the server must need none.
///
/// # Safety
/// Strings must be valid; `password` must be writable for `password_length`
/// bytes (or null with length 0); `id` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_vnc_open(
    host_key: *const c_char,
    port: u16,
    remote_host: *const c_char,
    username: *const c_char,
    password: *mut u8,
    password_length: usize,
    id: *mut u64,
) -> i32 {
    // Take the password and wipe the caller's copy before anything can fail.
    let secret = Zeroizing::new(if password.is_null() || password_length == 0 {
        Vec::new()
    } else {
        // SAFETY: caller contract: readable and writable for the length.
        let bytes = unsafe { std::slice::from_raw_parts(password, password_length) }.to_vec();
        // SAFETY: as above.
        unsafe { std::ptr::write_bytes(password, 0, password_length) };
        bytes
    });
    ffi(move || {
        // SAFETY: caller contract.
        let id = unsafe { id.as_mut() }.ok_or(Error::Invalid)?;
        *id = 0;
        if port == 0 || (password.is_null() && password_length != 0) {
            return Err(Error::Invalid);
        }
        // SAFETY: caller contract.
        let host_key = unsafe { text(host_key, MAX_KEY_TEXT)? };
        // SAFETY: caller contract.
        let route = Route::ssh_tunnel_to(&unsafe { text(remote_host, MAX_HOST_TEXT)? });
        // SAFETY: caller contract.
        let username = unsafe { text(username, mooring_vnc::auth::MAX_CREDENTIAL_BYTES)? };
        if let SignInDecision::Wait { .. } = lock(guard()).check(&host_key, now_ms()) {
            return Err(Error::RateLimited);
        }
        let credentials = if secret.is_empty() && username.is_empty() {
            None
        } else {
            Some(Credentials::new(&username, secret.to_vec()).map_err(|_| Error::Invalid)?)
        };
        drop(secret);
        let mut map = lock(sessions());
        if map.len() >= MAX_SESSIONS {
            return Err(Error::Busy);
        }
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let next = NEXT.fetch_add(1, Ordering::Relaxed);
        let session = Session::start(SessionConfig::new("127.0.0.1", port, route), credentials);
        map.insert(next, Arc::new(Entry { session, host_key }));
        *id = next;
        Ok(0)
    })
}

/// Take the next event as NUL-terminated JSON. Writes its length (0: none
/// waiting) to `length`. `capacity` must be at least `ML_VNC_EVENT_CAPACITY`.
///
/// # Safety
/// `out` must be writable for `capacity` bytes; `length` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_vnc_poll_event(
    id: u64,
    out: *mut c_char,
    capacity: usize,
    length: *mut usize,
) -> i32 {
    ffi(|| {
        // SAFETY: caller contract.
        let length = unsafe { length.as_mut() }.ok_or(Error::Invalid)?;
        *length = 0;
        if out.is_null() || capacity < ML_VNC_EVENT_CAPACITY {
            return Err(Error::Invalid);
        }
        let entry = entry(id)?;
        let Some(event) = entry.session.poll_event() else {
            return Ok(0);
        };
        match &event {
            SessionEvent::Connected { .. } => lock(guard()).succeeded(&entry.host_key),
            SessionEvent::Closed { error: Some(error) }
                if error.kind == SessionErrorKind::SignInRejected =>
            {
                lock(guard()).failed(&entry.host_key, now_ms());
            }
            _ => {}
        }
        let json = serde_json::to_vec(&event).map_err(|_| Error::Internal)?;
        if json.len() + 1 > capacity {
            return Err(Error::Buffer);
        }
        // SAFETY: `out` is writable for `capacity` bytes, checked above.
        unsafe {
            std::ptr::copy_nonoverlapping(json.as_ptr(), out.cast::<u8>(), json.len());
            *out.add(json.len()) = 0;
        }
        *length = json.len();
        Ok(0)
    })
}

/// The desktop's size once connected; `ML_SESSION_BUSY` before then.
///
/// # Safety
/// Outputs must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_vnc_frame_size(id: u64, width: *mut u32, height: *mut u32) -> i32 {
    ffi(|| {
        // SAFETY: caller contract.
        let (width, height) = unsafe { (width.as_mut(), height.as_mut()) };
        let (Some(width), Some(height)) = (width, height) else {
            return Err(Error::Invalid);
        };
        (*width, *height) = (0, 0);
        let (w, h, _) = entry(id)?.session.size().ok_or(Error::Busy)?;
        (*width, *height) = (u32::from(w), u32::from(h));
        Ok(0)
    })
}

/// Copy what changed into the caller's `width` x `height` BGRX image with
/// `stride` bytes per row. Returns `ML_VNC_COPIED` (with the region),
/// `ML_VNC_UNCHANGED`, `ML_VNC_RESIZED` (read the new size and reallocate)
/// or `ML_VNC_NOT_READY`.
///
/// # Safety
/// `pixels` must be writable for `stride * height` bytes; `region` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_vnc_copy_changes(
    id: u64,
    pixels: *mut u8,
    stride: usize,
    width: u32,
    height: u32,
    region: *mut MLVncRect,
) -> i32 {
    ffi(|| {
        // SAFETY: caller contract.
        let region = unsafe { region.as_mut() }.ok_or(Error::Invalid)?;
        *region = MLVncRect::default();
        let (Ok(width), Ok(height)) = (u16::try_from(width), u16::try_from(height)) else {
            return Err(Error::Invalid);
        };
        let size = stride
            .checked_mul(usize::from(height))
            .ok_or(Error::Invalid)?;
        if pixels.is_null() || size == 0 {
            return Err(Error::Invalid);
        }
        // SAFETY: caller contract: writable for stride * height bytes.
        let destination = unsafe { std::slice::from_raw_parts_mut(pixels, size) };
        Ok(
            match entry(id)?
                .session
                .copy_changes(destination, stride, width, height)
            {
                Copied::Region(rect) => {
                    *region = MLVncRect {
                        x: u32::from(rect.x),
                        y: u32::from(rect.y),
                        width: u32::from(rect.width),
                        height: u32::from(rect.height),
                    };
                    ML_VNC_COPIED
                }
                Copied::Unchanged => ML_VNC_UNCHANGED,
                Copied::SizeChanged { .. } => ML_VNC_RESIZED,
                Copied::NotReady => ML_VNC_NOT_READY,
            },
        )
    })
}

/// A key event: Mac virtual key code, the characters without modifiers
/// other than Shift (may be empty, never null), and 1 for down.
///
/// # Safety
/// `characters` must be a valid string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_vnc_key(
    id: u64,
    key_code: u16,
    characters: *const c_char,
    down: u8,
) -> i32 {
    ffi(|| {
        // SAFETY: caller contract.
        let characters = unsafe { text(characters, 64)? };
        entry(id)?.session.key(key_code, &characters, down != 0);
        Ok(0)
    })
}

/// Running totals since the session started, for the status line.
///
/// # Safety
/// `stats` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_vnc_stats(id: u64, stats: *mut MLVncStats) -> i32 {
    ffi(|| {
        // SAFETY: caller contract.
        let stats = unsafe { stats.as_mut() }.ok_or(Error::Invalid)?;
        *stats = MLVncStats::default();
        let totals = entry(id)?.session.stats();
        *stats = MLVncStats {
            updates: totals.updates,
            rectangles: totals.rectangles,
            bytes: totals.bytes,
        };
        Ok(0)
    })
}

/// Pointer position in desktop pixels; buttons: 1 left, 2 middle, 4 right.
#[unsafe(no_mangle)]
pub extern "C" fn ml_vnc_pointer(id: u64, x: f64, y: f64, buttons: u8) -> i32 {
    ffi(|| {
        if !x.is_finite() || !y.is_finite() {
            return Err(Error::Invalid);
        }
        entry(id)?.session.pointer(x, y, buttons);
        Ok(0)
    })
}

/// Scroll by lines; positive is right and down.
#[unsafe(no_mangle)]
pub extern "C" fn ml_vnc_scroll(id: u64, dx: f64, dy: f64) -> i32 {
    ffi(|| {
        if !dx.is_finite() || !dy.is_finite() {
            return Err(Error::Invalid);
        }
        entry(id)?.session.scroll(dx, dy);
        Ok(0)
    })
}

/// Release every held key and button, as when the window loses focus.
#[unsafe(no_mangle)]
pub extern "C" fn ml_vnc_release_all(id: u64) -> i32 {
    ffi(|| {
        entry(id)?.session.release_all();
        Ok(0)
    })
}

/// End the session: held keys and buttons are released, then the
/// connection closes. Takes at most a few hundred milliseconds.
#[unsafe(no_mangle)]
pub extern "C" fn ml_vnc_close(id: u64) -> i32 {
    ffi(|| {
        let entry = lock(sessions()).remove(&id).ok_or(Error::Closed)?;
        entry.session.stop();
        Ok(0)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::net::TcpListener;
    use std::time::Duration;

    fn event(id: u64) -> Option<serde_json::Value> {
        let mut buffer = vec![0 as c_char; ML_VNC_EVENT_CAPACITY];
        let mut length = 0;
        // SAFETY: valid buffers.
        let status =
            unsafe { ml_vnc_poll_event(id, buffer.as_mut_ptr(), buffer.len(), &mut length) };
        assert_eq!(status, 0);
        (length > 0).then(|| {
            let bytes: Vec<u8> = buffer[..length].iter().map(|b| *b as u8).collect();
            serde_json::from_slice(&bytes).unwrap()
        })
    }

    fn wait_closed(id: u64) -> serde_json::Value {
        for _ in 0..1000 {
            if let Some(event) = event(id) {
                if event["event"] == "closed" {
                    return event;
                }
            } else {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        panic!("session {id} never closed");
    }

    #[test]
    fn the_password_buffer_is_wiped_on_every_path() {
        let loopback = CString::new("127.0.0.1").unwrap();
        let key = CString::new("wipe-test").unwrap();
        let user = CString::new("alex").unwrap();
        let mut id = 0;
        // Invalid port: refused, and the buffer is still wiped.
        let mut password = *b"secret";
        // SAFETY: valid pointers.
        let status = unsafe {
            ml_vnc_open(
                key.as_ptr(),
                0,
                loopback.as_ptr(),
                user.as_ptr(),
                password.as_mut_ptr(),
                password.len(),
                &mut id,
            )
        };
        assert_eq!(status, Error::Invalid as i32);
        assert_eq!(password, [0; 6]);
        // A port nothing listens on: the attempt starts, fails to connect, and
        // a connection failure is not counted as a rejected sign-in.
        let closed_port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let mut password = *b"secret";
        // SAFETY: valid pointers.
        let status = unsafe {
            ml_vnc_open(
                key.as_ptr(),
                closed_port,
                loopback.as_ptr(),
                user.as_ptr(),
                password.as_mut_ptr(),
                password.len(),
                &mut id,
            )
        };
        assert_eq!(status, 0);
        assert_eq!(password, [0; 6]);
        assert!(id > 0);
        let closed = wait_closed(id);
        assert_eq!(closed["error"]["kind"], "connect_failed", "{closed}");
        assert_eq!(ml_vnc_close(id), 0);
        assert_eq!(ml_vnc_close(id), Error::Closed as i32);
        let mut wait = 7;
        let mut remaining = 0;
        // SAFETY: valid pointers.
        assert_eq!(
            unsafe { ml_vnc_sign_in_check(key.as_ptr(), &mut wait, &mut remaining) },
            0
        );
        assert_eq!((wait, remaining), (0, 2));
    }

    #[test]
    fn a_spent_budget_refuses_the_attempt_and_still_wipes() {
        let key = CString::new("lockout-test").unwrap();
        lock(guard()).failed("lockout-test", now_ms());
        lock(guard()).failed("lockout-test", now_ms());
        let (mut wait, mut remaining) = (0, 9);
        // SAFETY: valid pointers.
        let status = unsafe { ml_vnc_sign_in_check(key.as_ptr(), &mut wait, &mut remaining) };
        assert_eq!(status, Error::RateLimited as i32);
        assert!(wait > 9 * 60 * 1000 && remaining == 0, "{wait} {remaining}");
        let user = CString::new("alex").unwrap();
        let loopback = CString::new("127.0.0.1").unwrap();
        let mut password = *b"third try";
        let mut id = 5;
        // SAFETY: valid pointers.
        let status = unsafe {
            ml_vnc_open(
                key.as_ptr(),
                5900,
                loopback.as_ptr(),
                user.as_ptr(),
                password.as_mut_ptr(),
                password.len(),
                &mut id,
            )
        };
        assert_eq!(status, Error::RateLimited as i32);
        assert_eq!((id, password), (0, [0; 9]));
    }

    fn needs(remote_host: &str, types: &[u8]) -> (i32, i32) {
        let host = CString::new(remote_host).unwrap();
        let mut needs = 7;
        // SAFETY: valid pointers.
        let status =
            unsafe { ml_vnc_sign_in_needs(host.as_ptr(), types.as_ptr(), types.len(), &mut needs) };
        (status, needs)
    }

    #[test]
    fn what_signing_in_needs_depends_on_where_the_tunnel_ends() {
        let auth = Error::Auth as i32;
        for host in ["127.0.0.1", "::1", "localhost"] {
            assert_eq!(needs(host, &[1]), (0, ML_VNC_NEEDS_NOTHING), "{host}");
            assert_eq!(needs(host, &[2]), (0, ML_VNC_NEEDS_PASSWORD), "{host}");
            assert_eq!(needs(host, &[1, 129]), (0, ML_VNC_NEEDS_ACCOUNT), "{host}");
        }
        for host in ["192.168.1.20", "thinknvidia.local", ""] {
            assert_eq!(needs(host, &[1]), (auth, -1), "{host}");
            assert_eq!(needs(host, &[2, 30]), (auth, -1), "{host}");
            assert_eq!(needs(host, &[129, 5]), (0, ML_VNC_NEEDS_ACCOUNT), "{host}");
        }
        assert_eq!(needs("127.0.0.1", &[30]), (auth, -1));
        assert_eq!(needs("127.0.0.1", &[]), (auth, -1));
        let mut out = 7;
        // SAFETY: null types with a count are refused.
        assert_eq!(
            unsafe { ml_vnc_sign_in_needs(c"127.0.0.1".as_ptr(), std::ptr::null(), 1, &mut out) },
            Error::Invalid as i32
        );
    }

    /// A server that offers only no sign-in (as x11vnc -nopw does), serves
    /// one client, and reports the type it chose (0: none chosen).
    fn none_only_server() -> (u16, std::thread::JoinHandle<u8>) {
        use std::io::{Read, Write};
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(10)))
                .unwrap();
            stream.write_all(b"RFB 003.008\n").unwrap();
            let mut version = [0_u8; 12];
            stream.read_exact(&mut version).unwrap();
            stream.write_all(&[1, 1]).unwrap();
            let mut chosen = [0_u8; 1];
            if stream.read_exact(&mut chosen).is_err() {
                return 0;
            }
            stream.write_all(&0_u32.to_be_bytes()).unwrap();
            let mut shared = [0_u8; 1];
            stream.read_exact(&mut shared).unwrap();
            let mut init = Vec::new();
            init.extend_from_slice(&8_u16.to_be_bytes());
            init.extend_from_slice(&4_u16.to_be_bytes());
            init.extend_from_slice(&mooring_vnc::proto::PixelFormat::BGRX.encode());
            init.extend_from_slice(&13_u32.to_be_bytes());
            init.extend_from_slice(b"thinknvidia:0");
            stream.write_all(&init).unwrap();
            // Hold until the client closes.
            let mut rest = [0_u8; 256];
            while matches!(stream.read(&mut rest), Ok(n) if n > 0) {}
            chosen[0]
        });
        (port, handle)
    }

    fn open_without_password(remote_host: &str, port: u16) -> u64 {
        let key = CString::new(format!("none-{remote_host}")).unwrap();
        let host = CString::new(remote_host).unwrap();
        let mut id = 0;
        // SAFETY: valid pointers; no password.
        let status = unsafe {
            ml_vnc_open(
                key.as_ptr(),
                port,
                host.as_ptr(),
                c"".as_ptr(),
                std::ptr::null_mut(),
                0,
                &mut id,
            )
        };
        assert_eq!(status, 0);
        id
    }

    #[test]
    fn no_sign_in_works_only_through_ssh_to_the_servers_loopback() {
        // The tunnel ends at the SSH host's own loopback: signed in, no password.
        let (port, server) = none_only_server();
        let id = open_without_password("127.0.0.1", port);
        let mut seen = Vec::new();
        for _ in 0..1000 {
            match event(id) {
                Some(event) if event["event"] == "connected" => {
                    seen.push(event);
                    break;
                }
                Some(event) => seen.push(event),
                None => std::thread::sleep(Duration::from_millis(10)),
            }
        }
        let connected = seen.last().unwrap();
        assert_eq!(connected["event"], "connected", "{seen:?}");
        assert_eq!(connected["security"], "none");
        assert_eq!(connected["name"], "thinknvidia:0");
        assert!(
            seen.iter().any(|e| e["route"] == "ssh_to_loopback"),
            "{seen:?}"
        );
        assert_eq!(ml_vnc_close(id), 0);
        assert_eq!(server.join().unwrap(), 1);
        // The tunnel goes on to another machine: refused without choosing.
        let (port, server) = none_only_server();
        let id = open_without_password("192.168.1.20", port);
        let closed = wait_closed(id);
        assert_eq!(closed["error"]["kind"], "unsupported_security", "{closed}");
        assert_eq!(ml_vnc_close(id), 0);
        assert_eq!(server.join().unwrap(), 0, "type 1 must not be selected");
    }

    #[test]
    fn calls_validate_their_arguments() {
        let mut length = 1;
        let mut small = [0 as c_char; 16];
        // SAFETY: valid pointers; capacity is deliberately too small.
        assert_eq!(
            unsafe { ml_vnc_poll_event(1, small.as_mut_ptr(), small.len(), &mut length) },
            Error::Invalid as i32
        );
        assert_eq!(length, 0);
        assert_eq!(
            ml_vnc_pointer(u64::MAX, f64::NAN, 0.0, 0),
            Error::Invalid as i32
        );
        assert_eq!(ml_vnc_pointer(u64::MAX, 1.0, 1.0, 0), Error::Closed as i32);
        assert_eq!(
            ml_vnc_scroll(u64::MAX, f64::INFINITY, 0.0),
            Error::Invalid as i32
        );
        assert_eq!(ml_vnc_release_all(u64::MAX), Error::Closed as i32);
        let mut stats = MLVncStats {
            updates: 9,
            ..Default::default()
        };
        // SAFETY: valid pointer.
        assert_eq!(
            unsafe { ml_vnc_stats(u64::MAX, &mut stats) },
            Error::Closed as i32
        );
        assert_eq!(stats, MLVncStats::default());
        let (mut w, mut h) = (1, 1);
        // SAFETY: valid pointers.
        assert_eq!(
            unsafe { ml_vnc_frame_size(u64::MAX, &mut w, &mut h) },
            Error::Closed as i32
        );
        assert_eq!((w, h), (0, 0));
        let mut region = MLVncRect {
            x: 1,
            ..Default::default()
        };
        let mut pixels = [0_u8; 16];
        // SAFETY: valid pointers; width is out of range.
        assert_eq!(
            unsafe { ml_vnc_copy_changes(1, pixels.as_mut_ptr(), 16, 70_000, 1, &mut region) },
            Error::Invalid as i32
        );
        assert_eq!(region, MLVncRect::default());
        // SAFETY: null characters are refused.
        assert_eq!(
            unsafe { ml_vnc_key(1, 0, std::ptr::null(), 1) },
            Error::Invalid as i32
        );
    }
}
