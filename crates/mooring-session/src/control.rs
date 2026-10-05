//! Session control messages. Version 1 wire format, 52 bytes, big-endian:
//! version:u8 (=1), kind:u8, input_enabled:u8 (0/1), reserved:u8 (=0),
//! ping_id:u64, x:f64, y:f64, width:f64, height:f64, pixel_width:u32,
//! pixel_height:u32. Fields a kind does not use must be zero. A clock reply
//! carries the host's time in microseconds as pixel_width (high 32 bits) and
//! pixel_height (low 32 bits).

use crate::video::valid_dimensions;
use crate::{Error, Result};

pub(crate) const CONTROL_BYTES: usize = 52;
const COORDINATE_LIMIT: f64 = 100_000.0;
const SIZE_LIMIT: f64 = 32_768.0;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(crate) struct DisplayGeometry {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub pixel_width: u32,
    pub pixel_height: u32,
}

impl DisplayGeometry {
    /// Logical bounds are the host's CoreGraphics display rectangle; pixel
    /// dimensions are the encoded video size.
    pub(crate) fn is_valid(&self) -> bool {
        [self.x, self.y, self.width, self.height]
            .iter()
            .all(|value| value.is_finite())
            && self.x.abs() <= COORDINATE_LIMIT
            && self.y.abs() <= COORDINATE_LIMIT
            && self.width > 0.0
            && self.height > 0.0
            && self.width <= SIZE_LIMIT
            && self.height <= SIZE_LIMIT
            && valid_dimensions(self.pixel_width, self.pixel_height)
    }
    fn is_zero(&self) -> bool {
        *self == Self::default()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub(crate) enum ControlKind {
    Geometry = 1,
    InputState = 2,
    Ping = 3,
    Pong = 4,
    Keyframe = 5,
    /// Protocol 5: each side's capabilities, sent once at session start.
    Hello = 6,
    /// Protocol 5, viewer to host: share a display of this size.
    DisplayRequest = 7,
    /// Protocol 5, host to a viewer that measures latency: a pong that also
    /// carries the host's clock.
    Clock = 8,
    /// Protocol 5, either way, to a peer that announced it reads it: this
    /// Mac's Mooring version, once per session.
    Version = 9,
    /// Protocol 5, viewer to a host that can update itself: check for an update.
    UpdateRequest = 10,
    /// Protocol 5, host to viewer: how that check is going.
    UpdateStatus = 11,
    /// Protocol 5, viewer to a host that waits for dropped viewers: this
    /// viewer is ending the session on purpose, so the host needn't wait.
    Leaving = 12,
}

/// A Mooring release like 0.3.0-preview.19, packed as major, minor, patch
/// and preview number in 16 bits each, so later releases compare greater. A
/// final release stores 0xffff as its preview, after all its previews; 0
/// overall is a development build.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Release(pub u64);

impl Release {
    const FINAL: u64 = 0xffff;
    /// Strict: `major.minor.patch` or `major.minor.patch-preview.N`, decimal
    /// numbers without leading zeros, each below 65536, N from 1 to 65534.
    pub(crate) fn parse(text: &str) -> Result<Self> {
        let number = |digits: &str| -> Result<u64> {
            let valid = !digits.is_empty()
                && digits.len() <= 5
                && digits.bytes().all(|byte| byte.is_ascii_digit())
                && (digits == "0" || !digits.starts_with('0'));
            if !valid {
                return Err(Error::Invalid);
            }
            let value: u64 = digits.parse().map_err(|_| Error::Invalid)?;
            if value > u64::from(u16::MAX) {
                return Err(Error::Invalid);
            }
            Ok(value)
        };
        let (base, preview) = match text.split_once("-preview.") {
            Some((base, preview)) => {
                let preview = number(preview)?;
                if preview == 0 || preview == Self::FINAL {
                    return Err(Error::Invalid);
                }
                (base, preview)
            }
            None => (text, Self::FINAL),
        };
        let parts: Vec<&str> = base.split('.').collect();
        let [major, minor, patch] = parts.as_slice() else {
            return Err(Error::Invalid);
        };
        Ok(Self(
            number(major)? << 48 | number(minor)? << 32 | number(patch)? << 16 | preview,
        ))
    }
    pub(crate) fn display(self) -> String {
        if self.0 == 0 {
            return "a development build".into();
        }
        let part = |shift: u32| (self.0 >> shift) & 0xffff;
        let base = format!("{}.{}.{}", part(48), part(32), part(16));
        match part(0) {
            Self::FINAL => base,
            preview => format!("{base} preview {preview}"),
        }
    }
}

/// Where a sharing Mac's update check stands, as reported to the viewer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub(crate) enum UpdateState {
    Checking = 1,
    UpToDate = 2,
    /// Downloaded and verified; installs once no session is connected.
    Ready = 3,
    Failed = 4,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum ControlMessage {
    Geometry {
        geometry: DisplayGeometry,
        input_enabled: bool,
    },
    InputState {
        input_enabled: bool,
    },
    Ping(u64),
    Pong(u64),
    Keyframe,
    /// Capability bits in the ping_id field; unknown bits are ignored.
    Hello(u64),
    /// The viewer's video area: `width`×`height` points at `scale` 1 or 2,
    /// carried in the geometry size and pixel fields. All zero asks the host
    /// to share its own display again.
    DisplayRequest(DisplayRequest),
    /// Answers a ping with the host's clock (CoreMedia host time, in
    /// microseconds) when it received it, so the viewer can place the host's
    /// capture timestamps on its own clock.
    Clock {
        ping_id: u64,
        host_us: u64,
    },
    /// The sender's build number and release, in the pixel_width and
    /// ping_id fields.
    Version {
        build: u32,
        release: Release,
    },
    UpdateRequest,
    /// The state in pixel_height; for Ready, the waiting update's release
    /// and build as in Version, otherwise zero.
    UpdateStatus {
        state: UpdateState,
        build: u32,
        release: Release,
    },
    Leaving,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct DisplayRequest {
    pub width: u32,
    pub height: u32,
    pub scale: u32,
}
impl DisplayRequest {
    fn from_geometry(geometry: &DisplayGeometry) -> Option<Self> {
        if geometry.is_zero() {
            return Some(Self::default());
        }
        let points = |value: f64| {
            (value.fract() == 0.0 && (240.0..=7680.0).contains(&value)).then_some(value as u32)
        };
        let (width, height) = (points(geometry.width)?, points(geometry.height)?);
        let scale = geometry.pixel_width / width;
        (geometry.x == 0.0
            && geometry.y == 0.0
            && width >= 320
            && (scale == 1 || scale == 2)
            && geometry.pixel_width == width * scale
            && geometry.pixel_height == height * scale
            && valid_dimensions(geometry.pixel_width, geometry.pixel_height))
        .then_some(Self {
            width,
            height,
            scale,
        })
    }
    fn geometry(&self) -> DisplayGeometry {
        if *self == Self::default() {
            return DisplayGeometry::default();
        }
        DisplayGeometry {
            x: 0.0,
            y: 0.0,
            width: self.width.into(),
            height: self.height.into(),
            pixel_width: self.width * self.scale,
            pixel_height: self.height * self.scale,
        }
    }
}

impl ControlMessage {
    /// Strict constructor shared by the wire decoder and the C ABI.
    pub(crate) fn from_parts(
        kind: u8,
        input_enabled: u8,
        ping_id: u64,
        geometry: DisplayGeometry,
    ) -> Result<Self> {
        let enabled = match input_enabled {
            0 => false,
            1 => true,
            _ => return Err(Error::Invalid),
        };
        let message = match kind {
            1 if geometry.is_valid() && ping_id == 0 => Self::Geometry {
                geometry,
                input_enabled: enabled,
            },
            2 if geometry.is_zero() && ping_id == 0 => Self::InputState {
                input_enabled: enabled,
            },
            3 if geometry.is_zero() && !enabled => Self::Ping(ping_id),
            4 if geometry.is_zero() && !enabled => Self::Pong(ping_id),
            5 if geometry.is_zero() && !enabled && ping_id == 0 => Self::Keyframe,
            6 if geometry.is_zero() && !enabled => Self::Hello(ping_id),
            7 if !enabled && ping_id == 0 => Self::DisplayRequest(
                DisplayRequest::from_geometry(&geometry).ok_or(Error::Invalid)?,
            ),
            8 if !enabled
                && [geometry.x, geometry.y, geometry.width, geometry.height] == [0.0; 4] =>
            {
                Self::Clock {
                    ping_id,
                    host_us: u64::from(geometry.pixel_width) << 32
                        | u64::from(geometry.pixel_height),
                }
            }
            9 if !enabled
                && [geometry.x, geometry.y, geometry.width, geometry.height] == [0.0; 4]
                && geometry.pixel_width > 0
                && geometry.pixel_height == 0 =>
            {
                Self::Version {
                    build: geometry.pixel_width,
                    release: Release(ping_id),
                }
            }
            10 if !enabled && geometry.is_zero() && ping_id == 0 => Self::UpdateRequest,
            12 if !enabled && geometry.is_zero() && ping_id == 0 => Self::Leaving,
            11 if !enabled
                && [geometry.x, geometry.y, geometry.width, geometry.height] == [0.0; 4] =>
            {
                let state = match geometry.pixel_height {
                    1 => UpdateState::Checking,
                    2 => UpdateState::UpToDate,
                    3 => UpdateState::Ready,
                    4 => UpdateState::Failed,
                    _ => return Err(Error::Invalid),
                };
                // Only a waiting update names its version, and it must.
                let named = geometry.pixel_width != 0 || ping_id != 0;
                let complete = geometry.pixel_width != 0;
                if named != (state == UpdateState::Ready) || (named && !complete) {
                    return Err(Error::Invalid);
                }
                Self::UpdateStatus {
                    state,
                    build: geometry.pixel_width,
                    release: Release(ping_id),
                }
            }
            _ => return Err(Error::Invalid),
        };
        Ok(message)
    }

    pub(crate) fn kind(&self) -> ControlKind {
        match self {
            Self::Geometry { .. } => ControlKind::Geometry,
            Self::InputState { .. } => ControlKind::InputState,
            Self::Ping(_) => ControlKind::Ping,
            Self::Pong(_) => ControlKind::Pong,
            Self::Keyframe => ControlKind::Keyframe,
            Self::Hello(_) => ControlKind::Hello,
            Self::DisplayRequest(_) => ControlKind::DisplayRequest,
            Self::Clock { .. } => ControlKind::Clock,
            Self::Version { .. } => ControlKind::Version,
            Self::UpdateRequest => ControlKind::UpdateRequest,
            Self::UpdateStatus { .. } => ControlKind::UpdateStatus,
            Self::Leaving => ControlKind::Leaving,
        }
    }

    /// Returns (input_enabled, ping_id, geometry) with unused fields zeroed.
    pub(crate) fn parts(&self) -> (u8, u64, DisplayGeometry) {
        match *self {
            Self::Geometry {
                geometry,
                input_enabled,
            } => (input_enabled.into(), 0, geometry),
            Self::InputState { input_enabled } => {
                (input_enabled.into(), 0, DisplayGeometry::default())
            }
            Self::Ping(id) | Self::Pong(id) | Self::Hello(id) => {
                (0, id, DisplayGeometry::default())
            }
            Self::Keyframe => (0, 0, DisplayGeometry::default()),
            Self::DisplayRequest(request) => (0, 0, request.geometry()),
            Self::Clock { ping_id, host_us } => (
                0,
                ping_id,
                DisplayGeometry {
                    pixel_width: (host_us >> 32) as u32,
                    pixel_height: host_us as u32,
                    ..DisplayGeometry::default()
                },
            ),
            Self::Version { build, release } => (
                0,
                release.0,
                DisplayGeometry {
                    pixel_width: build,
                    ..DisplayGeometry::default()
                },
            ),
            Self::UpdateRequest | Self::Leaving => (0, 0, DisplayGeometry::default()),
            Self::UpdateStatus {
                state,
                build,
                release,
            } => (
                0,
                release.0,
                DisplayGeometry {
                    pixel_width: build,
                    pixel_height: state as u32,
                    ..DisplayGeometry::default()
                },
            ),
        }
    }

    pub(crate) fn encode(&self) -> [u8; CONTROL_BYTES] {
        let (enabled, ping_id, geometry) = self.parts();
        let mut bytes = [0_u8; CONTROL_BYTES];
        bytes[0] = 1;
        bytes[1] = self.kind() as u8;
        bytes[2] = enabled;
        bytes[4..12].copy_from_slice(&ping_id.to_be_bytes());
        for (index, value) in [geometry.x, geometry.y, geometry.width, geometry.height]
            .into_iter()
            .enumerate()
        {
            let start = 12 + index * 8;
            bytes[start..start + 8].copy_from_slice(&value.to_bits().to_be_bytes());
        }
        bytes[44..48].copy_from_slice(&geometry.pixel_width.to_be_bytes());
        bytes[48..52].copy_from_slice(&geometry.pixel_height.to_be_bytes());
        bytes
    }

    /// Any malformed authenticated control message is a protocol violation.
    pub(crate) fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() != CONTROL_BYTES || bytes[0] != 1 || bytes[3] != 0 {
            return Err(Error::Protocol);
        }
        let float = |start: usize| {
            f64::from_bits(u64::from_be_bytes(
                bytes[start..start + 8].try_into().unwrap(),
            ))
        };
        let word = |start: usize| u32::from_be_bytes(bytes[start..start + 4].try_into().unwrap());
        let geometry = DisplayGeometry {
            x: float(12),
            y: float(20),
            width: float(28),
            height: float(36),
            pixel_width: word(44),
            pixel_height: word(48),
        };
        let ping_id = u64::from_be_bytes(bytes[4..12].try_into().unwrap());
        Self::from_parts(bytes[1], bytes[2], ping_id, geometry).map_err(|_| Error::Protocol)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn geometry() -> DisplayGeometry {
        DisplayGeometry {
            x: -1920.0,
            y: 0.0,
            width: 1920.0,
            height: 1080.0,
            pixel_width: 1920,
            pixel_height: 1080,
        }
    }

    #[test]
    fn every_valid_control_message_round_trips() {
        let messages = [
            ControlMessage::Geometry {
                geometry: geometry(),
                input_enabled: true,
            },
            ControlMessage::InputState {
                input_enabled: false,
            },
            ControlMessage::Ping(0),
            ControlMessage::Pong(u64::MAX),
            ControlMessage::Keyframe,
            ControlMessage::Clock {
                ping_id: 7,
                host_us: 0x0001_0203_0405_0607,
            },
            ControlMessage::Clock {
                ping_id: u64::MAX,
                host_us: u64::MAX,
            },
            ControlMessage::Version {
                build: 24,
                release: Release::parse("0.3.0-preview.19").unwrap(),
            },
            ControlMessage::Version {
                build: u32::MAX,
                release: Release(0),
            },
            ControlMessage::UpdateRequest,
            ControlMessage::UpdateStatus {
                state: UpdateState::Checking,
                build: 0,
                release: Release(0),
            },
            ControlMessage::UpdateStatus {
                state: UpdateState::Ready,
                build: 25,
                release: Release::parse("0.3.0-preview.20").unwrap(),
            },
            ControlMessage::UpdateStatus {
                state: UpdateState::Failed,
                build: 0,
                release: Release(0),
            },
            ControlMessage::Leaving,
        ];
        for message in messages {
            assert_eq!(ControlMessage::decode(&message.encode()).unwrap(), message);
            let (enabled, id, display) = message.parts();
            assert_eq!(
                ControlMessage::from_parts(message.kind() as u8, enabled, id, display).unwrap(),
                message
            );
        }
    }

    #[test]
    fn clock_replies_carry_only_an_id_and_the_host_time() {
        let clock = ControlMessage::Clock {
            ping_id: 3,
            host_us: 1_150_523_260_054,
        };
        let (_, id, display) = clock.parts();
        assert_eq!(
            (id, display.pixel_width, display.pixel_height),
            (3, 267, 3_766_992_022)
        );
        for change in [
            |g: &mut DisplayGeometry| g.x = 1.0,
            |g: &mut DisplayGeometry| g.y = f64::NAN,
            |g: &mut DisplayGeometry| g.width = 1.0,
            |g: &mut DisplayGeometry| g.height = -1.0,
        ] {
            let mut bad = display;
            change(&mut bad);
            assert_eq!(
                ControlMessage::from_parts(8, 0, 3, bad),
                Err(Error::Invalid)
            );
        }
        assert_eq!(
            ControlMessage::from_parts(8, 1, 3, display),
            Err(Error::Invalid)
        );
    }

    #[test]
    fn releases_parse_strictly_and_display_plainly() {
        let preview = Release::parse("0.3.0-preview.19").unwrap();
        assert_eq!(preview.0, 3 << 32 | 19);
        assert_eq!(preview.display(), "0.3.0 preview 19");
        assert_eq!(Release::parse("1.2.3").unwrap().display(), "1.2.3");
        assert_eq!(
            Release::parse("65535.0.10-preview.65534").unwrap().0,
            65535 << 48 | 10 << 16 | 65534
        );
        assert_eq!(Release(0).display(), "a development build");
        // Later previews sort after earlier ones, and a final release after all its previews.
        let final_release = Release::parse("0.3.0").unwrap();
        assert!(Release::parse("0.3.0-preview.20").unwrap().0 > preview.0);
        assert!(final_release.0 > Release::parse("0.3.0-preview.65534").unwrap().0);
        assert!(Release::parse("0.3.1-preview.1").unwrap().0 > final_release.0);
        for bad in [
            "",
            "0.3",
            "0.3.0.1",
            "0.3.0-preview.",
            "0.3.0-preview.0",
            "0.3.0-preview.07",
            "0.3.0-preview.65535",
            "03.0.0",
            "0.3.0-beta.1",
            "0.3.0-preview.1-preview.2",
            "65536.0.0",
            "0.3.x",
            " 0.3.0",
            "0.3.0\n",
            "-1.0.0",
            "0..0",
        ] {
            assert_eq!(Release::parse(bad), Err(Error::Invalid), "{bad:?}");
        }
    }

    #[test]
    fn version_and_update_messages_carry_only_their_fields() {
        let version = |build: u32, height: u32, x: f64| DisplayGeometry {
            x,
            pixel_width: build,
            pixel_height: height,
            ..DisplayGeometry::default()
        };
        assert!(ControlMessage::from_parts(9, 0, 5, version(24, 0, 0.0)).is_ok());
        for (enabled, geometry) in [
            (0, version(0, 0, 0.0)),
            (0, version(24, 1, 0.0)),
            (0, version(24, 0, 1.0)),
            (1, version(24, 0, 0.0)),
        ] {
            assert_eq!(
                ControlMessage::from_parts(9, enabled, 5, geometry),
                Err(Error::Invalid)
            );
        }
        assert_eq!(
            ControlMessage::from_parts(10, 0, 1, DisplayGeometry::default()),
            Err(Error::Invalid)
        );
        let status = |state: u32, build: u32, release: u64| {
            ControlMessage::from_parts(11, 0, release, version(build, state, 0.0))
        };
        assert!(status(3, 25, 7).is_ok() && status(3, 25, 0).is_ok() && status(2, 0, 0).is_ok());
        for (state, build, release) in [
            (0, 0, 0),
            (5, 0, 0),
            (3, 0, 0),
            (3, 0, 7),
            (1, 25, 0),
            (2, 0, 7),
            (4, 1, 1),
        ] {
            assert_eq!(
                status(state, build, release),
                Err(Error::Invalid),
                "{state} {build} {release}"
            );
        }
    }

    #[test]
    fn display_geometry_bounds_are_exact() {
        let with = |change: fn(&mut DisplayGeometry)| {
            let mut value = geometry();
            change(&mut value);
            value
        };
        let invalid = [
            with(|g| g.x = f64::NAN),
            with(|g| g.x = f64::INFINITY),
            with(|g| g.x = -100_001.0),
            with(|g| g.x = 100_001.0),
            with(|g| g.y = f64::NAN),
            with(|g| g.y = f64::NEG_INFINITY),
            with(|g| g.y = -100_001.0),
            with(|g| g.y = 100_001.0),
            with(|g| g.width = 0.0),
            with(|g| g.width = -1.0),
            with(|g| g.width = f64::NAN),
            with(|g| g.width = f64::INFINITY),
            with(|g| g.width = 32_769.0),
            with(|g| g.height = 0.0),
            with(|g| g.height = -1.0),
            with(|g| g.height = f64::NAN),
            with(|g| g.height = f64::INFINITY),
            with(|g| g.height = 32_769.0),
            with(|g| g.pixel_width = 0),
            with(|g| g.pixel_width = 15),
            with(|g| g.pixel_width = 1921),
            with(|g| g.pixel_width = 4098),
            with(|g| g.pixel_width = u32::MAX),
            with(|g| g.pixel_height = 0),
            with(|g| g.pixel_height = 15),
            with(|g| g.pixel_height = 1081),
            with(|g| g.pixel_height = 4098),
            with(|g| g.pixel_height = u32::MAX),
            with(|g| {
                g.pixel_width = 4096;
                g.pixel_height = 4096
            }),
        ];
        for value in invalid {
            assert!(!value.is_valid(), "{value:?}");
            assert!(ControlMessage::from_parts(1, 1, 0, value).is_err());
        }
        let valid = [
            DisplayGeometry {
                x: -100_000.0,
                y: 100_000.0,
                width: 32_768.0,
                height: 32_768.0,
                ..geometry()
            },
            with(|g| {
                g.pixel_width = 16;
                g.pixel_height = 16
            }),
            with(|g| {
                g.pixel_width = 3840;
                g.pixel_height = 2160
            }),
            with(|g| {
                g.pixel_width = 4096;
                g.pixel_height = 1080
            }),
        ];
        for value in valid {
            assert!(value.is_valid(), "{value:?}");
        }
    }

    #[test]
    fn each_kind_rejects_fields_it_does_not_use() {
        let display = geometry();
        let zero = DisplayGeometry::default();
        for (kind, enabled, id, value) in [
            (1, 1, 1, display), // geometry cannot carry a ping ID
            (1, 2, 0, display), // input permission is a strict boolean
            (2, 0, 1, zero),    // input state cannot carry a ping ID
            (2, 0, 0, display), // only geometry carries a display
            (3, 1, 0, zero),    // ping cannot carry input permission
            (3, 0, 0, display), // ping cannot carry a display
            (4, 1, 7, zero),    // pong cannot carry input permission
            (5, 0, 1, zero),    // keyframe carries nothing
            (5, 1, 0, zero),
            (5, 0, 0, display),
            (6, 1, 3, zero), // hello carries only capabilities
            (6, 0, 3, display),
            (12, 1, 0, zero), // leaving carries nothing
            (12, 0, 1, zero),
            (12, 0, 0, display),
            (0, 0, 0, zero), // unknown kinds
            (13, 0, 0, zero),
        ] {
            assert!(ControlMessage::from_parts(kind, enabled, id, value).is_err());
        }
        let hello = ControlMessage::Hello(u64::MAX);
        assert_eq!(
            ControlMessage::decode(&hello.encode()),
            Ok(hello),
            "unknown capability bits survive"
        );
    }

    #[test]
    fn display_requests_carry_points_and_an_exact_scale() {
        let sized =
            |width: f64, height: f64, pixel_width: u32, pixel_height: u32| DisplayGeometry {
                width,
                height,
                pixel_width,
                pixel_height,
                ..DisplayGeometry::default()
            };
        let retina = ControlMessage::from_parts(7, 0, 0, sized(1512.0, 916.0, 3024, 1832)).unwrap();
        assert_eq!(
            retina,
            ControlMessage::DisplayRequest(DisplayRequest {
                width: 1512,
                height: 916,
                scale: 2
            })
        );
        assert_eq!(ControlMessage::decode(&retina.encode()), Ok(retina));
        let release = ControlMessage::from_parts(7, 0, 0, DisplayGeometry::default()).unwrap();
        assert_eq!(
            release,
            ControlMessage::DisplayRequest(DisplayRequest::default())
        );
        assert_eq!(ControlMessage::decode(&release.encode()), Ok(release));
        for invalid in [
            sized(1512.0, 916.0, 4536, 2748),  // scale 3
            sized(1512.0, 916.0, 3024, 1830),  // pixels disagree with the scale
            sized(1512.5, 916.0, 3025, 1832),  // fractional points
            sized(300.0, 240.0, 600, 480),     // narrower than 320 points
            sized(2560.0, 1600.0, 5120, 3200), // more pixels than the video allows
            sized(1512.0, 916.0, 0, 0),
            DisplayGeometry {
                x: 1.0,
                ..sized(1512.0, 916.0, 3024, 1832)
            },
        ] {
            assert!(
                ControlMessage::from_parts(7, 0, 0, invalid).is_err(),
                "{invalid:?}"
            );
        }
        assert!(ControlMessage::from_parts(7, 1, 0, sized(1512.0, 916.0, 3024, 1832)).is_err());
        assert!(ControlMessage::from_parts(7, 0, 5, sized(1512.0, 916.0, 3024, 1832)).is_err());
    }

    #[test]
    fn malformed_wire_messages_are_protocol_violations() {
        let valid = ControlMessage::Geometry {
            geometry: geometry(),
            input_enabled: true,
        }
        .encode();
        let mut cases = vec![valid[..51].to_vec(), [&valid[..], &[0]].concat()];
        for (index, value) in [(0, 2), (1, 9), (2, 2), (3, 1)] {
            let mut bytes = valid;
            bytes[index] = value;
            cases.push(bytes.to_vec());
        }
        let mut nan = valid;
        nan[12..20].copy_from_slice(&f64::NAN.to_bits().to_be_bytes());
        cases.push(nan.to_vec());
        for bytes in cases {
            assert_eq!(ControlMessage::decode(&bytes), Err(Error::Protocol));
        }
    }
}
