//! RFB constants and client-to-server messages (RFC 6143 and the community
//! RFB specification).

/// The largest desktop Mooring accepts, per side.
pub const MAX_DIMENSION: u16 = 16_384;
pub const MAX_NAME_BYTES: u32 = 4_096;
pub const MAX_REASON_BYTES: u32 = 4_096;
/// Clipboard text from the server beyond this is skipped, never buffered.
pub const MAX_CUT_TEXT_BYTES: u32 = 1 << 20;
/// Rectangles in one update, from the 16-bit count in the message.
pub const MAX_RECTS_PER_UPDATE: u16 = u16::MAX;

pub mod security {
    pub const INVALID: u8 = 0;
    pub const NONE: u8 = 1;
    pub const VNC_PASSWORD: u8 = 2;
    pub const RA2: u8 = 5;
    pub const RA2NE: u8 = 6;
    pub const APPLE_DH: u8 = 30;
    pub const RA2_256: u8 = 129;
}

pub mod encoding {
    pub const RAW: i32 = 0;
    pub const COPY_RECT: i32 = 1;
    pub const ZRLE: i32 = 16;
    pub const DESKTOP_SIZE: i32 = -223;
    pub const LAST_RECT: i32 = -224;
    pub const EXTENDED_DESKTOP_SIZE: i32 = -308;
}

/// What Mooring asks for, most preferred first.
pub const ENCODINGS: [i32; 6] = [
    encoding::ZRLE,
    encoding::COPY_RECT,
    encoding::RAW,
    encoding::DESKTOP_SIZE,
    encoding::EXTENDED_DESKTOP_SIZE,
    encoding::LAST_RECT,
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PixelFormat {
    pub bits_per_pixel: u8,
    pub depth: u8,
    pub big_endian: bool,
    pub true_colour: bool,
    pub red_max: u16,
    pub green_max: u16,
    pub blue_max: u16,
    pub red_shift: u8,
    pub green_shift: u8,
    pub blue_shift: u8,
}

impl PixelFormat {
    /// 32-bit little-endian 0x00RRGGBB: bytes arrive as B, G, R, X, which is
    /// what Core Graphics draws as 32-bit little-endian with alpha skipped.
    pub const BGRX: PixelFormat = PixelFormat {
        bits_per_pixel: 32,
        depth: 24,
        big_endian: false,
        true_colour: true,
        red_max: 255,
        green_max: 255,
        blue_max: 255,
        red_shift: 16,
        green_shift: 8,
        blue_shift: 0,
    };

    pub fn encode(&self) -> [u8; 16] {
        let mut out = [0_u8; 16];
        out[0] = self.bits_per_pixel;
        out[1] = self.depth;
        out[2] = u8::from(self.big_endian);
        out[3] = u8::from(self.true_colour);
        out[4..6].copy_from_slice(&self.red_max.to_be_bytes());
        out[6..8].copy_from_slice(&self.green_max.to_be_bytes());
        out[8..10].copy_from_slice(&self.blue_max.to_be_bytes());
        out[10] = self.red_shift;
        out[11] = self.green_shift;
        out[12] = self.blue_shift;
        out
    }

    pub fn decode(bytes: &[u8; 16]) -> Self {
        Self {
            bits_per_pixel: bytes[0],
            depth: bytes[1],
            big_endian: bytes[2] != 0,
            true_colour: bytes[3] != 0,
            red_max: u16::from_be_bytes([bytes[4], bytes[5]]),
            green_max: u16::from_be_bytes([bytes[6], bytes[7]]),
            blue_max: u16::from_be_bytes([bytes[8], bytes[9]]),
            red_shift: bytes[10],
            green_shift: bytes[11],
            blue_shift: bytes[12],
        }
    }
}

pub fn set_pixel_format(format: &PixelFormat) -> [u8; 20] {
    let mut out = [0_u8; 20];
    out[4..].copy_from_slice(&format.encode());
    out
}

pub fn set_encodings(encodings: &[i32]) -> Vec<u8> {
    let count = u16::try_from(encodings.len()).unwrap_or(u16::MAX);
    let mut out = Vec::with_capacity(4 + encodings.len() * 4);
    out.extend_from_slice(&[2, 0]);
    out.extend_from_slice(&count.to_be_bytes());
    for value in encodings.iter().take(usize::from(count)) {
        out.extend_from_slice(&value.to_be_bytes());
    }
    out
}

pub fn update_request(incremental: bool, x: u16, y: u16, width: u16, height: u16) -> [u8; 10] {
    let mut out = [0_u8; 10];
    out[0] = 3;
    out[1] = u8::from(incremental);
    out[2..4].copy_from_slice(&x.to_be_bytes());
    out[4..6].copy_from_slice(&y.to_be_bytes());
    out[6..8].copy_from_slice(&width.to_be_bytes());
    out[8..10].copy_from_slice(&height.to_be_bytes());
    out
}

pub fn key_event(down: bool, keysym: u32) -> [u8; 8] {
    let mut out = [0_u8; 8];
    out[0] = 4;
    out[1] = u8::from(down);
    out[4..8].copy_from_slice(&keysym.to_be_bytes());
    out
}

pub fn pointer_event(buttons: u8, x: u16, y: u16) -> [u8; 6] {
    let mut out = [0_u8; 6];
    out[0] = 5;
    out[1] = buttons;
    out[2..4].copy_from_slice(&x.to_be_bytes());
    out[4..6].copy_from_slice(&y.to_be_bytes());
    out
}

/// Parse "RFB xxx.yyy\n" into (major, minor).
pub fn parse_version(greeting: &[u8; 12]) -> Option<(u16, u16)> {
    if &greeting[..4] != b"RFB " || greeting[7] != b'.' || greeting[11] != b'\n' {
        return None;
    }
    let number = |bytes: &[u8]| -> Option<u16> {
        bytes
            .iter()
            .all(u8::is_ascii_digit)
            .then(|| std::str::from_utf8(bytes).ok()?.parse().ok())?
    };
    Some((number(&greeting[4..7])?, number(&greeting[8..11])?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_have_the_documented_layout() {
        assert_eq!(
            set_pixel_format(&PixelFormat::BGRX),
            [
                0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0
            ]
        );
        assert_eq!(
            PixelFormat::decode(&PixelFormat::BGRX.encode()),
            PixelFormat::BGRX
        );
        assert_eq!(
            set_encodings(&[16, -223]),
            [2, 0, 0, 2, 0, 0, 0, 16, 0xff, 0xff, 0xff, 0x21]
        );
        assert_eq!(
            update_request(true, 1, 2, 640, 480),
            [3, 1, 0, 1, 0, 2, 2, 128, 1, 224]
        );
        assert_eq!(key_event(true, 0xff0d), [4, 1, 0, 0, 0, 0, 0xff, 0x0d]);
        assert_eq!(pointer_event(0b101, 300, 2), [5, 5, 1, 44, 0, 2]);
    }

    #[test]
    fn versions_parse_strictly() {
        assert_eq!(parse_version(b"RFB 003.008\n"), Some((3, 8)));
        assert_eq!(parse_version(b"RFB 003.889\n"), Some((3, 889)));
        assert_eq!(parse_version(b"RFB 03.0008\n"), None);
        assert_eq!(parse_version(b"HTTP/1.1 400"), None);
        assert_eq!(parse_version(b"RFB 0+3.008\n"), None);
    }
}
