//! Live session telemetry and tuning.
//!
//! Each side sends the other a bounded stats record about once a second over
//! the authenticated session (transport type 4); the viewer may also send
//! tuning, which only the sharing host applies. Locally, the app serves the
//! combined view on an owner-only Unix socket in the MacLink data directory:
//! one JSON line per snapshot out, one JSON command per line in. Nothing here
//! opens a network port, and telemetry carries measurements only.
//!
//! Wire format, version 1, big-endian: version:u8 (=1), kind:u8, count:u8,
//! reserved:u8 (=0), then for stats `count` × (metric:u8, value:f64), or for
//! tuning bitrate_kbps:u32, max_width:u32, fps:u8, in_flight:u8,
//! keyframe_seconds:u8, reserved:u8 (=0).

use crate::{Error, Result};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::HashSet;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub(crate) const MAX_TELEMETRY: usize = 512;
pub(crate) const MAX_METRICS: usize = 32;
pub(crate) use maclink_platform::TELEMETRY_SOCKET as SOCKET_NAME;
const MAX_VALUE: f64 = 1e9;
const MAX_CLIENTS: usize = 4;
const MAX_COMMAND: usize = 1024;
/// sun_path on macOS holds 104 bytes including the terminator.
const MAX_SOCKET_PATH: usize = 103;
const POLL: Duration = Duration::from_millis(50);

macro_rules! metrics {
    ($($name:ident = $id:literal => $label:literal,)*) => {
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        #[repr(u8)]
        pub(crate) enum Metric { $($name = $id,)* }
        impl Metric {
            pub(crate) fn from_raw(value: u8) -> Option<Self> {
                match value { $($id => Some(Self::$name),)* _ => None }
            }
            pub(crate) fn name(self) -> &'static str {
                match self { $(Self::$name => $label,)* }
            }
        }
    };
}
metrics! {
    CaptureFps = 1 => "capture_fps",
    EncodedFps = 2 => "encoded_fps",
    SkippedFps = 3 => "skipped_fps",
    DroppedFps = 4 => "dropped_fps",
    FailedFrames = 5 => "failed_frames",
    Keyframes = 6 => "keyframes",
    EncodeMs = 7 => "encode_ms",
    EncodeMsMax = 8 => "encode_ms_max",
    SendMs = 9 => "send_ms",
    SendMsMax = 10 => "send_ms_max",
    SentMbps = 11 => "sent_mbps",
    FrameKib = 12 => "frame_kib",
    InFlight = 13 => "in_flight",
    BitrateMbps = 14 => "bitrate_mbps",
    PixelWidth = 15 => "pixel_width",
    PixelHeight = 16 => "pixel_height",
    FpsCap = 17 => "fps_cap",
    CaptureMs = 18 => "capture_ms",
    ReceivedFps = 32 => "received_fps",
    ReceivedMbps = 33 => "received_mbps",
    DecodeMs = 34 => "decode_ms",
    DecodeMsMax = 35 => "decode_ms_max",
    DecodedFps = 36 => "decoded_fps",
    PresentedFps = 37 => "presented_fps",
    RttMs = 38 => "rtt_ms",
    KeyframeRequests = 39 => "keyframe_requests",
    DecoderOverflows = 40 => "decoder_overflows",
    LatencyMs = 41 => "latency_ms",
    LatencyMsP95 = 42 => "latency_ms_p95",
    ToViewerMs = 43 => "to_viewer_ms",
    DisplayWaitMs = 44 => "display_wait_ms",
    ClockErrorMs = 45 => "clock_error_ms",
}

impl Metric {
    /// Added with the latency capability; older peers reject these IDs.
    pub(crate) fn needs_latency(self) -> bool {
        matches!(
            self,
            Self::CaptureMs
                | Self::LatencyMs
                | Self::LatencyMsP95
                | Self::ToViewerMs
                | Self::DisplayWaitMs
                | Self::ClockErrorMs
        )
    }
}

/// At most 32 distinct metrics with finite values from 0 to 1e9.
pub(crate) type Stats = Vec<(Metric, f64)>;

pub(crate) fn validate_stats(stats: &[(Metric, f64)]) -> Result<()> {
    let mut seen = HashSet::new();
    let valid = stats.len() <= MAX_METRICS
        && stats.iter().all(|(metric, value)| {
            seen.insert(*metric) && value.is_finite() && (0.0..=MAX_VALUE).contains(value)
        });
    if valid { Ok(()) } else { Err(Error::Invalid) }
}

/// Zero means "unchanged" in an update. Only the sharing host applies tuning.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Tuning {
    pub bitrate_kbps: u32,
    pub max_width: u32,
    pub fps: u8,
    pub in_flight: u8,
    pub keyframe_seconds: u8,
}

impl Tuning {
    pub(crate) const DEFAULT: Self = Self {
        bitrate_kbps: 25_000,
        max_width: 3840,
        fps: 60,
        in_flight: 2,
        keyframe_seconds: 2,
    };
    /// Every present field is within the bounds the host can apply.
    pub(crate) fn validate(&self) -> Result<()> {
        let within =
            |value: u32, range: std::ops::RangeInclusive<u32>| value == 0 || range.contains(&value);
        let valid = within(self.bitrate_kbps, 1_000..=80_000)
            && within(self.max_width, 640..=3840)
            && self.max_width.is_multiple_of(2)
            && within(self.fps.into(), 1..=60)
            && within(self.in_flight.into(), 1..=2)
            && within(self.keyframe_seconds.into(), 1..=10);
        if valid { Ok(()) } else { Err(Error::Invalid) }
    }
    /// Present fields of `update` replace this value's fields.
    pub(crate) fn merged(self, update: Self) -> Self {
        let pick = |new: u32, old: u32| if new == 0 { old } else { new };
        Self {
            bitrate_kbps: pick(update.bitrate_kbps, self.bitrate_kbps),
            max_width: pick(update.max_width, self.max_width),
            fps: pick(update.fps.into(), self.fps.into()) as u8,
            in_flight: pick(update.in_flight.into(), self.in_flight.into()) as u8,
            keyframe_seconds: pick(update.keyframe_seconds.into(), self.keyframe_seconds.into())
                as u8,
        }
    }
    fn is_empty(&self) -> bool {
        *self == Self::default()
    }
    fn to_json(self) -> Value {
        let mut object = Map::new();
        if self.bitrate_kbps != 0 {
            object.insert(
                "bitrate_mbps".into(),
                json!(f64::from(self.bitrate_kbps) / 1000.0),
            );
        }
        for (key, value) in [
            ("max_width", self.max_width),
            ("fps", self.fps.into()),
            ("in_flight", self.in_flight.into()),
            ("keyframe_seconds", self.keyframe_seconds.into()),
        ] {
            if value != 0 {
                object.insert(key.into(), json!(value));
            }
        }
        Value::Object(object)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum TelemetryMessage {
    Stats(Stats),
    Tuning(Tuning),
}

impl TelemetryMessage {
    pub(crate) fn validate(&self) -> Result<()> {
        match self {
            Self::Stats(stats) => validate_stats(stats),
            Self::Tuning(tuning) if tuning.is_empty() => Err(Error::Invalid),
            Self::Tuning(tuning) => tuning.validate(),
        }
    }
    pub(crate) fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;
        Ok(match self {
            Self::Stats(stats) => {
                let mut bytes = vec![1, 1, stats.len() as u8, 0];
                for (metric, value) in stats {
                    bytes.push(*metric as u8);
                    bytes.extend_from_slice(&value.to_bits().to_be_bytes());
                }
                bytes
            }
            Self::Tuning(tuning) => {
                let mut bytes = vec![1, 2, 0, 0];
                bytes.extend_from_slice(&tuning.bitrate_kbps.to_be_bytes());
                bytes.extend_from_slice(&tuning.max_width.to_be_bytes());
                bytes.extend_from_slice(&[
                    tuning.fps,
                    tuning.in_flight,
                    tuning.keyframe_seconds,
                    0,
                ]);
                bytes
            }
        })
    }
    /// Any malformed authenticated telemetry is a protocol violation.
    pub(crate) fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < 4 || bytes[0] != 1 || bytes[3] != 0 {
            return Err(Error::Protocol);
        }
        let message = match bytes[1] {
            1 => {
                let count = usize::from(bytes[2]);
                if bytes.len() != 4 + count * 9 {
                    return Err(Error::Protocol);
                }
                let stats = bytes[4..]
                    .as_chunks::<9>()
                    .0
                    .iter()
                    .map(|entry| {
                        let metric = Metric::from_raw(entry[0]).ok_or(Error::Protocol)?;
                        Ok((
                            metric,
                            f64::from_bits(u64::from_be_bytes(entry[1..9].try_into().unwrap())),
                        ))
                    })
                    .collect::<Result<Stats>>()?;
                Self::Stats(stats)
            }
            2 if bytes.len() == 16 && bytes[2] == 0 && bytes[15] == 0 => Self::Tuning(Tuning {
                bitrate_kbps: u32::from_be_bytes(bytes[4..8].try_into().unwrap()),
                max_width: u32::from_be_bytes(bytes[8..12].try_into().unwrap()),
                fps: bytes[12],
                in_flight: bytes[13],
                keyframe_seconds: bytes[14],
            }),
            _ => return Err(Error::Protocol),
        };
        message.validate().map_err(|_| Error::Protocol)?;
        Ok(message)
    }
}

/// One local snapshot: this Mac's measurements, the peer's latest, and the
/// tuning in effect.
pub(crate) struct Snapshot {
    pub role: &'static str,
    pub session_seconds: f64,
    pub peer_age_seconds: Option<f64>,
    pub tuning: Tuning,
    pub local: Stats,
    pub peer: Stats,
    /// Why the latest session on this Mac ended, and how long ago.
    pub last_end: Option<(String, f64)>,
}

/// Session-end reasons are MacLink's own messages: bounded, printable text.
pub(crate) fn validate_reason(reason: &str) -> Result<()> {
    if reason.is_empty() || reason.len() > 159 || reason.chars().any(char::is_control) {
        return Err(Error::Invalid);
    }
    Ok(())
}

impl Snapshot {
    pub(crate) fn to_json_line(&self) -> Result<String> {
        validate_stats(&self.local)?;
        validate_stats(&self.peer)?;
        let finite = |value: f64| value.is_finite() && value >= 0.0;
        if !finite(self.session_seconds) || self.peer_age_seconds.is_some_and(|age| !finite(age)) {
            return Err(Error::Invalid);
        }
        if let Some((reason, age)) = &self.last_end {
            validate_reason(reason)?;
            if !finite(*age) {
                return Err(Error::Invalid);
            }
        }
        let object = |stats: &Stats| {
            Value::Object(
                stats
                    .iter()
                    .map(|(metric, value)| (metric.name().to_owned(), json!(value)))
                    .collect(),
            )
        };
        let mut line = serde_json::to_string(&json!({
            "t": self.session_seconds,
            "role": self.role,
            "tuning": self.tuning.to_json(),
            "local": object(&self.local),
            "peer": object(&self.peer),
            "peer_age_s": self.peer_age_seconds,
            "last_end": self.last_end.as_ref().map(|(reason, age)| json!({"reason": reason, "age_s": age})),
        }))
        .map_err(|_| Error::Internal)?;
        line.push('\n');
        Ok(line)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Command {
    tune: TuneRequest,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TuneRequest {
    bitrate_mbps: Option<f64>,
    max_width: Option<u32>,
    fps: Option<u8>,
    in_flight: Option<u8>,
    keyframe_seconds: Option<u8>,
    #[serde(default)]
    reset: bool,
}

/// `{"tune": {...}}` with any of bitrate_mbps, max_width, fps, in_flight,
/// keyframe_seconds, or reset (restore defaults, then apply the rest).
pub(crate) fn parse_command(line: &str) -> Result<Tuning> {
    let command: Command = serde_json::from_str(line).map_err(|_| Error::Invalid)?;
    let request = command.tune;
    let bitrate_kbps = match request.bitrate_mbps {
        Some(mbps) if mbps.is_finite() && mbps > 0.0 && mbps <= 80.0 => {
            (mbps * 1000.0).round() as u32
        }
        Some(_) => return Err(Error::Invalid),
        None => 0,
    };
    let update = Tuning {
        bitrate_kbps,
        max_width: request.max_width.unwrap_or(0),
        fps: request.fps.unwrap_or(0),
        in_flight: request.in_flight.unwrap_or(0),
        keyframe_seconds: request.keyframe_seconds.unwrap_or(0),
    };
    if [
        request.max_width.map(u64::from),
        request.fps.map(u64::from),
        request.in_flight.map(u64::from),
        request.keyframe_seconds.map(u64::from),
    ]
    .contains(&Some(0))
    {
        return Err(Error::Invalid);
    }
    update.validate()?;
    let tuning = if request.reset {
        Tuning::DEFAULT.merged(update)
    } else {
        update
    };
    if tuning.is_empty() {
        return Err(Error::Invalid);
    }
    Ok(tuning)
}

struct Client {
    stream: UnixStream,
    buffer: Vec<u8>,
}

/// Owner-only local socket. At most four clients; a client that cannot keep
/// up or sends an oversized line is disconnected. Commands merge into one
/// pending tuning that the app takes on its next tick.
pub(crate) struct Server {
    listener: UnixListener,
    path: PathBuf,
    clients: Mutex<Vec<Client>>,
    pending: Mutex<Option<Tuning>>,
    stopped: AtomicBool,
}

impl Server {
    pub(crate) fn start(directory: &Path) -> Result<Arc<Self>> {
        let path = directory.join(SOCKET_NAME);
        if path.as_os_str().len() > MAX_SOCKET_PATH {
            return Err(Error::Invalid);
        }
        std::fs::create_dir_all(directory).map_err(|_| Error::Storage)?;
        // An owner-only folder closes the window between bind and chmod.
        let folder = path.parent().ok_or(Error::Invalid)?;
        match std::fs::DirBuilder::new().mode(0o700).create(folder) {
            Ok(()) => {}
            Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
            Err(_) => return Err(Error::Storage),
        }
        if !std::fs::symlink_metadata(folder)
            .map_err(|_| Error::Storage)?
            .is_dir()
        {
            return Err(Error::Storage);
        }
        std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| Error::Storage)?;
        match std::fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_socket() => {
                if UnixStream::connect(&path).is_ok() {
                    return Err(Error::Busy); // another MacLink is serving it
                }
                std::fs::remove_file(&path).map_err(|_| Error::Storage)?;
            }
            Ok(_) => return Err(Error::Storage), // never replace a non-socket file
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(_) => return Err(Error::Storage),
        }
        let listener = UnixListener::bind(&path).map_err(|_| Error::Io)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| Error::Storage)?;
        listener.set_nonblocking(true).map_err(|_| Error::Io)?;
        let server = Arc::new(Self {
            listener,
            path,
            clients: Mutex::new(Vec::new()),
            pending: Mutex::new(None),
            stopped: AtomicBool::new(false),
        });
        let worker = Arc::clone(&server);
        std::thread::Builder::new()
            .name("maclink-telemetry".into())
            .spawn(move || worker.run())
            .map_err(|_| Error::Internal)?;
        Ok(server)
    }

    fn run(&self) {
        while !self.stopped.load(Ordering::Acquire) {
            while let Ok((stream, _)) = self.listener.accept() {
                let Ok(mut clients) = self.clients.lock() else {
                    return;
                };
                if clients.len() < MAX_CLIENTS && stream.set_nonblocking(true).is_ok() {
                    clients.push(Client {
                        stream,
                        buffer: Vec::new(),
                    });
                }
            }
            self.read_commands();
            std::thread::sleep(POLL);
        }
    }

    fn read_commands(&self) {
        let Ok(mut clients) = self.clients.lock() else {
            return;
        };
        clients.retain_mut(|client| {
            let mut chunk = [0_u8; 512];
            loop {
                match client.stream.read(&mut chunk) {
                    // Everything already sent has been answered; drop the closed client.
                    Ok(0) => return false,
                    Ok(count) => {
                        client.buffer.extend_from_slice(&chunk[..count]);
                        if !self.answer_lines(client) || client.buffer.len() > MAX_COMMAND {
                            return false;
                        }
                    }
                    Err(error) if error.kind() == ErrorKind::WouldBlock => return true,
                    Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                    Err(_) => return false,
                }
            }
        });
    }

    /// Handles each complete line; the 1 KiB limit applies per command.
    fn answer_lines(&self, client: &mut Client) -> bool {
        while let Some(end) = client.buffer.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = client.buffer.drain(..=end).collect();
            if line.len() > MAX_COMMAND + 1 {
                return false;
            }
            let reply = match std::str::from_utf8(&line)
                .map_err(|_| Error::Invalid)
                .and_then(parse_command)
            {
                Ok(tuning) => {
                    let Ok(mut pending) = self.pending.lock() else {
                        return false;
                    };
                    let merged = pending.unwrap_or_default().merged(tuning);
                    *pending = Some(merged);
                    json!({"ack": {"pending": merged.to_json()}})
                }
                Err(_) => {
                    json!({"error": "Expected {\"tune\": {...}} with bitrate_mbps 1–80, max_width 640–3840 (even), fps 1–60, in_flight 1–2, keyframe_seconds 1–10, or reset."})
                }
            };
            if client
                .stream
                .write_all(format!("{reply}\n").as_bytes())
                .is_err()
            {
                return false;
            }
        }
        true
    }

    /// Clients that cannot take the whole line are dropped, never waited for.
    pub(crate) fn publish(&self, snapshot: &Snapshot) -> Result<()> {
        let line = snapshot.to_json_line()?;
        let mut clients = self.clients.lock().map_err(|_| Error::Internal)?;
        clients.retain_mut(|client| client.stream.write_all(line.as_bytes()).is_ok());
        Ok(())
    }

    pub(crate) fn take_tuning(&self) -> Option<Tuning> {
        self.pending.lock().ok()?.take()
    }

    pub(crate) fn stop(&self) {
        if !self.stopped.swap(true, Ordering::AcqRel) {
            let _ = std::fs::remove_file(&self.path);
            if let Ok(mut clients) = self.clients.lock() {
                clients.clear();
            }
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};

    fn directory() -> PathBuf {
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        // Short paths: Unix socket names are limited to 103 bytes.
        let path = PathBuf::from(format!(
            "/tmp/mlt-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&path);
        path
    }
    fn stats() -> Stats {
        vec![
            (Metric::CaptureFps, 42.5),
            (Metric::EncodeMs, 23.0),
            (Metric::PixelWidth, 3456.0),
        ]
    }

    #[test]
    fn stats_and_tuning_round_trip_the_wire() {
        let tuning = Tuning {
            bitrate_kbps: 40_000,
            max_width: 2560,
            fps: 30,
            in_flight: 1,
            keyframe_seconds: 4,
        };
        for message in [
            TelemetryMessage::Stats(stats()),
            TelemetryMessage::Stats(vec![]),
            TelemetryMessage::Tuning(tuning),
        ] {
            let bytes = message.encode().unwrap();
            assert!(bytes.len() <= MAX_TELEMETRY);
            assert_eq!(TelemetryMessage::decode(&bytes).unwrap(), message);
        }
        let full: Stats = (1..=17)
            .chain(32..=40)
            .map(|id| (Metric::from_raw(id).unwrap(), 1.0))
            .collect();
        assert!(TelemetryMessage::Stats(full).encode().unwrap().len() <= MAX_TELEMETRY);
    }

    #[test]
    fn invalid_stats_and_tuning_are_rejected() {
        for stats in [
            vec![(Metric::CaptureFps, f64::NAN)],
            vec![(Metric::CaptureFps, -1.0)],
            vec![(Metric::CaptureFps, 2e9)],
            vec![(Metric::CaptureFps, 1.0), (Metric::CaptureFps, 2.0)],
            vec![(Metric::RttMs, 1.0); 33],
        ] {
            assert!(TelemetryMessage::Stats(stats).encode().is_err());
        }
        for tuning in [
            Tuning::default(),
            Tuning {
                bitrate_kbps: 999,
                ..Tuning::default()
            },
            Tuning {
                bitrate_kbps: 80_001,
                ..Tuning::default()
            },
            Tuning {
                max_width: 639,
                ..Tuning::default()
            },
            Tuning {
                max_width: 2561,
                ..Tuning::default()
            },
            Tuning {
                max_width: 3842,
                ..Tuning::default()
            },
            Tuning {
                fps: 61,
                ..Tuning::default()
            },
            Tuning {
                in_flight: 3,
                ..Tuning::default()
            },
            Tuning {
                keyframe_seconds: 11,
                ..Tuning::default()
            },
        ] {
            assert!(
                TelemetryMessage::Tuning(tuning).encode().is_err(),
                "{tuning:?}"
            );
        }
    }

    #[test]
    fn malformed_wire_telemetry_is_a_protocol_violation() {
        let valid = TelemetryMessage::Stats(stats()).encode().unwrap();
        let tuning = TelemetryMessage::Tuning(Tuning {
            fps: 30,
            ..Tuning::default()
        })
        .encode()
        .unwrap();
        let mut cases = vec![
            vec![],
            valid[..valid.len() - 1].to_vec(),
            [&valid[..], &[0]].concat(),
            tuning[..15].to_vec(),
        ];
        for (index, value) in [(0, 2), (1, 3), (3, 1)] {
            let mut bytes = valid.clone();
            bytes[index] = value;
            cases.push(bytes);
        }
        let mut unknown = valid.clone();
        unknown[4] = 99;
        cases.push(unknown);
        let mut reserved = tuning.clone();
        reserved[15] = 1;
        cases.push(reserved);
        let mut too_fast = tuning.clone();
        too_fast[12] = 61;
        cases.push(too_fast);
        for bytes in cases {
            assert_eq!(TelemetryMessage::decode(&bytes), Err(Error::Protocol));
        }
    }

    #[test]
    fn tuning_merges_present_fields_only() {
        let merged = Tuning::DEFAULT.merged(Tuning {
            bitrate_kbps: 12_000,
            fps: 30,
            ..Tuning::default()
        });
        assert_eq!(
            merged,
            Tuning {
                bitrate_kbps: 12_000,
                fps: 30,
                ..Tuning::DEFAULT
            }
        );
    }

    #[test]
    fn local_commands_are_strict() {
        assert_eq!(
            parse_command(r#"{"tune":{"bitrate_mbps":40.5,"max_width":2560}}"#).unwrap(),
            Tuning {
                bitrate_kbps: 40_500,
                max_width: 2560,
                ..Tuning::default()
            }
        );
        assert_eq!(
            parse_command(r#"{"tune":{"reset":true,"fps":30}}"#).unwrap(),
            Tuning {
                fps: 30,
                ..Tuning::DEFAULT
            }
        );
        for invalid in [
            "",
            "{}",
            r#"{"tune":{}}"#,
            r#"{"tune":{"fps":0}}"#,
            r#"{"tune":{"fps":61}}"#,
            r#"{"tune":{"bitrate_mbps":0}}"#,
            r#"{"tune":{"bitrate_mbps":81}}"#,
            r#"{"tune":{"max_width":2561}}"#,
            r#"{"tune":{"colour":"red"}}"#,
            r#"{"tune":{"fps":30},"extra":1}"#,
            r#"{"tune":{"fps":"30"}}"#,
            r#"{"tune":{"in_flight":3}}"#,
        ] {
            assert!(parse_command(invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn snapshots_are_one_json_line_of_named_measurements() {
        let snapshot = Snapshot {
            role: "viewer",
            session_seconds: 12.5,
            peer_age_seconds: Some(0.4),
            tuning: Tuning::DEFAULT,
            local: vec![(Metric::RttMs, 8.0)],
            peer: stats(),
            last_end: Some(("The other Mac stopped responding".into(), 12.0)),
        };
        let line = snapshot.to_json_line().unwrap();
        assert!(line.ends_with('\n') && line.matches('\n').count() == 1);
        let value: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(value["role"], "viewer");
        assert_eq!(value["local"]["rtt_ms"], 8.0);
        assert_eq!(value["peer"]["capture_fps"], 42.5);
        assert_eq!(value["tuning"]["bitrate_mbps"], 25.0);
        assert_eq!(
            value["last_end"]["reason"],
            "The other Mac stopped responding"
        );
        for reason in ["", "line\nbreak", &"x".repeat(160)] {
            let invalid = Snapshot {
                role: "idle",
                session_seconds: 0.0,
                peer_age_seconds: None,
                tuning: Tuning::DEFAULT,
                local: vec![],
                peer: vec![],
                last_end: Some((reason.to_owned(), 1.0)),
            };
            assert!(invalid.to_json_line().is_err(), "{reason:?}");
        }
        assert!(
            Snapshot {
                session_seconds: f64::NAN,
                ..snapshot
            }
            .to_json_line()
            .is_err()
        );
    }

    #[test]
    fn socket_serves_snapshots_and_takes_commands() {
        let folder = directory();
        let server = Server::start(&folder).unwrap();
        let path = folder.join(SOCKET_NAME);
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            Server::start(&folder).err(),
            Some(Error::Busy),
            "a second instance does not steal the socket"
        );
        let client = UnixStream::connect(&path).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut reader = BufReader::new(client.try_clone().unwrap());
        let mut writer = client;
        writer
            .write_all(b"{\"tune\":{\"bitrate_mbps\":12}}\n{\"tune\":{\"fps\":30}}\nnot json\n")
            .unwrap();
        let mut line = String::new();
        for expected in [r#""bitrate_mbps":12.0"#, r#""fps":30"#, "error"] {
            line.clear();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains(expected), "{line}");
        }
        assert_eq!(
            server.take_tuning(),
            Some(Tuning {
                bitrate_kbps: 12_000,
                fps: 30,
                ..Tuning::default()
            })
        );
        assert_eq!(server.take_tuning(), None, "commands are taken once");
        std::thread::sleep(POLL * 3); // the worker registers clients between polls
        let snapshot = Snapshot {
            role: "host",
            session_seconds: 1.0,
            peer_age_seconds: None,
            tuning: Tuning::DEFAULT,
            local: stats(),
            peer: vec![],
            last_end: None,
        };
        server.publish(&snapshot).unwrap();
        line.clear();
        reader.read_line(&mut line).unwrap();
        assert!(line.contains(r#""capture_fps":42.5"#), "{line}");
        server.stop();
        assert!(!path.exists());
        let _ = std::fs::remove_dir_all(folder);
    }

    #[test]
    fn socket_bounds_clients_and_command_length_and_never_replaces_files() {
        let folder = directory();
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::create_dir_all(folder.join(SOCKET_NAME).parent().unwrap()).unwrap();
        std::fs::write(folder.join(SOCKET_NAME), "not a socket").unwrap();
        assert_eq!(Server::start(&folder).err(), Some(Error::Storage));
        std::fs::remove_file(folder.join(SOCKET_NAME)).unwrap();
        let server = Server::start(&folder).unwrap();
        let path = folder.join(SOCKET_NAME);
        let clients: Vec<UnixStream> = (0..6)
            .map(|_| UnixStream::connect(&path).unwrap())
            .collect();
        std::thread::sleep(POLL * 4);
        assert_eq!(server.clients.lock().unwrap().len(), MAX_CLIENTS);
        let mut noisy = &clients[0];
        noisy.write_all(&vec![b'x'; MAX_COMMAND + 10]).unwrap();
        std::thread::sleep(POLL * 4);
        assert_eq!(
            server.clients.lock().unwrap().len(),
            MAX_CLIENTS - 1,
            "oversized lines disconnect the client"
        );
        assert!(
            Server::start(&PathBuf::from(format!("/tmp/{}", "d".repeat(100)))).is_err(),
            "socket path length is bounded"
        );
        server.stop();
        let _ = std::fs::remove_dir_all(folder);
    }

    #[test]
    fn commands_from_clients_that_close_immediately_still_apply() {
        let folder = directory();
        let server = Server::start(&folder).unwrap();
        let path = folder.join(SOCKET_NAME);
        assert_eq!(
            std::fs::metadata(path.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        {
            let mut client = UnixStream::connect(&path).unwrap();
            client.write_all(b"{\"tune\":{\"fps\":30}}\n").unwrap();
        } // closed before the server polls
        let burst: String = (0..60).map(|_| "{\"tune\":{\"in_flight\":1}}\n").collect();
        assert!(
            burst.len() > MAX_COMMAND,
            "many short commands exceed one command's limit"
        );
        let client = UnixStream::connect(&path).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        (&client).write_all(burst.as_bytes()).unwrap();
        let mut reader = BufReader::new(client);
        for _ in 0..60 {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert!(line.contains("ack"), "{line}");
        }
        assert_eq!(
            server.take_tuning(),
            Some(Tuning {
                fps: 30,
                in_flight: 1,
                ..Tuning::default()
            })
        );
        server.stop();
        let _ = std::fs::remove_dir_all(folder);
    }

    #[test]
    fn stale_socket_files_are_replaced() {
        let folder = directory();
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::create_dir_all(folder.join(SOCKET_NAME).parent().unwrap()).unwrap();
        // A crashed instance leaves its socket file behind with no listener.
        drop(UnixListener::bind(folder.join(SOCKET_NAME)).unwrap());
        assert!(folder.join(SOCKET_NAME).exists());
        let server = Server::start(&folder).unwrap();
        assert!(UnixStream::connect(folder.join(SOCKET_NAME)).is_ok());
        server.stop();
        let _ = std::fs::remove_dir_all(folder);
    }
}
