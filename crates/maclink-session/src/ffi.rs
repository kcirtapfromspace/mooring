//! C ABI for the Swift shell; see `include/maclink_session.h`. Every function
//! catches panics and returns a status. Outputs are cleared before work starts,
//! so a failed call never leaves partial results. Validation lives in Rust:
//! Swift converts between Apple types and these fixed-layout structs only.

use crate::control::{ControlMessage, DisplayGeometry};
use crate::input::{InputEvent, InputReducer, MAX_RELEASES};
use crate::pairing::{PairingCode, normalize_address};
use crate::peers::{MAX_PEERS, Peer, PeerStore};
use crate::transport::{self, Handle, Incoming, Listener, Outgoing, deadline};
use crate::video::{VideoFrame, VideoHeader, valid_dimensions};
use crate::{Error, Result};
use std::ffi::{CStr, c_char};
use std::net::{IpAddr, SocketAddr};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use zeroize::{Zeroize, Zeroizing};

pub const ML_TEXT_CAPACITY: usize = 256;
pub const ML_PEER_ID_CAPACITY: usize = 65;
pub const ML_PAIRING_CODE_CAPACITY: usize = 2049;
pub const ML_CREDENTIAL_CAPACITY: usize = 1024;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLDisplayGeometry {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub pixel_width: u32,
    pub pixel_height: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLControlMessage {
    pub geometry: MLDisplayGeometry,
    pub ping_id: u64,
    pub kind: u8,
    pub input_enabled: u8,
    pub reserved: [u8; 6],
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLInputEvent {
    pub x: f64,
    pub y: f64,
    pub delta_x: f64,
    pub delta_y: f64,
    pub modifiers: u32,
    pub key_code: u16,
    pub kind: u8,
    pub button: u8,
    pub click_count: u8,
    pub is_repeat: u8,
    pub reserved: [u8; 6],
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLVideoHeader {
    pub sequence: u64,
    pub timestamp_us: u64,
    pub width: u32,
    pub height: u32,
    pub keyframe: u8,
    pub reserved: [u8; 7],
}
#[repr(C)]
pub struct MLVideoFrame {
    pub header: MLVideoHeader,
    pub sps: *const u8,
    pub sps_length: usize,
    pub pps: *const u8,
    pub pps_length: usize,
    pub avcc: *const u8,
    pub avcc_length: usize,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLVideoPacket {
    pub header: MLVideoHeader,
    pub sps_offset: usize,
    pub sps_length: usize,
    pub pps_offset: usize,
    pub pps_length: usize,
    pub avcc_offset: usize,
    pub avcc_length: usize,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLSessionMessage {
    pub kind: u8,
    pub reserved: [u8; 7],
    pub video: MLVideoPacket,
    pub input: MLInputEvent,
    pub control: MLControlMessage,
}
#[repr(C)]
pub struct MLPairingCode {
    pub address: [c_char; ML_TEXT_CAPACITY],
    pub name: [c_char; ML_TEXT_CAPACITY],
    pub peer_id: [c_char; ML_PEER_ID_CAPACITY],
    pub public_key: [u8; 32],
    pub secret: [u8; 32],
}
#[repr(C)]
pub struct MLPeer {
    pub id: [c_char; ML_PEER_ID_CAPACITY],
    pub name: [c_char; ML_TEXT_CAPACITY],
    pub address: [c_char; ML_TEXT_CAPACITY],
}
/// Opaque host input state; calls are serialized internally.
pub struct MLInputState(Mutex<InputReducer>);

// Layout contract, asserted identically in include/maclink_session.h.
const _: () = {
    use std::mem::{offset_of, size_of};
    assert!(size_of::<MLDisplayGeometry>() == 40);
    assert!(offset_of!(MLDisplayGeometry, pixel_width) == 32);
    assert!(size_of::<MLControlMessage>() == 56);
    assert!(offset_of!(MLControlMessage, ping_id) == 40);
    assert!(offset_of!(MLControlMessage, kind) == 48);
    assert!(offset_of!(MLControlMessage, input_enabled) == 49);
    assert!(size_of::<MLInputEvent>() == 48);
    assert!(offset_of!(MLInputEvent, modifiers) == 32);
    assert!(offset_of!(MLInputEvent, key_code) == 36);
    assert!(offset_of!(MLInputEvent, kind) == 38);
    assert!(offset_of!(MLInputEvent, button) == 39);
    assert!(offset_of!(MLInputEvent, click_count) == 40);
    assert!(offset_of!(MLInputEvent, is_repeat) == 41);
    assert!(size_of::<MLVideoHeader>() == 32);
    assert!(offset_of!(MLVideoHeader, width) == 16);
    assert!(offset_of!(MLVideoHeader, keyframe) == 24);
    assert!(size_of::<MLVideoFrame>() == 80);
    assert!(offset_of!(MLVideoFrame, sps) == 32);
    assert!(offset_of!(MLVideoFrame, pps) == 48);
    assert!(offset_of!(MLVideoFrame, avcc_length) == 72);
    assert!(size_of::<MLVideoPacket>() == 80);
    assert!(offset_of!(MLVideoPacket, sps_offset) == 32);
    assert!(offset_of!(MLVideoPacket, avcc_length) == 72);
    assert!(size_of::<MLSessionMessage>() == 192);
    assert!(offset_of!(MLSessionMessage, video) == 8);
    assert!(offset_of!(MLSessionMessage, input) == 88);
    assert!(offset_of!(MLSessionMessage, control) == 136);
    assert!(size_of::<MLPairingCode>() == 641);
    assert!(offset_of!(MLPairingCode, name) == 256);
    assert!(offset_of!(MLPairingCode, peer_id) == 512);
    assert!(offset_of!(MLPairingCode, public_key) == 577);
    assert!(offset_of!(MLPairingCode, secret) == 609);
    assert!(size_of::<MLPeer>() == 577);
    assert!(offset_of!(MLPeer, name) == 65);
    assert!(offset_of!(MLPeer, address) == 321);
};

impl MLPairingCode {
    const EMPTY: Self = Self {
        address: [0; ML_TEXT_CAPACITY],
        name: [0; ML_TEXT_CAPACITY],
        peer_id: [0; ML_PEER_ID_CAPACITY],
        public_key: [0; 32],
        secret: [0; 32],
    };
}
impl MLPeer {
    const EMPTY: Self = Self {
        id: [0; ML_PEER_ID_CAPACITY],
        name: [0; ML_TEXT_CAPACITY],
        address: [0; ML_TEXT_CAPACITY],
    };
}

fn geometry(raw: &MLDisplayGeometry) -> DisplayGeometry {
    DisplayGeometry {
        x: raw.x,
        y: raw.y,
        width: raw.width,
        height: raw.height,
        pixel_width: raw.pixel_width,
        pixel_height: raw.pixel_height,
    }
}
fn control(raw: &MLControlMessage) -> Result<ControlMessage> {
    if raw.reserved != [0; 6] {
        return Err(Error::Invalid);
    }
    ControlMessage::from_parts(
        raw.kind,
        raw.input_enabled,
        raw.ping_id,
        geometry(&raw.geometry),
    )
}
fn control_out(message: &ControlMessage) -> MLControlMessage {
    let (input_enabled, ping_id, display) = message.parts();
    MLControlMessage {
        geometry: MLDisplayGeometry {
            x: display.x,
            y: display.y,
            width: display.width,
            height: display.height,
            pixel_width: display.pixel_width,
            pixel_height: display.pixel_height,
        },
        ping_id,
        kind: message.kind() as u8,
        input_enabled,
        reserved: [0; 6],
    }
}
fn input(raw: &MLInputEvent) -> Result<InputEvent> {
    if raw.reserved != [0; 6] {
        return Err(Error::Invalid);
    }
    InputEvent::from_parts(
        raw.kind,
        raw.key_code,
        raw.button,
        raw.click_count,
        raw.is_repeat,
        raw.modifiers,
        (raw.x, raw.y),
        (raw.delta_x, raw.delta_y),
    )
}
fn input_out(event: &InputEvent) -> MLInputEvent {
    MLInputEvent {
        x: event.x,
        y: event.y,
        delta_x: event.delta_x,
        delta_y: event.delta_y,
        modifiers: event.modifiers,
        key_code: event.key_code,
        kind: event.kind as u8,
        button: event.button,
        click_count: event.click_count,
        is_repeat: event.is_repeat.into(),
        reserved: [0; 6],
    }
}
fn header(raw: &MLVideoHeader) -> Result<VideoHeader> {
    if raw.reserved != [0; 7] || raw.keyframe > 1 {
        return Err(Error::Invalid);
    }
    Ok(VideoHeader {
        width: raw.width,
        height: raw.height,
        sequence: raw.sequence,
        timestamp_us: raw.timestamp_us,
        keyframe: raw.keyframe == 1,
    })
}
fn header_out(value: &VideoHeader) -> MLVideoHeader {
    MLVideoHeader {
        sequence: value.sequence,
        timestamp_us: value.timestamp_us,
        width: value.width,
        height: value.height,
        keyframe: value.keyframe.into(),
        reserved: [0; 7],
    }
}
/// # Safety
/// Each non-null component pointer must be readable for its length.
unsafe fn frame(raw: &MLVideoFrame) -> Result<VideoFrame<'_>> {
    let part = |pointer: *const u8, length: usize| -> Result<&[u8]> {
        match (pointer.is_null(), length) {
            (_, 0) => Ok(&[]),
            (true, _) => Err(Error::Invalid),
            // SAFETY: the ABI requires `length` readable bytes at `pointer`.
            (false, _) => Ok(unsafe { std::slice::from_raw_parts(pointer, length) }),
        }
    };
    Ok(VideoFrame {
        header: header(&raw.header)?,
        sps: part(raw.sps, raw.sps_length)?,
        pps: part(raw.pps, raw.pps_length)?,
        avcc: part(raw.avcc, raw.avcc_length)?,
    })
}

fn write_text<const N: usize>(target: &mut [c_char; N], value: &str) -> Result<()> {
    if value.len() >= N || value.as_bytes().contains(&0) {
        return Err(Error::Internal);
    }
    target.fill(0);
    for (slot, byte) in target.iter_mut().zip(value.bytes()) {
        *slot = byte as c_char;
    }
    Ok(())
}
fn read_text<const N: usize>(source: &[c_char; N]) -> Result<String> {
    let end = source
        .iter()
        .position(|value| *value == 0)
        .ok_or(Error::Invalid)?;
    String::from_utf8(source[..end].iter().map(|value| *value as u8).collect())
        .map_err(|_| Error::Invalid)
}
fn code_out(code: &PairingCode, out: &mut MLPairingCode) -> Result<()> {
    write_text(&mut out.address, &code.address)?;
    write_text(&mut out.name, &code.name)?;
    write_text(&mut out.peer_id, &code.peer_id())?;
    out.public_key = code.public_key;
    out.secret = code.secret;
    Ok(())
}
/// Strictly re-validates a code that crossed the boundary; its peer ID is
/// always recomputed from the public key.
fn code_in(raw: &MLPairingCode) -> Result<PairingCode> {
    PairingCode::new(
        &read_text(&raw.address)?,
        &read_text(&raw.name)?,
        raw.public_key,
        raw.secret,
    )
}
fn peer_out(peer: &Peer, out: &mut MLPeer) -> Result<()> {
    write_text(&mut out.id, &peer.id)?;
    write_text(&mut out.name, &peer.name)?;
    write_text(&mut out.address, &peer.address)
}

fn ffi(action: impl FnOnce() -> Result<()>) -> i32 {
    match catch_unwind(AssertUnwindSafe(action)) {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => error as i32,
        Err(_) => Error::Internal as i32,
    }
}
/// # Safety
/// A non-null pointer must be valid for writes of `T`.
unsafe fn output<'a, T>(pointer: *mut T) -> Result<&'a mut T> {
    // SAFETY: forwarded caller contract.
    unsafe { pointer.as_mut() }.ok_or(Error::Invalid)
}
/// # Safety
/// A non-null pointer must be valid for reads of `T`.
unsafe fn input_ref<'a, T>(pointer: *const T) -> Result<&'a T> {
    // SAFETY: forwarded caller contract.
    unsafe { pointer.as_ref() }.ok_or(Error::Invalid)
}
/// # Safety
/// A non-null pointer must be readable for 32 bytes.
unsafe fn key(pointer: *const u8) -> Result<Zeroizing<[u8; 32]>> {
    if pointer.is_null() {
        return Err(Error::Invalid);
    }
    let mut value = Zeroizing::new([0; 32]);
    // SAFETY: the ABI requires a readable 32-byte caller buffer for a non-null key.
    unsafe { std::ptr::copy_nonoverlapping(pointer, value.as_mut_ptr(), 32) };
    Ok(value)
}
/// # Safety
/// A non-null pointer must be a valid NUL-terminated string.
unsafe fn text(pointer: *const c_char) -> Result<String> {
    if pointer.is_null() {
        return Err(Error::Invalid);
    }
    // SAFETY: forwarded caller contract.
    let value = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|_| Error::Invalid)?;
    if value.len() > 4096 {
        return Err(Error::Invalid);
    }
    Ok(value.to_owned())
}
/// # Safety
/// As for `text`; null selects the default MacLink support directory.
unsafe fn store(directory: *const c_char) -> Result<PeerStore> {
    if directory.is_null() {
        return PeerStore::default_location();
    }
    let path = unsafe { text(directory)? };
    if path.is_empty() {
        return Err(Error::Invalid);
    }
    Ok(PeerStore::new(PathBuf::from(path)))
}
/// # Safety
/// `out` must be writable for `capacity` events and `count` for one usize.
unsafe fn events_out(
    events: &[InputEvent],
    out: *mut MLInputEvent,
    count: *mut usize,
) -> Result<()> {
    if events.len() > MAX_RELEASES {
        return Err(Error::Internal);
    }
    for (index, event) in events.iter().enumerate() {
        // SAFETY: callers checked capacity >= MAX_RELEASES.
        unsafe { *out.add(index) = input_out(event) };
    }
    unsafe { *count = events.len() };
    Ok(())
}

// Identity, listener and connection lifecycle.

/// Generate a responder identity and independent random pairing credential.
/// # Safety
/// All three pointers must designate distinct writable buffers of 32 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_generate_identity(
    private_out: *mut u8,
    public_out: *mut u8,
    psk_out: *mut u8,
) -> i32 {
    ffi(|| {
        if private_out.is_null() || public_out.is_null() || psk_out.is_null() {
            return Err(Error::Invalid);
        }
        let pair = transport::builder()?
            .generate_keypair()
            .map_err(|_| Error::Internal)?;
        let private = Zeroizing::new(pair.private);
        let mut psk = Zeroizing::new([0_u8; 32]);
        getrandom::fill(&mut *psk).map_err(|_| Error::Internal)?;
        // SAFETY: caller promises three distinct writable key buffers.
        unsafe {
            std::ptr::copy_nonoverlapping(private.as_ptr(), private_out, 32);
            std::ptr::copy_nonoverlapping(pair.public.as_ptr(), public_out, 32);
            std::ptr::copy_nonoverlapping(psk.as_ptr(), psk_out, 32);
        }
        Ok(())
    })
}
/// Start an explicit listener on a numeric local bind address.
/// # Safety
/// Host must be NUL terminated, keys readable for 32 bytes, and out writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_listen(
    bind_host: *const c_char,
    port: u16,
    private: *const u8,
    psk: *const u8,
    out: *mut u64,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = 0;
        let ip = unsafe { text(bind_host)? }
            .parse::<IpAddr>()
            .map_err(|_| Error::Invalid)?;
        let listener = Listener::bind(
            SocketAddr::new(ip, port),
            unsafe { key(private)? },
            unsafe { key(psk)? },
        )?;
        *out = transport::insert(Handle::Listener(Arc::new(listener)), None)?;
        Ok(())
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ml_session_listener_port(id: u64) -> u16 {
    catch_unwind(AssertUnwindSafe(|| {
        transport::listener(id)
            .ok()?
            .socket
            .local_addr()
            .ok()
            .map(|address| address.port())
    }))
    .ok()
    .flatten()
    .unwrap_or(0)
}
/// Accept and authenticate one peer before publishing a host session handle.
/// # Safety
/// Out must point to a writable u64 for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_accept(id: u64, timeout_ms: u32, out: *mut u64) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = 0;
        let listener = transport::listener(id)?;
        let session = listener.accept(deadline(timeout_ms)?)?;
        *out = transport::insert(Handle::Session(session), Some(&listener))?;
        Ok(())
    })
}
/// Connect as a viewer using a pinned public key and random pairing secret.
/// # Safety
/// Host is NUL terminated, keys are readable 32-byte buffers, out is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_connect(
    address: *const c_char,
    port: u16,
    public: *const u8,
    psk: *const u8,
    timeout_ms: u32,
    out: *mut u64,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = 0;
        let end = deadline(timeout_ms)?;
        let host = normalize_address(&unsafe { text(address)? })?;
        let (public, psk) = (unsafe { key(public)? }, unsafe { key(psk)? });
        let session = transport::connect(&host, port, &public, &psk, end)?;
        *out = transport::insert(Handle::Session(session), None)?;
        Ok(())
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ml_session_close(id: u64) -> i32 {
    ffi(|| transport::close(id))
}
#[unsafe(no_mangle)]
pub extern "C" fn ml_session_error_string(status: i32) -> *const c_char {
    match status {
        0 => c"Success",
        -1 => c"Invalid argument or message",
        -2 => c"Network operation failed",
        -3 => c"Operation timed out",
        -4 => c"Authentication failed",
        -5 => c"The other Mac sent an invalid or incomplete session message",
        -6 => c"Session closed",
        -7 => c"Receive buffer too small; session closed",
        -8 => c"Operation busy",
        -10 => c"The other Mac sent messages too quickly",
        -11 => c"The other Mac stopped responding",
        -12 => c"MacLink could not read or save paired Macs",
        _ => c"Internal session error",
    }
    .as_ptr()
}

// Typed session messages.

/// # Safety
/// `frame` and each non-null component must be readable during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_send_video(
    id: u64,
    frame_in: *const MLVideoFrame,
    timeout_ms: u32,
) -> i32 {
    ffi(|| {
        let value = unsafe { frame(input_ref(frame_in)?)? };
        transport::session(id)?.send_message(&Outgoing::Video(value), deadline(timeout_ms)?)
    })
}
/// # Safety
/// `event` must be readable during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_send_input(
    id: u64,
    event: *const MLInputEvent,
    timeout_ms: u32,
) -> i32 {
    ffi(|| {
        let value = input(unsafe { input_ref(event)? })?;
        transport::session(id)?.send_message(&Outgoing::Input(value), deadline(timeout_ms)?)
    })
}
/// # Safety
/// `message` must be readable during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_send_control(
    id: u64,
    message: *const MLControlMessage,
    timeout_ms: u32,
) -> i32 {
    ffi(|| {
        let value = control(unsafe { input_ref(message)? })?;
        transport::session(id)?.send_message(&Outgoing::Control(value), deadline(timeout_ms)?)
    })
}
/// # Safety
/// `out` must be writable; a non-null `video_buffer` writable for `capacity`
/// bytes and not aliased by another call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_receive(
    id: u64,
    video_buffer: *mut u8,
    capacity: usize,
    out: *mut MLSessionMessage,
    timeout_ms: u32,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = MLSessionMessage::default();
        if video_buffer.is_null() && capacity != 0 {
            return Err(Error::Invalid);
        }
        let video: &mut [u8] = if capacity == 0 {
            &mut []
        } else {
            // SAFETY: caller promises a writable, unaliased buffer of `capacity`.
            unsafe {
                std::slice::from_raw_parts_mut(video_buffer, capacity.min(transport::MAX_VIDEO))
            }
        };
        let message = transport::session(id)?.receive_message(video, deadline(timeout_ms)?)?;
        match message {
            Incoming::Video(packet) => {
                out.kind = crate::policy::VIDEO;
                out.video = MLVideoPacket {
                    header: header_out(&packet.header),
                    sps_offset: packet.sps.start,
                    sps_length: packet.sps.len(),
                    pps_offset: packet.pps.start,
                    pps_length: packet.pps.len(),
                    avcc_offset: packet.avcc.start,
                    avcc_length: packet.avcc.len(),
                };
            }
            Incoming::Input(event) => {
                out.kind = crate::policy::INPUT;
                out.input = input_out(&event);
            }
            Incoming::Control(message) => {
                out.kind = crate::policy::CONTROL;
                out.control = control_out(&message);
            }
        }
        Ok(())
    })
}

// Stateless validation for values Swift builds before sending.

/// # Safety
/// `value` must be readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_display_geometry_validate(value: *const MLDisplayGeometry) -> i32 {
    ffi(|| {
        if geometry(unsafe { input_ref(value)? }).is_valid() {
            Ok(())
        } else {
            Err(Error::Invalid)
        }
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ml_video_dimensions_validate(width: u32, height: u32) -> i32 {
    ffi(|| {
        if valid_dimensions(width, height) {
            Ok(())
        } else {
            Err(Error::Invalid)
        }
    })
}
/// # Safety
/// As for `ml_session_send_video`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_video_frame_validate(value: *const MLVideoFrame) -> i32 {
    ffi(|| unsafe { frame(input_ref(value)?)? }.validate())
}
/// # Safety
/// `event` must be readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_input_event_validate(event: *const MLInputEvent) -> i32 {
    ffi(|| input(unsafe { input_ref(event)? }).map(|_| ()))
}

// Host input state.

#[unsafe(no_mangle)]
pub extern "C" fn ml_input_state_new() -> *mut MLInputState {
    Box::into_raw(Box::new(MLInputState(Mutex::new(InputReducer::default()))))
}
/// # Safety
/// `state` must come from `ml_input_state_new` and not be used afterward.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_input_state_free(state: *mut MLInputState) {
    if !state.is_null() {
        // SAFETY: ownership returns from the caller exactly once.
        drop(unsafe { Box::from_raw(state) });
    }
}
/// # Safety
/// `state` is live; `out` holds `capacity` events; `count` is writable.
unsafe fn with_state(
    state: *const MLInputState,
    out: *mut MLInputEvent,
    capacity: usize,
    count: *mut usize,
    held_buttons: *mut u8,
    action: impl FnOnce(&mut InputReducer) -> Result<(Vec<InputEvent>, u8)>,
) -> i32 {
    ffi(|| {
        let count = unsafe { output(count)? };
        *count = 0;
        let mut held = unsafe { held_buttons.as_mut() };
        if let Some(held) = held.as_deref_mut() {
            *held = 0;
        }
        if out.is_null() || capacity < MAX_RELEASES {
            return Err(Error::Invalid);
        }
        let state = unsafe { input_ref(state)? };
        let (events, mask) = action(&mut *state.0.lock().map_err(|_| Error::Internal)?)?;
        unsafe { events_out(&events, out, count)? };
        if let Some(held) = held {
            *held = mask;
        }
        Ok(())
    })
}
/// Stage one received event; post the returned events, then commit. Any other
/// call discards an uncommitted stage. Capacity must be at least 131.
/// `held_buttons` (nullable) receives the buttons held afterward, bit n for
/// button n, which decides whether a pointer move is a drag.
/// # Safety
/// As for `with_state`; `event` must be readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_input_state_accept(
    state: *mut MLInputState,
    event: *const MLInputEvent,
    now: f64,
    out: *mut MLInputEvent,
    capacity: usize,
    count: *mut usize,
    held_buttons: *mut u8,
) -> i32 {
    unsafe {
        with_state(state, out, capacity, count, held_buttons, |reducer| {
            reducer.accept(&input(input_ref(event)?)?, now)
        })
    }
}
/// # Safety
/// `state` must be live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_input_state_commit(state: *mut MLInputState) -> i32 {
    ffi(|| {
        unsafe { input_ref(state)? }
            .0
            .lock()
            .map_err(|_| Error::Internal)?
            .commit();
        Ok(())
    })
}
/// Forget every held key and button, returning the releases to post.
/// # Safety
/// As for `with_state`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_input_state_release_all(
    state: *mut MLInputState,
    out: *mut MLInputEvent,
    capacity: usize,
    count: *mut usize,
) -> i32 {
    unsafe {
        with_state(
            state,
            out,
            capacity,
            count,
            std::ptr::null_mut(),
            |reducer| Ok((reducer.release_all(), 0)),
        )
    }
}
/// Permanently end the state after releasing everything it holds.
/// # Safety
/// As for `with_state`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_input_state_stop(
    state: *mut MLInputState,
    out: *mut MLInputEvent,
    capacity: usize,
    count: *mut usize,
) -> i32 {
    unsafe {
        with_state(
            state,
            out,
            capacity,
            count,
            std::ptr::null_mut(),
            |reducer| Ok((reducer.stop(), 0)),
        )
    }
}

// Pairing codes and credentials.

/// # Safety
/// `address` is a NUL-terminated string; `out` is writable for `capacity`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_address_normalize(
    address: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    ffi(|| {
        if out.is_null() || capacity < ML_TEXT_CAPACITY {
            return Err(Error::Invalid);
        }
        // SAFETY: caller promises `capacity` writable bytes.
        let target = unsafe { &mut *(out as *mut [c_char; ML_TEXT_CAPACITY]) };
        target.fill(0);
        write_text(target, &normalize_address(&unsafe { text(address)? })?)
    })
}
/// The sharing Mac's own code. The computer name is normalized, never rejected.
/// # Safety
/// Strings are NUL terminated, keys readable for 32 bytes, `out` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_pairing_code_for_host(
    address: *const c_char,
    computer_name: *const c_char,
    public_key: *const u8,
    secret: *const u8,
    out: *mut MLPairingCode,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = MLPairingCode::EMPTY;
        let code = PairingCode::for_host(
            &unsafe { text(address)? },
            &unsafe { text(computer_name)? },
            *unsafe { key(public_key)? },
            *unsafe { key(secret)? },
        )?;
        code_out(&code, out)
    })
}
/// Writes the NUL-terminated `MLP1.` text. Capacity must be at least 2049.
/// # Safety
/// `code` readable; `out` writable for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_pairing_code_encode(
    code: *const MLPairingCode,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    ffi(|| {
        if out.is_null() || capacity < ML_PAIRING_CODE_CAPACITY {
            return Err(Error::Invalid);
        }
        // SAFETY: caller promises `capacity` writable bytes.
        let target = unsafe { &mut *(out as *mut [c_char; ML_PAIRING_CODE_CAPACITY]) };
        target.fill(0);
        let encoded = code_in(unsafe { input_ref(code)? })?.encode();
        write_text(target, &encoded)
    })
}
/// # Safety
/// `text` is NUL terminated; `out` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_pairing_code_parse(
    text_in: *const c_char,
    out: *mut MLPairingCode,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = MLPairingCode::EMPTY;
        let mut value = Zeroizing::new(unsafe { text(text_in)? });
        let code = PairingCode::parse(&value)?;
        value.zeroize();
        code_out(&code, out)
    })
}
/// The Keychain representation. Capacity must be at least 1024.
/// # Safety
/// `code` readable; `out` writable for `capacity`; `length` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_pairing_credential_encode(
    code: *const MLPairingCode,
    out: *mut u8,
    capacity: usize,
    length: *mut usize,
) -> i32 {
    ffi(|| {
        let length = unsafe { output(length)? };
        *length = 0;
        if out.is_null() || capacity < ML_CREDENTIAL_CAPACITY {
            return Err(Error::Invalid);
        }
        let bytes = code_in(unsafe { input_ref(code)? })?.credential();
        if bytes.len() > capacity {
            return Err(Error::Internal);
        }
        // SAFETY: caller promises `capacity` writable bytes.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
        *length = bytes.len();
        Ok(())
    })
}
/// # Safety
/// `data` readable for `length` bytes; `out` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_pairing_credential_decode(
    data: *const u8,
    length: usize,
    out: *mut MLPairingCode,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = MLPairingCode::EMPTY;
        if data.is_null() {
            return Err(Error::Invalid);
        }
        // SAFETY: caller promises `length` readable bytes.
        let bytes = unsafe { std::slice::from_raw_parts(data, length) };
        code_out(&PairingCode::from_credential(bytes)?, out)
    })
}

// Saved peers. A null directory selects MACLINK_HOME or Application Support.

/// Capacity must be at least 32.
/// # Safety
/// `directory` null or NUL terminated; `out` writable for `capacity` peers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_peers_load(
    directory: *const c_char,
    out: *mut MLPeer,
    capacity: usize,
    count: *mut usize,
) -> i32 {
    ffi(|| {
        let count = unsafe { output(count)? };
        *count = 0;
        if out.is_null() || capacity < MAX_PEERS {
            return Err(Error::Invalid);
        }
        let peers = unsafe { store(directory)? }.load()?;
        for (index, peer) in peers.iter().enumerate() {
            // SAFETY: capacity was checked against the store's bound.
            let slot = unsafe { &mut *out.add(index) };
            *slot = MLPeer::EMPTY;
            peer_out(peer, slot)?;
        }
        *count = peers.len();
        Ok(())
    })
}
/// Save or refresh a peer at the front of the list after it connects.
/// # Safety
/// Strings null (directory only) or NUL terminated; `code` readable; `out`
/// null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_peers_remember(
    directory: *const c_char,
    code: *const MLPairingCode,
    address: *const c_char,
    out: *mut MLPeer,
) -> i32 {
    ffi(|| {
        if let Some(out) = unsafe { out.as_mut() } {
            *out = MLPeer::EMPTY;
        }
        let code = code_in(unsafe { input_ref(code)? })?;
        let peer = unsafe { store(directory)? }.remember(&code, &unsafe { text(address)? })?;
        match unsafe { out.as_mut() } {
            Some(out) => peer_out(&peer, out),
            None => Ok(()),
        }
    })
}
/// Import the earlier preference list once; a no-op when a store exists.
/// # Safety
/// `directory` null or NUL terminated; `json` readable for `length`;
/// `imported` null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_peers_import_legacy(
    directory: *const c_char,
    json: *const u8,
    length: usize,
    imported: *mut usize,
) -> i32 {
    ffi(|| {
        if let Some(imported) = unsafe { imported.as_mut() } {
            *imported = 0;
        }
        if json.is_null() {
            return Err(Error::Invalid);
        }
        // SAFETY: caller promises `length` readable bytes.
        let count = unsafe { store(directory)? }
            .import_legacy(unsafe { std::slice::from_raw_parts(json, length) })?;
        if let Some(imported) = unsafe { imported.as_mut() } {
            *imported = count;
        }
        Ok(())
    })
}
