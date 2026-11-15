//! Optional internet reachability beneath the existing Noise authentication.
//! Disabled builds export rejecting stubs, keeping the native ABI stable.
use crate::Error;
#[cfg(feature = "internet")]
use crate::Result;
#[cfg(feature = "internet")]
use std::ffi::CStr;
use std::ffi::c_char;
#[cfg(feature = "internet")]
use std::panic::{AssertUnwindSafe, catch_unwind};

#[cfg(feature = "internet")]
fn ffi(action: impl FnOnce() -> Result<()>) -> i32 {
    match catch_unwind(AssertUnwindSafe(action)) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => e as i32,
        Err(_) => Error::Internal as i32,
    }
}
#[cfg(feature = "internet")]
fn linked(error: mooring_connectivity::LinkError) -> Error {
    match error {
        mooring_connectivity::LinkError::Unauthorized => Error::Auth,
        mooring_connectivity::LinkError::Timeout => Error::Timeout,
        mooring_connectivity::LinkError::Cancelled | mooring_connectivity::LinkError::Closed => {
            Error::Closed
        }
        mooring_connectivity::LinkError::Invalid(_) => Error::Invalid,
        _ => Error::Io,
    }
}
#[cfg(feature = "internet")]
unsafe fn text<'a>(value: *const c_char, max: usize) -> Result<&'a str> {
    if value.is_null() {
        return Err(Error::Invalid);
    }
    let value = unsafe { CStr::from_ptr(value) }
        .to_str()
        .map_err(|_| Error::Invalid)?;
    if value.len() > max {
        return Err(Error::Invalid);
    }
    Ok(value)
}
#[cfg(feature = "internet")]
unsafe fn seed(value: *const u8) -> Result<mooring_connectivity::SecretKey> {
    if value.is_null() {
        return Err(Error::Invalid);
    }
    let mut bytes = zeroize::Zeroizing::new([0u8; 32]);
    bytes.copy_from_slice(unsafe { std::slice::from_raw_parts(value, 32) });
    Ok(mooring_connectivity::SecretKey::from_bytes(&bytes))
}
#[cfg(feature = "internet")]
unsafe fn output(value: &str, out: *mut c_char, capacity: usize) -> Result<()> {
    if out.is_null() || value.len() >= capacity {
        return Err(Error::Buffer);
    }
    unsafe {
        std::ptr::copy_nonoverlapping(value.as_ptr(), out.cast(), value.len());
        *out.add(value.len()) = 0;
    }
    Ok(())
}
#[cfg(feature = "internet")]
fn config(relay: &str, only: u8) -> Result<mooring_connectivity::Config> {
    use mooring_connectivity::{Config, ConnectivityMode};
    if only > 1 {
        return Err(Error::Invalid);
    }
    let relay = if relay.is_empty() {
        None
    } else {
        Some(relay.parse().map_err(|_| Error::Invalid)?)
    };
    Ok(Config {
        mode: if only == 1 {
            ConnectivityMode::RelayOnly
        } else if relay.is_some() {
            ConnectivityMode::Automatic
        } else {
            ConnectivityMode::DirectOnly
        },
        relay,
        ..Default::default()
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn ml_internet_available() -> u8 {
    u8::from(cfg!(feature = "internet"))
}

/// # Safety
/// The seed points to 32 bytes and public output to at least capacity bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_internet_public_id(
    private: *const u8,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if !out.is_null() && capacity > 0 {
        unsafe {
            *out = 0;
        }
    }
    #[cfg(feature = "internet")]
    return ffi(|| unsafe { output(&seed(private)?.public().to_string(), out, capacity) });
    #[cfg(not(feature = "internet"))]
    {
        let _ = (private, out, capacity);
        Error::Invalid as i32
    }
}
/// # Safety
/// Key output points to 32 writable bytes. No existing identity is read.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_internet_generate_identity(out: *mut u8) -> i32 {
    if !out.is_null() {
        unsafe {
            std::ptr::write_bytes(out, 0, 32);
        }
    }
    #[cfg(feature = "internet")]
    return ffi(|| {
        if out.is_null() {
            return Err(Error::Invalid);
        }
        let key = mooring_connectivity::SecretKey::generate();
        let bytes = zeroize::Zeroizing::new(key.to_bytes());
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, 32);
        }
        Ok(())
    });
    #[cfg(not(feature = "internet"))]
    {
        let _ = out;
        Error::Invalid as i32
    }
}
/// # Safety
/// C strings are NUL-terminated; private points to 32 bytes, ticket output has capacity bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_internet_listen(
    listener: u64,
    private: *const u8,
    allowed: *const c_char,
    relay: *const c_char,
    relay_only: u8,
    ticket: *mut c_char,
    capacity: usize,
) -> i32 {
    if !ticket.is_null() && capacity > 0 {
        unsafe {
            *ticket = 0;
        }
    }
    #[cfg(feature = "internet")]
    return ffi(|| {
        use crate::transport;
        use std::sync::atomic::Ordering;
        if ticket.is_null() || capacity == 0 {
            return Err(Error::Invalid);
        }
        unsafe {
            *ticket = 0;
        }
        let listener = transport::listener(listener)?;
        if listener.closed.load(Ordering::Acquire) {
            return Err(Error::Closed);
        }
        if listener.pin_only {
            return Err(Error::Invalid);
        }
        let allowed = unsafe { text(allowed, 128)? }
            .parse()
            .map_err(|_| Error::Invalid)?;
        let config = config(unsafe { text(relay, 2048)? }, relay_only)?;
        if listener
            .internet
            .lock()
            .map_err(|_| Error::Internal)?
            .is_some()
        {
            return Err(Error::Busy);
        }
        let server = mooring_connectivity::blocking::InternetServer::start_native(
            unsafe { seed(private)? },
            config,
            vec![allowed],
            listener.socket.local_addr().map_err(|_| Error::Io)?.port(),
        )
        .map_err(linked)?;
        let locator = server.ticket().map_err(linked)?.encode().map_err(linked)?;
        // Relay readiness may take seconds. Do not hold the listener's mutex
        // during network I/O: Stop Sharing must be able to close immediately.
        let mut state = listener.internet.lock().map_err(|_| Error::Internal)?;
        if listener.closed.load(Ordering::Acquire) {
            return Err(Error::Closed);
        }
        if state.is_some() {
            return Err(Error::Busy);
        }
        unsafe {
            output(&locator, ticket, capacity)?;
        }
        *state = Some(server);
        Ok(())
    });
    #[cfg(not(feature = "internet"))]
    {
        let _ = (
            listener, private, allowed, relay, relay_only, ticket, capacity,
        );
        Error::Invalid as i32
    }
}
/// # Safety
/// Caller buffers and pairing/key values follow the session C ABI contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_connect_internet(
    ticket: *const c_char,
    private: *const u8,
    code: *const crate::ffi::MLPairingCode,
    device_private: *const u8,
    name: *const c_char,
    timeout_ms: u32,
    out: *mut u64,
    out_mode: *mut u8,
) -> i32 {
    if !out.is_null() {
        unsafe {
            *out = 0;
        }
    }
    if !out_mode.is_null() {
        unsafe {
            *out_mode = 0;
        }
    }
    #[cfg(feature = "internet")]
    return ffi(|| {
        use crate::{ffi, transport};
        use mooring_connectivity::{
            LinkService, Ticket,
            blocking::{InternetBridge, unix_seconds},
        };
        if out.is_null() || out_mode.is_null() || code.is_null() || device_private.is_null() {
            return Err(Error::Invalid);
        }
        unsafe {
            *out = 0;
            *out_mode = 0;
        }
        let end = transport::deadline(timeout_ms)?;
        if !(100..=60_000).contains(&timeout_ms) {
            return Err(Error::Invalid);
        }
        let locator = unsafe { text(ticket, 8192)? };
        let parsed = Ticket::parse(locator, unix_seconds().map_err(linked)?).map_err(linked)?;
        let relay = parsed
            .endpoint
            .relay_urls()
            .next()
            .map(|r| r.as_str())
            .unwrap_or("");
        let mut options = config(relay, 0)?;
        options.limits.connect_ms = u64::from(timeout_ms);
        let pairing = ffi::code_in(unsafe { &*code })?;
        let name = unsafe { text(name, 256)? };
        let mut key = zeroize::Zeroizing::new([0u8; 32]);
        key.copy_from_slice(unsafe { std::slice::from_raw_parts(device_private, 32) });
        let bridge = InternetBridge::dial(
            unsafe { seed(private)? },
            options,
            locator,
            LinkService::NativeSession,
        )
        .map_err(linked)?;
        let (session, mode, _) = transport::connect_paired(
            &["127.0.0.1".into()],
            bridge.local_address().port(),
            &pairing,
            &key,
            name,
            end,
        )?;
        session
            .internet_path
            .store(3, std::sync::atomic::Ordering::Release);
        *session.internet.lock().map_err(|_| Error::Internal)? = Some(bridge);
        let id = transport::insert(transport::Handle::Session(session), None)?;
        unsafe {
            *out = id;
            *out_mode = mode as u8;
        }
        Ok(())
    });
    #[cfg(not(feature = "internet"))]
    {
        let _ = (
            ticket,
            private,
            code,
            device_private,
            name,
            timeout_ms,
            out,
            out_mode,
        );
        Error::Invalid as i32
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn ml_session_transport_path(id: u64) -> i32 {
    match crate::transport::session(id) {
        Ok(session) => session.transport_path() as i32,
        Err(error) => error as i32,
    }
}
