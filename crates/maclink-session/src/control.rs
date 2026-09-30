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
            (0, 0, 0, zero), // unknown kinds
            (9, 0, 0, zero),
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
