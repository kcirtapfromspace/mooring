//! The host's pointer image, sent to a viewer that announced it draws remote
//! cursors, so the pointer over the video matches the remote Mac: an I-beam
//! over text, resize arrows at a window edge.
//!
//! Wire format: `[version=1, 0, 0, 0, width:u16, height:u16, hotspot_x:u16,
//! hotspot_y:u16]`, big-endian, then a PNG of the cursor image. Width and
//! height are the cursor's size in points; the PNG may carry more pixels for
//! Retina. The hotspot lies inside the cursor.

use crate::{Error, Result};
use std::ops::Range;

const VERSION: u8 = 1;
const HEADER: usize = 12;
/// Cursor images are small; this bounds a hostile peer, not real cursors.
pub(crate) const MAX_CURSOR_POINTS: u16 = 256;
pub(crate) const MAX_CURSOR: usize = 64 * 1024;
const PNG_SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct CursorShape {
    pub width: u16,
    pub height: u16,
    pub hotspot_x: u16,
    pub hotspot_y: u16,
}

impl CursorShape {
    fn is_valid(&self) -> bool {
        (1..=MAX_CURSOR_POINTS).contains(&self.width)
            && (1..=MAX_CURSOR_POINTS).contains(&self.height)
            && self.hotspot_x < self.width
            && self.hotspot_y < self.height
    }
}

pub(crate) fn encode(shape: &CursorShape, png: &[u8]) -> Result<Vec<u8>> {
    if !shape.is_valid() || !png.starts_with(PNG_SIGNATURE) || HEADER + png.len() > MAX_CURSOR {
        return Err(Error::Invalid);
    }
    let mut out = Vec::with_capacity(HEADER + png.len());
    out.extend_from_slice(&[VERSION, 0, 0, 0]);
    for value in [shape.width, shape.height, shape.hotspot_x, shape.hotspot_y] {
        out.extend_from_slice(&value.to_be_bytes());
    }
    out.extend_from_slice(png);
    Ok(out)
}

/// A received cursor; the PNG is a range of the caller's receive buffer.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct CursorPacket {
    pub shape: CursorShape,
    pub png: Range<usize>,
}

impl CursorPacket {
    pub(crate) fn parse(data: &[u8]) -> Result<Self> {
        if data.len() <= HEADER || data.len() > MAX_CURSOR || data[..4] != [VERSION, 0, 0, 0] {
            return Err(Error::Protocol);
        }
        let word = |at: usize| u16::from_be_bytes([data[at], data[at + 1]]);
        let shape = CursorShape {
            width: word(4),
            height: word(6),
            hotspot_x: word(8),
            hotspot_y: word(10),
        };
        if !shape.is_valid() || !data[HEADER..].starts_with(PNG_SIGNATURE) {
            return Err(Error::Protocol);
        }
        Ok(Self {
            shape,
            png: HEADER..data.len(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";
    const IBEAM: CursorShape = CursorShape {
        width: 9,
        height: 18,
        hotspot_x: 4,
        hotspot_y: 9,
    };

    #[test]
    fn cursors_round_trip_with_their_hotspot() {
        let wire = encode(&IBEAM, PNG).unwrap();
        let packet = CursorPacket::parse(&wire).unwrap();
        assert_eq!(packet.shape, IBEAM);
        assert_eq!(&wire[packet.png], PNG);
    }

    #[test]
    fn invalid_cursors_are_refused() {
        let shaped = |width, height, hotspot_x, hotspot_y| CursorShape {
            width,
            height,
            hotspot_x,
            hotspot_y,
        };
        for shape in [
            shaped(0, 18, 0, 0),
            shaped(257, 18, 4, 9),
            shaped(9, 18, 9, 9), // hotspot outside
            shaped(9, 18, 4, 18),
        ] {
            assert_eq!(encode(&shape, PNG), Err(Error::Invalid), "{shape:?}");
        }
        assert_eq!(encode(&IBEAM, b"GIF89a"), Err(Error::Invalid));
        let huge = [PNG, &vec![0; MAX_CURSOR]].concat();
        assert_eq!(encode(&IBEAM, &huge), Err(Error::Invalid));
        let good = encode(&IBEAM, PNG).unwrap();
        let mutate = |index: usize, value: u8| {
            let mut copy = good.clone();
            copy[index] = value;
            copy
        };
        for bad in [
            good[..HEADER].to_vec(),
            mutate(0, 2),
            mutate(1, 1),
            mutate(9, 9),     // hotspot x = width
            mutate(12, b'G'), // not a PNG
        ] {
            assert_eq!(CursorPacket::parse(&bad), Err(Error::Protocol), "{bad:?}");
        }
    }
}
