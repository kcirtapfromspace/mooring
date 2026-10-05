//! C ABI for the Swift shell; see `include/mooring_session.h`. Every function
//! catches panics and returns a status. Outputs are cleared before work starts,
//! so a failed call never leaves partial results. Validation lives in Rust:
//! Swift converts between Apple types and these fixed-layout structs only.

use crate::clipboard::{self, ClipboardKind, MAX_CLIPBOARD, MAX_CLIPBOARD_BYTES, MAX_ITEMS};
use crate::control::{ControlMessage, DisplayGeometry};
use crate::devices::{DeviceStore, LegacyAction, Via};
use crate::input::{InputEvent, InputReducer, MAX_RELEASES, keeps_local};
use crate::pairing::{CodeKind, PairingCode, normalize_address};
use crate::peers::{MAX_PEERS, Peer, PeerStore};
use crate::policy::{RECONNECT_DELAYS, RECONNECT_STABLE, reconnect_delay};
use crate::telemetry::{
    MAX_METRICS, Metric, Server, Snapshot, Stats, TelemetryMessage, Tuning, validate_reason,
    validate_stats,
};
use crate::transport::{self, Handle, Incoming, Listener, Outgoing, deadline};
use crate::video::{Codec, VideoFrame, VideoHeader, hevc_chroma_format, valid_dimensions};
use crate::{Error, Result};
use std::ffi::{CStr, c_char};
use std::net::{IpAddr, SocketAddr};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use zeroize::{Zeroize, Zeroizing};

pub const ML_TEXT_CAPACITY: usize = 256;
pub const ML_PEER_ID_CAPACITY: usize = 65;
/// A Mac's other addresses, joined by single spaces, and the NUL.
pub const ML_ALTERNATES_CAPACITY: usize = crate::pairing::MAX_ALTERNATES_TEXT + 1;
pub const ML_ADDRESSES_MAX: usize = crate::pairing::MAX_ADDRESSES;
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
    /// 0 or 1: H.264; 2: HEVC.
    pub codec: u8,
    pub reserved: [u8; 6],
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
    /// HEVC only: the video parameter set.
    pub vps: *const u8,
    pub vps_length: usize,
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
    pub vps_offset: usize,
    pub vps_length: usize,
}
/// One clipboard representation to send.
#[repr(C)]
pub struct MLClipboardItem {
    pub bytes: *const u8,
    pub length: usize,
    pub kind: u8,
    pub reserved: [u8; 7],
}
/// One received representation, at `offset` in the caller's buffer.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLClipboardRange {
    pub offset: usize,
    pub length: usize,
    pub kind: u8,
    pub reserved: [u8; 7],
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLClipboardMessage {
    pub count: u8,
    pub reserved: [u8; 7],
    pub items: [MLClipboardRange; MAX_ITEMS],
}
/// A received pointer image: its size and hotspot in points, and the PNG at
/// `png_offset` in the caller's buffer.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLCursorMessage {
    pub width: u16,
    pub height: u16,
    pub hotspot_x: u16,
    pub hotspot_y: u16,
    pub png_offset: usize,
    pub png_length: usize,
}
/// Pacing history the host keeps between once-a-second bitrate updates.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLFlowState {
    pub recent: u32,
    pub clear_seconds: u32,
    /// The link's rate when it last ran out, kbit/s; 0 if unknown.
    pub limit_kbps: u32,
    pub held_seconds: u32,
    /// Recent peak of what was sent, kbit/s.
    pub peak_kbps: u32,
}
/// Measures the link's rate while video waits in the send buffer; start
/// zeroed. Fields are the meter's own.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLLinkMeter {
    pub last_ms: u64,
    pub last_sent: u64,
    pub busy_ms: u64,
    pub busy_bytes: u64,
    pub idle_ms: u64,
    pub last_queued: u32,
    pub started: u32,
}
/// The kernel's view of a session's sending side, for the host's pacing.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLSendQueue {
    pub queued_bytes: u32,
    pub round_trip_ms: u32,
    pub sent_bytes: u64,
    pub retransmitted_bytes: u64,
}
/// One clock reply: the viewer's send and receive times for the ping, and the
/// host's time in its reply, all in microseconds of CoreMedia host time.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLClockSample {
    pub sent_us: u64,
    pub received_us: u64,
    pub host_us: u64,
}
/// Host time minus viewer time, and its error bound, in microseconds.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLClockEstimate {
    pub offset_us: i64,
    pub error_us: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLFrameLatency {
    pub total_us: u64,
    pub to_viewer_us: u64,
    pub display_wait_us: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLHostWake {
    pub attempts: u32,
    pub last_activity_ms: u32,
}
/// A received Opus packet at `payload_offset` in the caller's buffer, with
/// its sequence number and duration in 48 kHz frames.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLAudioMessage {
    pub sequence: u32,
    pub frames: u16,
    pub channels: u8,
    pub codec: u8,
    pub payload_offset: usize,
    pub payload_length: usize,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLSessionMessage {
    pub kind: u8,
    pub reserved: [u8; 7],
    pub video: MLVideoPacket,
    pub input: MLInputEvent,
    pub control: MLControlMessage,
    pub telemetry: MLTelemetryMessage,
    pub clipboard: MLClipboardMessage,
    pub cursor: MLCursorMessage,
    pub audio: MLAudioMessage,
}
pub const ML_CLIPBOARD_MAX_ITEMS: usize = 3;
pub const ML_CLIPBOARD_MAX_BYTES: usize = 4_194_304;
pub const ML_SESSION_MAX_MESSAGE: usize = 12_582_912;
pub const ML_CLIPBOARD_MAX_MESSAGE: usize = 4_194_332;
const _: () = assert!(ML_CLIPBOARD_MAX_MESSAGE == MAX_CLIPBOARD);
const _: () = assert!(ML_CLIPBOARD_MAX_ITEMS == MAX_ITEMS);
const _: () = assert!(ML_CLIPBOARD_MAX_BYTES == MAX_CLIPBOARD_BYTES);
const _: () = assert!(
    ML_SESSION_MAX_MESSAGE == transport::MAX_VIDEO && MAX_CLIPBOARD <= transport::MAX_VIDEO
);
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLMetric {
    pub metric: u8,
    pub reserved: [u8; 7],
    pub value: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLTuning {
    pub bitrate_kbps: u32,
    pub max_width: u32,
    pub fps: u8,
    pub in_flight: u8,
    pub keyframe_seconds: u8,
    pub reserved: [u8; 5],
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct MLTelemetryMessage {
    pub kind: u8,
    pub count: u8,
    pub reserved: [u8; 6],
    pub tuning: MLTuning,
    pub metrics: [MLMetric; MAX_METRICS],
}
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct MLTelemetrySnapshot {
    pub role: u8,
    pub local_count: u8,
    pub peer_count: u8,
    pub reserved: [u8; 5],
    pub session_seconds: f64,
    /// Negative when no peer measurements have arrived.
    pub peer_age_seconds: f64,
    pub tuning: MLTuning,
    pub local: [MLMetric; MAX_METRICS],
    pub peer: [MLMetric; MAX_METRICS],
    /// Seconds since the latest session ended; ignored when `last_end` is empty.
    pub last_end_age_seconds: f64,
    /// Why the latest session on this Mac ended; empty when none has.
    pub last_end: [c_char; ML_REASON_CAPACITY],
}
pub const ML_REASON_CAPACITY: usize = 160;
impl Default for MLTelemetrySnapshot {
    fn default() -> Self {
        Self {
            role: 0,
            local_count: 0,
            peer_count: 0,
            reserved: [0; 5],
            session_seconds: 0.0,
            peer_age_seconds: -1.0,
            tuning: MLTuning::default(),
            local: [MLMetric::default(); MAX_METRICS],
            peer: [MLMetric::default(); MAX_METRICS],
            last_end_age_seconds: 0.0,
            last_end: [0; ML_REASON_CAPACITY],
        }
    }
}
#[repr(C)]
pub struct MLPairingCode {
    pub address: [c_char; ML_TEXT_CAPACITY],
    pub name: [c_char; ML_TEXT_CAPACITY],
    pub peer_id: [c_char; ML_PEER_ID_CAPACITY],
    pub public_key: [u8; 32],
    pub secret: [u8; 32],
    /// ML_PAIRING_* : old code, one-time code or device pairing.
    pub kind: u8,
    /// The sharing Mac's other addresses, separated by single spaces.
    pub alternates: [c_char; ML_ALTERNATES_CAPACITY],
}
/// A Mac approved to connect to this one: its ID (hex SHA-256 of its device
/// key), name, when it paired and last connected (Unix seconds), and how it
/// was approved (ML_DEVICE_VIA_*).
#[repr(C)]
pub struct MLDevice {
    pub paired: u64,
    pub last_seen: u64,
    pub id: [c_char; ML_PEER_ID_CAPACITY],
    pub name: [c_char; ML_TEXT_CAPACITY],
    pub via: u8,
}
/// Whether Macs paired before per-device keys may still connect, until when
/// (0: no end set) and when one last did (0: never).
#[repr(C)]
#[derive(Default)]
pub struct MLLegacyState {
    pub accepted: u8,
    pub reserved: [u8; 7],
    pub closes_at: u64,
    pub last_used: u64,
}
#[repr(C)]
pub struct MLPeer {
    pub id: [c_char; ML_PEER_ID_CAPACITY],
    pub name: [c_char; ML_TEXT_CAPACITY],
    /// The address that last worked; the others are tried with it.
    pub address: [c_char; ML_TEXT_CAPACITY],
    pub alternates: [c_char; ML_ALTERNATES_CAPACITY],
}
/// Opaque host input state; calls are serialized internally.
pub struct MLInputState(Mutex<InputReducer>);

// Layout contract, asserted identically in include/mooring_session.h.
const _: () = {
    use std::mem::{offset_of, size_of};
    assert!(size_of::<MLDisplayGeometry>() == 40);
    assert!(size_of::<MLMetric>() == 16);
    assert!(offset_of!(MLMetric, value) == 8);
    assert!(size_of::<MLTuning>() == 16);
    assert!(offset_of!(MLTuning, fps) == 8);
    assert!(size_of::<MLTelemetryMessage>() == 536);
    assert!(offset_of!(MLTelemetryMessage, tuning) == 8);
    assert!(offset_of!(MLTelemetryMessage, metrics) == 24);
    assert!(size_of::<MLTelemetrySnapshot>() == 1232);
    assert!(offset_of!(MLTelemetrySnapshot, last_end_age_seconds) == 1064);
    assert!(offset_of!(MLTelemetrySnapshot, last_end) == 1072);
    assert!(offset_of!(MLTelemetrySnapshot, tuning) == 24);
    assert!(offset_of!(MLTelemetrySnapshot, local) == 40);
    assert!(offset_of!(MLTelemetrySnapshot, peer) == 552);
    assert!(offset_of!(MLSessionMessage, telemetry) == 208);
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
    assert!(offset_of!(MLVideoHeader, codec) == 25);
    assert!(size_of::<MLVideoFrame>() == 96);
    assert!(offset_of!(MLVideoFrame, sps) == 32);
    assert!(offset_of!(MLVideoFrame, pps) == 48);
    assert!(offset_of!(MLVideoFrame, avcc_length) == 72);
    assert!(offset_of!(MLVideoFrame, vps) == 80);
    assert!(size_of::<MLVideoPacket>() == 96);
    assert!(offset_of!(MLVideoPacket, sps_offset) == 32);
    assert!(offset_of!(MLVideoPacket, avcc_length) == 72);
    assert!(offset_of!(MLVideoPacket, vps_offset) == 80);
    assert!(size_of::<MLSessionMessage>() == 872);
    assert!(size_of::<MLClockSample>() == 24 && offset_of!(MLClockSample, host_us) == 16);
    assert!(size_of::<MLSendQueue>() == 24 && offset_of!(MLSendQueue, sent_bytes) == 8);
    assert!(size_of::<MLFlowState>() == 20);
    assert!(size_of::<MLLinkMeter>() == 48 && offset_of!(MLLinkMeter, last_queued) == 40);
    assert!(size_of::<MLClockEstimate>() == 16 && offset_of!(MLClockEstimate, error_us) == 8);
    assert!(size_of::<MLFrameLatency>() == 24 && offset_of!(MLFrameLatency, display_wait_us) == 16);
    assert!(size_of::<MLHostWake>() == 8 && offset_of!(MLHostWake, last_activity_ms) == 4);
    assert!(offset_of!(MLSessionMessage, audio) == 848);
    assert!(size_of::<MLAudioMessage>() == 24);
    assert!(offset_of!(MLAudioMessage, frames) == 4);
    assert!(offset_of!(MLAudioMessage, codec) == 7);
    assert!(offset_of!(MLAudioMessage, payload_offset) == 8);
    assert!(offset_of!(MLSessionMessage, cursor) == 824);
    assert!(size_of::<MLCursorMessage>() == 24);
    assert!(offset_of!(MLCursorMessage, png_offset) == 8);
    assert!(offset_of!(MLSessionMessage, clipboard) == 744);
    assert!(size_of::<MLClipboardItem>() == 24);
    assert!(offset_of!(MLClipboardItem, kind) == 16);
    assert!(size_of::<MLClipboardRange>() == 24);
    assert!(offset_of!(MLClipboardRange, kind) == 16);
    assert!(size_of::<MLClipboardMessage>() == 80);
    assert!(offset_of!(MLClipboardMessage, items) == 8);
    assert!(offset_of!(MLSessionMessage, video) == 8);
    assert!(offset_of!(MLSessionMessage, input) == 104);
    assert!(offset_of!(MLSessionMessage, control) == 152);
    assert!(size_of::<MLPairingCode>() == 1666);
    assert!(offset_of!(MLPairingCode, kind) == 641);
    assert!(offset_of!(MLPairingCode, alternates) == 642);
    assert!(offset_of!(MLPairingCode, name) == 256);
    assert!(offset_of!(MLPairingCode, peer_id) == 512);
    assert!(offset_of!(MLPairingCode, public_key) == 577);
    assert!(offset_of!(MLPairingCode, secret) == 609);
    assert!(size_of::<MLPeer>() == 1601);
    assert!(offset_of!(MLPeer, alternates) == 577);
    assert!(
        size_of::<MLDevice>() == 344
            && offset_of!(MLDevice, id) == 16
            && offset_of!(MLDevice, via) == 337
    );
    assert!(size_of::<MLLegacyState>() == 24 && offset_of!(MLLegacyState, closes_at) == 8);
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
        kind: 0,
        alternates: [0; ML_ALTERNATES_CAPACITY],
    };
}
impl MLPeer {
    const EMPTY: Self = Self {
        id: [0; ML_PEER_ID_CAPACITY],
        name: [0; ML_TEXT_CAPACITY],
        address: [0; ML_TEXT_CAPACITY],
        alternates: [0; ML_ALTERNATES_CAPACITY],
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
fn stats_in(metrics: &[MLMetric], count: u8) -> Result<Stats> {
    let stats = metrics
        .get(..usize::from(count))
        .ok_or(Error::Invalid)?
        .iter()
        .map(
            |entry| match (Metric::from_raw(entry.metric), entry.reserved) {
                (Some(metric), [0, 0, 0, 0, 0, 0, 0]) => Ok((metric, entry.value)),
                _ => Err(Error::Invalid),
            },
        )
        .collect::<Result<Stats>>()?;
    validate_stats(&stats)?;
    Ok(stats)
}
fn stats_out(stats: &Stats, out: &mut [MLMetric; MAX_METRICS]) -> u8 {
    for (slot, (metric, value)) in out.iter_mut().zip(stats) {
        *slot = MLMetric {
            metric: *metric as u8,
            reserved: [0; 7],
            value: *value,
        };
    }
    stats.len() as u8
}
fn tuning_in(raw: &MLTuning) -> Result<Tuning> {
    if raw.reserved != [0; 5] {
        return Err(Error::Invalid);
    }
    let tuning = Tuning {
        bitrate_kbps: raw.bitrate_kbps,
        max_width: raw.max_width,
        fps: raw.fps,
        in_flight: raw.in_flight,
        keyframe_seconds: raw.keyframe_seconds,
    };
    tuning.validate()?;
    Ok(tuning)
}
fn tuning_out(tuning: Tuning) -> MLTuning {
    MLTuning {
        bitrate_kbps: tuning.bitrate_kbps,
        max_width: tuning.max_width,
        fps: tuning.fps,
        in_flight: tuning.in_flight,
        keyframe_seconds: tuning.keyframe_seconds,
        reserved: [0; 5],
    }
}
fn telemetry_in(raw: &MLTelemetryMessage) -> Result<TelemetryMessage> {
    if raw.reserved != [0; 6] {
        return Err(Error::Invalid);
    }
    match raw.kind {
        1 => Ok(TelemetryMessage::Stats(stats_in(&raw.metrics, raw.count)?)),
        2 if raw.count == 0 => Ok(TelemetryMessage::Tuning(tuning_in(&raw.tuning)?)),
        _ => Err(Error::Invalid),
    }
}
fn telemetry_out(message: &TelemetryMessage) -> MLTelemetryMessage {
    let mut out = MLTelemetryMessage::default();
    match message {
        TelemetryMessage::Stats(stats) => {
            out.kind = 1;
            out.count = stats_out(stats, &mut out.metrics);
        }
        TelemetryMessage::Tuning(tuning) => {
            out.kind = 2;
            out.tuning = tuning_out(*tuning);
        }
    }
    out
}
fn header(raw: &MLVideoHeader) -> Result<VideoHeader> {
    if raw.reserved != [0; 6] || raw.keyframe > 1 {
        return Err(Error::Invalid);
    }
    Ok(VideoHeader {
        codec: Codec::from_raw(raw.codec)?,
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
        codec: value.codec.raw(),
        reserved: [0; 6],
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
        vps: part(raw.vps, raw.vps_length)?,
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
    out.kind = code.kind as u8;
    write_text(&mut out.alternates, &code.alternates.join(" "))
}
/// Strictly re-validates a code that crossed the boundary; its peer ID is
/// always recomputed from the public key.
fn code_in(raw: &MLPairingCode) -> Result<PairingCode> {
    PairingCode::of_kind(
        &read_text(&raw.address)?,
        &read_text(&raw.name)?,
        raw.public_key,
        raw.secret,
        CodeKind::from_raw(raw.kind)?,
    )?
    .with_alternates(&split_list(&read_text(&raw.alternates)?))
}
fn peer_out(peer: &Peer, out: &mut MLPeer) -> Result<()> {
    write_text(&mut out.id, &peer.id)?;
    write_text(&mut out.name, &peer.name)?;
    write_text(&mut out.address, &peer.address)?;
    write_text(&mut out.alternates, &peer.alternates.join(" "))
}
fn split_list(text: &str) -> Vec<String> {
    text.split(' ')
        .filter(|entry| !entry.is_empty())
        .map(str::to_owned)
        .collect()
}
/// Addresses separated by spaces: one to ML_ADDRESSES_MAX, each normalized by
/// the host rule, repeats dropped.
fn address_list(text: &str) -> Result<Vec<String>> {
    let mut list: Vec<String> = Vec::new();
    for entry in split_list(text) {
        let address = normalize_address(&entry)?;
        if !list.contains(&address) {
            list.push(address);
        }
    }
    if list.is_empty() || list.len() > ML_ADDRESSES_MAX {
        return Err(Error::Invalid);
    }
    Ok(list)
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
/// As for `text`; null selects the default Mooring support directory.
unsafe fn device_store(directory: *const c_char) -> Result<DeviceStore> {
    if directory.is_null() {
        return DeviceStore::default_location();
    }
    let path = unsafe { text(directory)? };
    if path.is_empty() {
        return Err(Error::Invalid);
    }
    Ok(DeviceStore::new(PathBuf::from(path)))
}
fn unix_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}
// Approved devices on the sharing Mac. A null directory selects MOORING_HOME
// or Application Support.

/// Creates the device list if missing. `accept_old_code` is 1 for a Mac that
/// already shared before per-device keys, so its paired Macs can move over.
/// # Safety
/// `directory` null or NUL terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_devices_init(directory: *const c_char, accept_old_code: u8) -> i32 {
    ffi(|| unsafe { device_store(directory)? }.init(accept_old_code == 1))
}
/// Capacity must be at least ML_DEVICES_MAX.
/// # Safety
/// `directory` null or NUL terminated; `out` writable for `capacity` devices;
/// `count` and `legacy` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_devices_load(
    directory: *const c_char,
    out: *mut MLDevice,
    capacity: usize,
    count: *mut usize,
    legacy: *mut MLLegacyState,
) -> i32 {
    ffi(|| {
        let count = unsafe { output(count)? };
        let legacy = unsafe { output(legacy)? };
        *count = 0;
        *legacy = MLLegacyState::default();
        if out.is_null() || capacity < ML_DEVICES_MAX {
            return Err(Error::Invalid);
        }
        let state = unsafe { device_store(directory)? }.load()?;
        // SAFETY: caller promises `capacity` writable devices.
        let slots = unsafe { std::slice::from_raw_parts_mut(out, capacity) };
        for (slot, device) in slots.iter_mut().zip(&state.devices) {
            *slot = MLDevice {
                paired: device.paired,
                last_seen: device.last_seen,
                id: [0; ML_PEER_ID_CAPACITY],
                name: [0; ML_TEXT_CAPACITY],
                via: match device.via {
                    Via::Code => 1,
                    Via::Migrated => 2,
                },
            };
            write_text(&mut slot.id, &device.id)?;
            write_text(&mut slot.name, &device.name)?;
        }
        *count = state.devices.len();
        *legacy = MLLegacyState {
            accepted: u8::from(state.legacy.accepted),
            reserved: [0; 7],
            closes_at: state.legacy.closes_at.unwrap_or(0),
            last_used: state.legacy.last_used.unwrap_or(0),
        };
        Ok(())
    })
}
/// Removes an approved Mac; the caller also ends its session if connected.
/// # Safety
/// Strings null (directory) or NUL terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_devices_remove(
    directory: *const c_char,
    device_id: *const c_char,
) -> i32 {
    ffi(|| {
        unsafe { device_store(directory)? }.remove(&unsafe { text(device_id)? })?;
        Ok(())
    })
}
/// ML_LEGACY_STOP_NOW, or ML_LEGACY_ANOTHER_WEEK before the old code has stopped.
/// # Safety
/// `directory` null or NUL terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_devices_legacy_action(directory: *const c_char, action: u8) -> i32 {
    ffi(|| {
        let action = match action {
            1 => LegacyAction::StopNow,
            2 => LegacyAction::AnotherWeek,
            _ => return Err(Error::Invalid),
        };
        unsafe { device_store(directory)? }.legacy_action(action, unix_seconds())
    })
}
/// Reset Pairing: no Mac is approved and the old code is not accepted.
/// # Safety
/// `directory` null or NUL terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_devices_reset(directory: *const c_char) -> i32 {
    ffi(|| unsafe { device_store(directory)? }.reset())
}
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
/// As ml_session_listen, approving devices from `directory` (null: MOORING_HOME
/// or Application Support). Viewers may pair with a one-time code, connect with
/// an approved device key, or use the old code while it is still accepted.
/// # Safety
/// As ml_session_listen; `directory` null or NUL terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_listen_devices(
    bind_host: *const c_char,
    port: u16,
    private: *const u8,
    psk: *const u8,
    directory: *const c_char,
    out: *mut u64,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = 0;
        let devices = unsafe { device_store(directory)? };
        let ip = unsafe { text(bind_host)? }
            .parse::<IpAddr>()
            .map_err(|_| Error::Invalid)?;
        let listener = Listener::bind(
            SocketAddr::new(ip, port),
            unsafe { key(private)? },
            unsafe { key(psk)? },
        )?
        .with_devices(devices);
        *out = transport::insert(Handle::Listener(Arc::new(listener)), None)?;
        Ok(())
    })
}
/// A new one-time code's secret for this listener, replacing any earlier one.
/// It approves one Mac within ML_PAIRING_LIFETIME_SECONDS and is never saved.
/// # Safety
/// `out` must be writable for 32 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_listener_pairing_secret(id: u64, out: *mut u8) -> i32 {
    ffi(|| {
        if out.is_null() {
            return Err(Error::Invalid);
        }
        // SAFETY: caller promises 32 writable bytes.
        let target = unsafe { std::slice::from_raw_parts_mut(out, 32) };
        target.fill(0);
        let secret = transport::listener(id)?.new_pairing_secret()?;
        target.copy_from_slice(&*secret);
        Ok(())
    })
}
/// Connects with a pasted code or saved pairing (see transport::connect_paired),
/// proving this Mac's device key. `mode_out` says how (ML_MODE_*): after PAIR
/// or MIGRATE, save the device pairing from ml_pairing_device.
/// # Safety
/// Strings NUL terminated; `code` readable; `device_private` readable for 32
/// bytes; `out` and `mode_out` writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ml_session_connect_paired(
    addresses: *const c_char,
    port: u16,
    code: *const MLPairingCode,
    device_private: *const u8,
    device_name: *const c_char,
    timeout_ms: u32,
    out: *mut u64,
    mode_out: *mut u8,
    used_out: *mut c_char,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        let mode_out = unsafe { output(mode_out)? };
        *out = 0;
        *mode_out = 0;
        if used_out.is_null() {
            return Err(Error::Invalid);
        }
        // SAFETY: caller promises ML_TEXT_CAPACITY writable bytes.
        let used_out = unsafe { &mut *(used_out as *mut [c_char; ML_TEXT_CAPACITY]) };
        used_out.fill(0);
        let end = deadline(timeout_ms)?;
        let hosts = address_list(&unsafe { text(addresses)? })?;
        let code = code_in(unsafe { input_ref(code)? })?;
        let private = unsafe { key(device_private)? };
        let name = unsafe { text(device_name)? };
        let (session, mode, used) =
            transport::connect_paired(&hosts, port, &code, &private, &name, end)?;
        write_text(used_out, &used)?;
        *out = transport::insert(Handle::Session(session), None)?;
        *mode_out = mode as u8;
        Ok(())
    })
}
/// Host: the approved device on the other end, or an empty string for a Mac
/// using the old code.
/// # Safety
/// `out` must be writable for ML_PEER_ID_CAPACITY bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_peer_device(id: u64, out: *mut c_char) -> i32 {
    ffi(|| {
        if out.is_null() {
            return Err(Error::Invalid);
        }
        // SAFETY: caller promises ML_PEER_ID_CAPACITY writable bytes.
        let target = unsafe { &mut *(out as *mut [c_char; ML_PEER_ID_CAPACITY]) };
        target.fill(0);
        let session = transport::session(id)?;
        write_text(target, session.peer_device.as_deref().unwrap_or(""))
    })
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
        -12 => c"Mooring could not read or save paired Macs",
        -13 => c"The other Mac answered, but Mooring isn't sharing there",
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
/// Both sides may send stats; only the viewer may send tuning.
/// # Safety
/// `message` must be readable during the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_send_telemetry(
    id: u64,
    message: *const MLTelemetryMessage,
    timeout_ms: u32,
) -> i32 {
    ffi(|| {
        let value = telemetry_in(unsafe { input_ref(message)? })?;
        transport::session(id)?.send_message(&Outgoing::Telemetry(value), deadline(timeout_ms)?)
    })
}
/// # Safety
/// `items` must be readable for `count` entries, each `bytes` readable for its
/// `length` during the call.
unsafe fn clipboard_items<'a>(
    items: *const MLClipboardItem,
    count: usize,
) -> Result<Vec<(ClipboardKind, &'a [u8])>> {
    if items.is_null() || !(1..=MAX_ITEMS).contains(&count) {
        return Err(Error::Invalid);
    }
    // SAFETY: caller promises `count` readable entries.
    let raw = unsafe { std::slice::from_raw_parts(items, count) };
    raw.iter()
        .map(|item| {
            if item.bytes.is_null() || item.length == 0 || item.length > MAX_CLIPBOARD_BYTES {
                return Err(Error::Invalid);
            }
            // SAFETY: caller promises `length` readable bytes.
            let data = unsafe { std::slice::from_raw_parts(item.bytes, item.length) };
            Ok((ClipboardKind::from_raw(item.kind)?, data))
        })
        .collect()
}
/// Either side may send. Rust validates kinds, order, signatures and the size
/// bound before any byte is written.
/// # Safety
/// As for `clipboard_items`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_send_clipboard(
    id: u64,
    items: *const MLClipboardItem,
    count: usize,
    timeout_ms: u32,
) -> i32 {
    ffi(|| {
        let values = unsafe { clipboard_items(items, count)? };
        transport::session(id)?.send_message(&Outgoing::Clipboard(&values), deadline(timeout_ms)?)
    })
}
/// Hosts only, to a viewer that announced ML_CAPABILITY_CURSOR: the pointer
/// image as a PNG, with its size and hotspot in points.
/// # Safety
/// `png` must be readable for `png_length` bytes.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ml_session_send_cursor(
    id: u64,
    width: u16,
    height: u16,
    hotspot_x: u16,
    hotspot_y: u16,
    png: *const u8,
    png_length: usize,
    timeout_ms: u32,
) -> i32 {
    ffi(|| {
        if png.is_null() || png_length == 0 || png_length > crate::cursor::MAX_CURSOR {
            return Err(Error::Invalid);
        }
        // SAFETY: caller promises `png_length` readable bytes.
        let bytes = unsafe { std::slice::from_raw_parts(png, png_length) };
        let shape = crate::cursor::CursorShape {
            width,
            height,
            hotspot_x,
            hotspot_y,
        };
        transport::session(id)?.send_message(&Outgoing::Cursor(shape, bytes), deadline(timeout_ms)?)
    })
}
/// Hosts only, to a viewer that announced ML_CAPABILITY_AUDIO: one Opus
/// packet of `frames` 48 kHz frames.
/// # Safety
/// `payload` must be readable for `length` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_send_audio(
    id: u64,
    sequence: u32,
    frames: u16,
    channels: u8,
    payload: *const u8,
    length: usize,
    timeout_ms: u32,
) -> i32 {
    ffi(|| {
        if payload.is_null() || length == 0 || length > crate::audio::MAX_AUDIO_PAYLOAD {
            return Err(Error::Invalid);
        }
        // SAFETY: caller promises `length` readable bytes.
        let bytes = unsafe { std::slice::from_raw_parts(payload, length) };
        let header = crate::audio::AudioHeader {
            codec: crate::audio::OPUS,
            channels,
            sequence,
            frames,
        };
        transport::session(id)?.send_message(&Outgoing::Audio(header, bytes), deadline(timeout_ms)?)
    })
}
/// The viewer's playout rule, called after each decoded packet is buffered:
/// whether playback runs and how many of the oldest frames to drop.
/// # Safety
/// `playing_out` and `drop_out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_audio_playout(
    buffered_frames: u32,
    playing: u8,
    playing_out: *mut u8,
    drop_out: *mut u32,
) -> i32 {
    ffi(|| {
        let playing_out = unsafe { output(playing_out)? };
        let drop_out = unsafe { output(drop_out)? };
        let (play, drop) = crate::audio::playout(buffered_frames, playing != 0);
        *playing_out = u8::from(play);
        *drop_out = drop;
        Ok(())
    })
}
/// Packs a release such as "0.3.0-preview.19" for the version message.
/// # Safety
/// `text` must be NUL terminated and `out` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_release_pack(release: *const c_char, out: *mut u64) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = crate::control::Release::parse(&unsafe { text(release)? })?.0;
        Ok(())
    })
}
/// A packed release for display, NUL terminated: "0.3.0 preview 19",
/// "0.3.0", or "a development build".
/// # Safety
/// `out` must be writable for `capacity` bytes, at least ML_RELEASE_CAPACITY.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_release_display(packed: u64, out: *mut c_char, capacity: usize) -> i32 {
    ffi(|| {
        if out.is_null() || capacity < ML_RELEASE_CAPACITY {
            return Err(Error::Invalid);
        }
        // SAFETY: caller promises `capacity` writable bytes.
        let target = unsafe { &mut *(out as *mut [c_char; ML_RELEASE_CAPACITY]) };
        write_text(target, &crate::control::Release(packed).display())
    })
}
/// The session's send buffer and round trip, from the kernel.
/// # Safety
/// `out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_send_queue(id: u64, out: *mut MLSendQueue) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        let queue = transport::session(id)?.send_queue()?;
        *out = MLSendQueue {
            queued_bytes: queue.queued_bytes,
            round_trip_ms: queue.round_trip_ms,
            sent_bytes: queue.sent_bytes,
            retransmitted_bytes: queue.retransmitted_bytes,
        };
        Ok(())
    })
}
/// The most the send buffer may hold before the host starts a frame, from
/// the fastest recent round trip and the bytes sent in the last second.
#[unsafe(no_mangle)]
pub extern "C" fn ml_flow_queue_limit(min_round_trip_ms: u32, sent_bytes_per_second: u64) -> u32 {
    crate::flow::queue_limit(min_round_trip_ms, sent_bytes_per_second)
}
/// 1 when the host may start a video frame with this much queued, else 0.
#[unsafe(no_mangle)]
pub extern "C" fn ml_flow_admits_frame(queued_bytes: u32, limit: u32) -> i32 {
    i32::from(crate::flow::admits_frame(queued_bytes, limit))
}
/// One reading of the send buffer for the link meter; `now_ms` is any
/// monotonic clock in milliseconds.
/// # Safety
/// `meter` writable; `queue` readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_flow_link_sample(
    meter: *mut MLLinkMeter,
    now_ms: u64,
    queue: *const MLSendQueue,
) -> i32 {
    ffi(|| {
        let raw = unsafe { output(meter)? };
        let queue = unsafe { input_ref(queue)? };
        let mut meter = link_meter(raw);
        meter.sample(now_ms, queue.sent_bytes, queue.queued_bytes);
        *raw = link_meter_out(meter);
        Ok(())
    })
}
/// The link's rate in kbit/s over the backlogged time since the last call,
/// or 0 when there was too little; then starts again.
/// # Safety
/// `meter` writable or null (0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_flow_link_take_kbps(meter: *mut MLLinkMeter) -> u32 {
    let Some(raw) = (unsafe { meter.as_mut() }) else {
        return 0;
    };
    let mut meter = link_meter(raw);
    let kbps = meter.take_kbps();
    *raw = link_meter_out(meter);
    kbps
}
fn link_meter(raw: &MLLinkMeter) -> crate::flow::LinkMeter {
    crate::flow::LinkMeter {
        last_ms: raw.last_ms,
        last_sent: raw.last_sent,
        busy_ms: raw.busy_ms,
        busy_bytes: raw.busy_bytes,
        idle_ms: raw.idle_ms,
        last_queued: raw.last_queued,
        started: raw.started,
    }
}
fn link_meter_out(meter: crate::flow::LinkMeter) -> MLLinkMeter {
    MLLinkMeter {
        last_ms: meter.last_ms,
        last_sent: meter.last_sent,
        busy_ms: meter.busy_ms,
        busy_bytes: meter.busy_bytes,
        idle_ms: meter.idle_ms,
        last_queued: meter.last_queued,
        started: meter.started,
    }
}
/// The host's bitrate for the next second, from the milliseconds frames
/// waited for the send buffer in the last one, whether a keyframe went out in
/// it or the one before, the link's rate measured in it (or 0), and what was
/// sent in it, in kbit/s (see flow::next_bitrate). The caller keeps `state`,
/// zeroed at session start.
/// # Safety
/// `state` and `kbps_out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_flow_next_bitrate(
    current_kbps: u32,
    ceiling_kbps: u32,
    waited_ms: u32,
    after_keyframe: u8,
    link_kbps: u32,
    sent_kbps: u32,
    state: *mut MLFlowState,
    kbps_out: *mut u32,
) -> i32 {
    ffi(|| {
        let state = unsafe { output(state)? };
        let kbps_out = unsafe { output(kbps_out)? };
        let previous = crate::flow::FlowState {
            recent: state.recent,
            clear_seconds: state.clear_seconds,
            limit_kbps: state.limit_kbps,
            held_seconds: state.held_seconds,
            peak_kbps: state.peak_kbps,
        };
        let (kbps, next) = crate::flow::next_bitrate(
            current_kbps,
            ceiling_kbps,
            previous,
            waited_ms,
            after_keyframe != 0,
            link_kbps,
            sent_kbps,
        );
        *state = MLFlowState {
            recent: next.recent,
            clear_seconds: next.clear_seconds,
            limit_kbps: next.limit_kbps,
            held_seconds: next.held_seconds,
            peak_kbps: next.peak_kbps,
        };
        *kbps_out = kbps;
        Ok(())
    })
}
/// The best clock offset from up to 32 recent samples; INVALID when none is usable.
/// # Safety
/// `samples` must be readable for `count` entries and `out` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_clock_estimate(
    samples: *const MLClockSample,
    count: usize,
    out: *mut MLClockEstimate,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        if samples.is_null() || count > crate::clock::MAX_SAMPLES {
            return Err(Error::Invalid);
        }
        // SAFETY: caller promises `count` readable samples.
        let raw = unsafe { std::slice::from_raw_parts(samples, count) };
        let values: Vec<crate::clock::ClockSample> = raw
            .iter()
            .map(|sample| crate::clock::ClockSample {
                sent_us: sample.sent_us,
                received_us: sample.received_us,
                host_us: sample.host_us,
            })
            .collect();
        let estimate = crate::clock::estimate(&values)?;
        *out = MLClockEstimate {
            offset_us: estimate.offset_us,
            error_us: estimate.error_us,
        };
        Ok(())
    })
}
/// # Safety
/// As for `clipboard_items`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_clipboard_validate(items: *const MLClipboardItem, count: usize) -> i32 {
    ffi(|| {
        let values = unsafe { clipboard_items(items, count)? };
        clipboard::validate(values.iter().map(|(kind, data)| (*kind, *data)))
    })
}

/// Checks copied text or raw representation bytes for any pairing envelope.
/// Returns 1 for private content, 0 otherwise, INVALID for an invalid buffer.
/// # Safety
/// A non-null `bytes` must be readable for `length` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_clipboard_contains_pairing_secret(
    bytes: *const u8,
    length: usize,
) -> i32 {
    if length > clipboard::MAX_CLIPBOARD_BYTES || (bytes.is_null() && length != 0) {
        return Error::Invalid as i32;
    }
    let data = if length == 0 {
        &[]
    } else {
        // SAFETY: caller promises a readable buffer, bounded above.
        unsafe { std::slice::from_raw_parts(bytes, length) }
    };
    i32::from(crate::pairing::contains_pairing_secret(data))
}

/// Checked capture-to-viewer arithmetic; unusable samples return INVALID.
/// # Safety
/// `out` must be writable for one MLFrameLatency.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_clock_latency(
    offset_us: i64,
    host_us: u64,
    decode_start_us: u64,
    decoded_us: u64,
    presented_us: u64,
    out: *mut MLFrameLatency,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = MLFrameLatency::default();
        let latency = crate::clock::latency(
            offset_us,
            host_us,
            decode_start_us,
            decoded_us,
            presented_us,
        )?;
        *out = MLFrameLatency {
            total_us: latency.total_us,
            to_viewer_us: latency.to_viewer_us,
            display_wait_us: latency.display_wait_us,
        };
        Ok(())
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
                    vps_offset: packet.vps.start,
                    vps_length: packet.vps.len(),
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
            Incoming::Telemetry(message) => {
                out.kind = crate::policy::TELEMETRY;
                out.telemetry = telemetry_out(&message);
            }
            Incoming::Cursor(packet) => {
                out.kind = crate::policy::CURSOR;
                out.cursor = MLCursorMessage {
                    width: packet.shape.width,
                    height: packet.shape.height,
                    hotspot_x: packet.shape.hotspot_x,
                    hotspot_y: packet.shape.hotspot_y,
                    png_offset: packet.png.start,
                    png_length: packet.png.len(),
                };
            }
            Incoming::Audio(packet) => {
                out.kind = crate::policy::AUDIO;
                out.audio = MLAudioMessage {
                    sequence: packet.header.sequence,
                    frames: packet.header.frames,
                    channels: packet.header.channels,
                    codec: packet.header.codec,
                    payload_offset: packet.payload.start,
                    payload_length: packet.payload.len(),
                };
            }
            Incoming::Clipboard(packet) => {
                out.kind = crate::policy::CLIPBOARD;
                out.clipboard.count = packet.items.len() as u8;
                for (slot, (kind, range)) in out.clipboard.items.iter_mut().zip(&packet.items) {
                    *slot = MLClipboardRange {
                        offset: range.start,
                        length: range.len(),
                        kind: *kind as u8,
                        reserved: [0; 7],
                    };
                }
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

/// 1 when this key and modifier combination stays on the viewing Mac even
/// while it captures system shortcuts for the remote Mac, otherwise 0.
#[unsafe(no_mangle)]
pub extern "C" fn ml_input_keeps_local(key_code: u16, modifiers: u32) -> i32 {
    i32::from(keeps_local(key_code, modifiers))
}

pub const ML_CAPABILITY_HEVC_444: u64 = crate::policy::CAPABILITY_HEVC_444;
pub const ML_CAPABILITY_VIRTUAL_DISPLAY: u64 = crate::policy::CAPABILITY_VIRTUAL_DISPLAY;
pub const ML_CAPABILITY_CURSOR: u64 = crate::policy::CAPABILITY_CURSOR;
pub const ML_CAPABILITY_GESTURES: u64 = crate::policy::CAPABILITY_GESTURES;
pub const ML_CAPABILITY_AUDIO: u64 = crate::policy::CAPABILITY_AUDIO;
pub const ML_CAPABILITY_LATENCY: u64 = crate::policy::CAPABILITY_LATENCY;
pub const ML_DEVICES_MAX: usize = crate::devices::MAX_DEVICES;
pub const ML_PAIRING_LIFETIME_SECONDS: u64 = transport::PAIRING_LIFETIME.as_secs();
pub const ML_LEGACY_GRACE_SECONDS: u64 = crate::devices::LEGACY_GRACE_SECONDS;
pub const ML_CAPABILITY_VERSION: u64 = crate::policy::CAPABILITY_VERSION;
pub const ML_CAPABILITY_REMOTE_UPDATE: u64 = crate::policy::CAPABILITY_REMOTE_UPDATE;
pub const ML_CAPABILITY_WAITS: u64 = crate::policy::CAPABILITY_WAITS;
pub const ML_KEYFRAMES_ON_DEMAND: u8 = crate::telemetry::KEYFRAMES_ON_DEMAND;
pub const ML_HOST_WAKE_WAIT_MS: u64 = crate::policy::HOST_WAKE_WAIT.as_millis() as u64;

/// Advances one authenticated host wake. Returns an ML_HOST_WAKE_* action or
/// INVALID; flags must be 0 or 1, and state is unchanged on error.
/// # Safety
/// `state` must be readable and writable for one MLHostWake.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_host_wake_step(
    state: *mut MLHostWake,
    elapsed_ms: u32,
    may_listen: u8,
    may_share: u8,
    display_awake: u8,
) -> i32 {
    let mut action = 0;
    let status = ffi(|| {
        if may_listen > 1 || may_share > 1 || display_awake > 1 {
            return Err(Error::Invalid);
        }
        let state = unsafe { output(state)? };
        let mut wake = crate::policy::HostWake {
            attempts: state.attempts,
            last_activity_ms: state.last_activity_ms,
        };
        action = wake.step(
            elapsed_ms,
            may_listen == 1,
            may_share == 1,
            display_awake == 1,
        )? as i32;
        state.attempts = wake.attempts;
        state.last_activity_ms = wake.last_activity_ms;
        Ok(())
    });
    if status == 0 { action } else { status }
}

/// Clears a prior wake-timeout latch once the session is eligible, independent
/// of the display's power state. Invalid flags fail closed (keep the latch).
#[unsafe(no_mangle)]
pub extern "C" fn ml_host_needs_unlock(previous: u8, may_share: u8) -> u8 {
    if previous > 1 || may_share > 1 {
        return 1;
    }
    u8::from(crate::policy::host_needs_unlock(
        previous == 1,
        may_share == 1,
    ))
}
pub const ML_RELEASE_CAPACITY: usize = 64;
pub const ML_AUDIO_MAX_PAYLOAD: usize = crate::audio::MAX_AUDIO_PAYLOAD;
pub const ML_AUDIO_SAMPLE_RATE: u32 = crate::audio::SAMPLE_RATE;
pub const ML_CODEC_H264: u8 = 1;
pub const ML_CODEC_HEVC: u8 = 2;

/// This process's capabilities, announced in every protocol 5 session started
/// afterwards. Set once at launch, after local self-tests.
#[unsafe(no_mangle)]
pub extern "C" fn ml_capabilities_set(capabilities: u64) {
    transport::set_local_capabilities(capabilities);
}
/// The session's negotiated protocol version (4 or 5), or a negative error.
#[unsafe(no_mangle)]
pub extern "C" fn ml_session_protocol_version(id: u64) -> i32 {
    transport::session(id).map_or_else(|error| error as i32, |session| session.version as i32)
}
/// The peer's announced capabilities; zero until its Hello and in protocol 4.
/// # Safety
/// `out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_session_peer_capabilities(id: u64, out: *mut u64) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = transport::session(id)?
            .peer_capabilities
            .load(std::sync::atomic::Ordering::Acquire);
        Ok(())
    })
}
/// chroma_format_idc of an HEVC SPS (3 is 4:4:4), or a negative error.
/// # Safety
/// `sps` must be readable for `length` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_video_hevc_chroma_format(sps: *const u8, length: usize) -> i32 {
    if sps.is_null() || length == 0 || length > 4096 {
        return Error::Invalid as i32;
    }
    // SAFETY: caller promises `length` readable bytes.
    let bytes = unsafe { std::slice::from_raw_parts(sps, length) };
    hevc_chroma_format(bytes).map_or(Error::Invalid as i32, |value| value as i32)
}

pub const ML_RECONNECT_ATTEMPTS: u32 = 5;
pub const ML_RECONNECT_STABLE_SECONDS: u32 = 20;
const _: () = assert!(RECONNECT_DELAYS.len() == ML_RECONNECT_ATTEMPTS as usize);
const _: () = assert!(RECONNECT_STABLE.as_secs() == ML_RECONNECT_STABLE_SECONDS as u64);

/// Milliseconds to wait before automatic viewer reconnect `attempt`
/// (1-based), or `ML_SESSION_INVALID` once the bounded budget is spent.
#[unsafe(no_mangle)]
pub extern "C" fn ml_reconnect_delay_ms(attempt: u32) -> i32 {
    reconnect_delay(attempt)
        .and_then(|delay| i32::try_from(delay.as_millis()).ok())
        .unwrap_or(Error::Invalid as i32)
}
pub const ML_UPDATE_RECONNECT_ATTEMPTS: u32 = crate::policy::UPDATE_RECONNECT_ATTEMPTS;
/// As `ml_reconnect_delay_ms`, while the sharing Mac installs an update or
/// answers but isn't sharing.
#[unsafe(no_mangle)]
pub extern "C" fn ml_update_reconnect_delay_ms(attempt: u32) -> i32 {
    crate::policy::update_reconnect_delay(attempt)
        .and_then(|delay| i32::try_from(delay.as_millis()).ok())
        .unwrap_or(Error::Invalid as i32)
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
/// The sharing Mac's own code, of `kind` ML_PAIRING_LEGACY or
/// ML_PAIRING_ONE_TIME. The computer name is normalized, never rejected.
/// # Safety
/// Strings are NUL terminated, keys readable for 32 bytes, `out` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_pairing_code_for_host(
    address: *const c_char,
    computer_name: *const c_char,
    public_key: *const u8,
    secret: *const u8,
    kind: u8,
    alternates: *const c_char,
    out: *mut MLPairingCode,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = MLPairingCode::EMPTY;
        let alternates = if alternates.is_null() {
            vec![]
        } else {
            split_list(&unsafe { text(alternates)? })
        };
        let code = PairingCode::for_host(
            &unsafe { text(address)? },
            &unsafe { text(computer_name)? },
            *unsafe { key(public_key)? },
            *unsafe { key(secret)? },
            CodeKind::from_raw(kind)?,
            &alternates,
        )?;
        code_out(&code, out)
    })
}
/// This Mac's network addresses for its pairing codes, best first, separated
/// by single spaces (see addresses.rs); empty if there are none.
/// # Safety
/// `out` writable for `capacity` bytes, at least ML_ALTERNATES_CAPACITY.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_local_addresses(out: *mut c_char, capacity: usize) -> i32 {
    ffi(|| {
        if out.is_null() || capacity < ML_ALTERNATES_CAPACITY {
            return Err(Error::Invalid);
        }
        // SAFETY: caller promises `capacity` writable bytes.
        let target = unsafe { &mut *(out as *mut [c_char; ML_ALTERNATES_CAPACITY]) };
        target.fill(0);
        let addresses = crate::addresses::local_addresses();
        write_text(
            target,
            &crate::pairing::fitted_alternates("", &addresses).join(" "),
        )
    })
}
/// The saved pairing once this Mac is approved: the same sharing Mac,
/// without a secret.
/// # Safety
/// `code` readable; `out` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_pairing_device(
    code: *const MLPairingCode,
    out: *mut MLPairingCode,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = MLPairingCode::EMPTY;
        let device = code_in(unsafe { input_ref(code)? })?.device();
        code_out(&device, out)
    })
}
/// Writes the NUL-terminated `MLP1.` or `MLP2.` text. Capacity must be at
/// least 2049; a device pairing is not a code.
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
        let encoded = code_in(unsafe { input_ref(code)? })?.encode()?;
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
        let bytes = code_in(unsafe { input_ref(code)? })?.credential()?;
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

// Saved peers. A null directory selects MOORING_HOME or Application Support.

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
    addresses: *const c_char,
    out: *mut MLPeer,
) -> i32 {
    ffi(|| {
        if let Some(out) = unsafe { out.as_mut() } {
            *out = MLPeer::EMPTY;
        }
        let code = code_in(unsafe { input_ref(code)? })?;
        let tried = address_list(&unsafe { text(addresses)? })?;
        let peer = unsafe { store(directory)? }.remember(&code, &tried)?;
        match unsafe { out.as_mut() } {
            Some(out) => peer_out(&peer, out),
            None => Ok(()),
        }
    })
}
/// After a saved peer connected through `address`: it goes first among the
/// peer's addresses, and the peer to the top of the list. An unknown peer is
/// left alone.
/// # Safety
/// `directory` null or NUL terminated; `id` and `address` NUL terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_peers_connected(
    directory: *const c_char,
    id: *const c_char,
    address: *const c_char,
) -> i32 {
    ffi(|| {
        let (id, address) = (unsafe { text(id)? }, unsafe { text(address)? });
        unsafe { store(directory)? }
            .connected(&id, &address)
            .map(|_| ())
    })
}
/// Forget a saved peer by ID; forgetting an absent peer succeeds.
/// # Safety
/// `directory` null or NUL terminated; `id` NUL terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_peers_forget(directory: *const c_char, id: *const c_char) -> i32 {
    ffi(|| {
        let id = unsafe { text(id)? };
        unsafe { store(directory)? }.forget(&id).map(|_| ())
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

// Local telemetry socket: owner-only, in the Mooring data directory.

fn telemetry_server() -> &'static Mutex<Option<Arc<Server>>> {
    static SERVER: OnceLock<Mutex<Option<Arc<Server>>>> = OnceLock::new();
    SERVER.get_or_init(|| Mutex::new(None))
}
/// Start serving `telemetry.sock`; a no-op when already serving. BUSY means
/// another Mooring process already serves it.
/// # Safety
/// `directory` null (MOORING_HOME or Application Support) or NUL terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_telemetry_start(directory: *const c_char) -> i32 {
    ffi(|| {
        let mut server = telemetry_server().lock().map_err(|_| Error::Internal)?;
        if server.is_some() {
            return Ok(());
        }
        let directory = if directory.is_null() {
            mooring_platform::support_directory().map_err(|_| Error::Storage)?
        } else {
            PathBuf::from(unsafe { text(directory)? })
        };
        *server = Some(Server::start(&directory)?);
        Ok(())
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ml_telemetry_stop() -> i32 {
    ffi(|| {
        if let Some(server) = telemetry_server()
            .lock()
            .map_err(|_| Error::Internal)?
            .take()
        {
            server.stop();
        }
        Ok(())
    })
}
/// Send one snapshot line to every connected local client.
/// # Safety
/// `snapshot` must be readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_telemetry_publish(snapshot: *const MLTelemetrySnapshot) -> i32 {
    ffi(|| {
        let raw = unsafe { input_ref(snapshot)? };
        let role = match raw.role {
            0 => "idle",
            1 => "host",
            2 => "viewer",
            _ => return Err(Error::Invalid),
        };
        if raw.reserved != [0; 5] {
            return Err(Error::Invalid);
        }
        let value = Snapshot {
            role,
            session_seconds: raw.session_seconds,
            peer_age_seconds: (raw.peer_age_seconds >= 0.0).then_some(raw.peer_age_seconds),
            tuning: tuning_in(&raw.tuning)?,
            local: stats_in(&raw.local, raw.local_count)?,
            peer: stats_in(&raw.peer, raw.peer_count)?,
            last_end: match read_text(&raw.last_end)? {
                reason if reason.is_empty() => None,
                reason => {
                    validate_reason(&reason)?;
                    Some((reason, raw.last_end_age_seconds))
                }
            },
        };
        let server = telemetry_server()
            .lock()
            .map_err(|_| Error::Internal)?
            .clone()
            .ok_or(Error::Closed)?;
        server.publish(&value)
    })
}
/// Returns 1 and fills `out` when a local tuning command is pending, 0 when
/// none is, or a negative status.
/// # Safety
/// `out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_telemetry_take_tuning(out: *mut MLTuning) -> i32 {
    let mut taken = false;
    let status = ffi(|| {
        let out = unsafe { output(out)? };
        *out = MLTuning::default();
        let server = telemetry_server()
            .lock()
            .map_err(|_| Error::Internal)?
            .clone()
            .ok_or(Error::Closed)?;
        if let Some(tuning) = server.take_tuning() {
            *out = tuning_out(tuning);
            taken = true;
        }
        Ok(())
    });
    if status == 0 {
        i32::from(taken)
    } else {
        status
    }
}
/// The host's starting tuning.
/// # Safety
/// `out` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_tuning_defaults(out: *mut MLTuning) -> i32 {
    ffi(|| {
        *unsafe { output(out)? } = tuning_out(Tuning::DEFAULT);
        Ok(())
    })
}
/// Apply the present (nonzero) fields of `update` to `current`.
/// # Safety
/// Inputs must be readable and `out` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_tuning_merge(
    current: *const MLTuning,
    update: *const MLTuning,
    out: *mut MLTuning,
) -> i32 {
    ffi(|| {
        let out = unsafe { output(out)? };
        *out = MLTuning::default();
        let current = tuning_in(unsafe { input_ref(current)? })?;
        let update = tuning_in(unsafe { input_ref(update)? })?;
        *out = tuning_out(current.merged(update));
        Ok(())
    })
}
