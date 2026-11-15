//! Tight (encoding 7), as libvncserver (x11vnc), TigerVNC and neatvnc (wayvnc)
//! send it, including JPEG, which servers use only when the client sends a
//! quality level.
//!
//! A rectangle is one of:
//! - a fill colour;
//! - a JPEG image;
//! - "basic" pixels, copied, palette-indexed (two colours at one bit per
//!   pixel) or gradient-predicted, zlib-compressed on one of four streams
//!   that last for the whole connection unless the server resets them. Data
//!   under 12 bytes is sent uncompressed.
//!
//! With Mooring's 32-bit pixel format (depth 24), a Tight pixel is three bytes:
//! red, green, blue.
//!
//! Every length is bounded before memory is allocated. Decompressed data must
//! be exactly the size its rectangle needs, and a JPEG must be exactly the
//! rectangle's size. A JPEG the decoder can't read, even one that makes it
//! panic, ends the session with a protocol error and nothing else.

use crate::framebuffer::{BYTES_PER_PIXEL, Rect};
use crate::stream::RfbReader;
use flate2::{Decompress, FlushDecompress, Status};
use std::io;
use std::panic::{AssertUnwindSafe, catch_unwind};
use zune_jpeg::JpegDecoder;
use zune_jpeg::zune_core::bytestream::ZCursor;
use zune_jpeg::zune_core::colorspace::ColorSpace;
use zune_jpeg::zune_core::options::DecoderOptions;

/// Basic data shorter than this is sent without zlib.
const MIN_TO_COMPRESS: usize = 12;
/// The largest length a compact length can carry: 22 bits.
pub const MAX_COMPACT_LENGTH: usize = (1 << 22) - 1;
const STREAMS: usize = 4;

const FILL: u8 = 0x08;
const JPEG: u8 = 0x09;
const READ_FILTER: u8 = 0x04;
const FILTER_COPY: u8 = 0;
const FILTER_PALETTE: u8 = 1;
const FILTER_GRADIENT: u8 = 2;

/// What a Tight rectangle paints.
#[derive(Debug, PartialEq, Eq)]
pub enum Paint {
    /// One BGRX colour over the whole rectangle.
    Fill([u8; 4]),
    /// The rectangle's BGRX pixels, row by row.
    Pixels(Vec<u8>),
}

pub struct TightDecoder {
    streams: [Decompress; STREAMS],
    inflated: Vec<u8>,
}

impl Default for TightDecoder {
    fn default() -> Self {
        Self::new()
    }
}

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

/// One to three bytes, seven bits each and then eight, least significant first.
fn compact_length(reader: &mut RfbReader) -> io::Result<usize> {
    let mut length = 0_usize;
    for shift in [0, 7] {
        let byte = reader.u8()?;
        length |= usize::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok(length);
        }
    }
    Ok(length | usize::from(reader.u8()?) << 14)
}

fn rgb(bytes: &[u8]) -> [u8; 4] {
    [bytes[2], bytes[1], bytes[0], 0xff]
}

impl TightDecoder {
    pub fn new() -> Self {
        Self {
            streams: std::array::from_fn(|_| Decompress::new(true)),
            inflated: Vec::new(),
        }
    }

    /// Read one Tight rectangle. `rect` has been checked to lie inside the
    /// desktop; the caller paints the result.
    pub fn read(&mut self, reader: &mut RfbReader, rect: &Rect) -> io::Result<Paint> {
        let control = reader.u8()?;
        for (stream, inflater) in self.streams.iter_mut().enumerate() {
            if control & (1 << stream) != 0 {
                inflater.reset(true);
            }
        }
        match control >> 4 {
            FILL => {
                let mut pixel = [0_u8; 3];
                reader.read_exact(&mut pixel)?;
                Ok(Paint::Fill(rgb(&pixel)))
            }
            JPEG => {
                let length = compact_length(reader)?;
                let data = reader.bytes(length as u32, MAX_COMPACT_LENGTH as u32)?;
                decode_jpeg(&data, rect).map(Paint::Pixels)
            }
            basic if basic & !(READ_FILTER | 0x03) == 0 => self.basic(reader, rect, basic),
            other => Err(invalid(format!(
                "The server sent Tight compression {other:#x}, which Mooring did not ask for."
            ))),
        }
    }

    fn basic(&mut self, reader: &mut RfbReader, rect: &Rect, kind: u8) -> io::Result<Paint> {
        let stream = usize::from(kind & 0x03);
        let filter = if kind & READ_FILTER != 0 {
            reader.u8()?
        } else {
            FILTER_COPY
        };
        let (width, height) = (usize::from(rect.width), usize::from(rect.height));
        let pixels = rect.pixels();
        match filter {
            FILTER_COPY | FILTER_GRADIENT => {
                let data = self.data(reader, stream, pixels * 3)?;
                let mut out = Vec::with_capacity(pixels * BYTES_PER_PIXEL);
                if filter == FILTER_COPY {
                    for pixel in data.as_chunks::<3>().0 {
                        out.extend_from_slice(&rgb(pixel));
                    }
                } else {
                    gradient(data, width, &mut out);
                }
                Ok(Paint::Pixels(out))
            }
            FILTER_PALETTE => {
                let colours = usize::from(reader.u8()?) + 1;
                if colours < 2 {
                    return Err(invalid("A Tight palette needs at least two colours."));
                }
                let mut table = vec![0_u8; colours * 3];
                reader.read_exact(&mut table)?;
                let palette: Vec<[u8; 4]> =
                    table.as_chunks::<3>().0.iter().map(|p| rgb(p)).collect();
                let mut out = Vec::with_capacity(pixels * BYTES_PER_PIXEL);
                if colours == 2 {
                    let stride = width.div_ceil(8);
                    let data = self.data(reader, stream, stride * height)?;
                    for row in data.chunks_exact(stride.max(1)).take(height) {
                        for x in 0..width {
                            let bit = row[x / 8] >> (7 - x % 8) & 1;
                            out.extend_from_slice(&palette[usize::from(bit)]);
                        }
                    }
                } else {
                    let data = self.data(reader, stream, pixels)?;
                    for &index in data {
                        let colour = palette.get(usize::from(index)).ok_or_else(|| {
                            invalid("A Tight pixel points past the end of its palette.")
                        })?;
                        out.extend_from_slice(colour);
                    }
                }
                Ok(Paint::Pixels(out))
            }
            other => Err(invalid(format!(
                "The server sent Tight filter {other}, which Mooring does not know."
            ))),
        }
    }

    /// The rectangle's `size` bytes of filtered data: as sent when short,
    /// otherwise inflated from `stream`, which must give exactly `size`.
    fn data(&mut self, reader: &mut RfbReader, stream: usize, size: usize) -> io::Result<&[u8]> {
        self.inflated.clear();
        if size < MIN_TO_COMPRESS {
            self.inflated.resize(size, 0);
            reader.read_exact(&mut self.inflated)?;
            return Ok(&self.inflated);
        }
        let length = compact_length(reader)?;
        let compressed = reader.bytes(length as u32, MAX_COMPACT_LENGTH as u32)?;
        // One spare byte shows a stream that inflates to more than `size`.
        self.inflated.reserve_exact(size + 1);
        let inflater = &mut self.streams[stream];
        let mut consumed = 0;
        loop {
            let (before_in, before_out) = (inflater.total_in(), self.inflated.len());
            let status = inflater
                .decompress_vec(
                    &compressed[consumed..],
                    &mut self.inflated,
                    FlushDecompress::Sync,
                )
                .map_err(|error| invalid(format!("Tight data is not valid zlib: {error}")))?;
            consumed += (inflater.total_in() - before_in) as usize;
            if self.inflated.len() > size {
                return Err(invalid(
                    "Tight data decompresses to more than its rectangle holds.",
                ));
            }
            let progressed = inflater.total_in() != before_in || self.inflated.len() != before_out;
            if consumed == compressed.len() || status == Status::StreamEnd || !progressed {
                break;
            }
        }
        if self.inflated.len() != size || consumed != compressed.len() {
            return Err(invalid(
                "Tight data does not decompress to the size of its rectangle.",
            ));
        }
        Ok(&self.inflated)
    }
}

/// Undo the gradient filter: each component was sent as its difference from
/// left + above - above-left, clamped to 0..=255, all modulo 256.
fn gradient(data: &[u8], width: usize, out: &mut Vec<u8>) {
    if width == 0 {
        return;
    }
    let mut above = vec![0_u8; width * 3];
    let mut row = vec![0_u8; width * 3];
    for diffs in data.chunks_exact(width * 3) {
        for x in 0..width {
            for c in 0..3 {
                let at = x * 3 + c;
                let estimate = if x == 0 {
                    i32::from(above[at])
                } else {
                    i32::from(above[at]) + i32::from(row[at - 3]) - i32::from(above[at - 3])
                };
                row[at] = (estimate.clamp(0, 255) as u8).wrapping_add(diffs[at]);
            }
            out.extend_from_slice(&rgb(&row[x * 3..x * 3 + 3]));
        }
        std::mem::swap(&mut above, &mut row);
    }
}

/// Decode a JPEG that must be exactly `rect`'s size into BGRX.
pub fn decode_jpeg(data: &[u8], rect: &Rect) -> io::Result<Vec<u8>> {
    let (width, height) = (usize::from(rect.width), usize::from(rect.height));
    let decoded = catch_unwind(AssertUnwindSafe(|| {
        // RGBA has a NEON colour conversion; BGRA is scalar. Swapped below.
        let options = DecoderOptions::default()
            .jpeg_set_out_colorspace(ColorSpace::RGBA)
            .set_max_width(width)
            .set_max_height(height);
        let mut decoder = JpegDecoder::new_with_options(ZCursor::new(data), options);
        decoder.decode_headers().map_err(|e| e.to_string())?;
        let info = decoder.info().ok_or("no image header")?;
        if (usize::from(info.width), usize::from(info.height)) != (width, height) {
            return Err(format!(
                "a {}x{} image for a {width}x{height} rectangle",
                info.width, info.height
            ));
        }
        decoder.decode().map_err(|e| e.to_string())
    }));
    let mut pixels = match decoded {
        Ok(Ok(pixels)) => pixels,
        Ok(Err(reason)) => {
            return Err(invalid(format!(
                "The server sent a Tight JPEG Mooring can't use: {reason}."
            )));
        }
        Err(_) => {
            return Err(invalid(
                "The server sent a Tight JPEG that failed to decode.",
            ));
        }
    };
    if pixels.len() != width * height * BYTES_PER_PIXEL {
        return Err(invalid("A Tight JPEG decoded to the wrong size."));
    }
    for pixel in pixels.as_chunks_mut::<BYTES_PER_PIXEL>().0 {
        pixel.swap(0, 2);
        pixel[3] = 0xff;
    }
    Ok(pixels)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use flate2::{Compress, Compression, FlushCompress};

    /// A JPEG from macOS ImageIO (`sips`, quality 90), metadata removed:
    /// 32x16, the left half red (220, 0, 0) and the right half blue.
    pub const RED_BLUE_JPEG: &[u8] = include_bytes!("../testdata/red-blue-32x16.jpg");

    pub fn compact(length: usize) -> Vec<u8> {
        let mut out = vec![(length & 0x7f) as u8];
        if length > 0x7f {
            out[0] |= 0x80;
            out.push((length >> 7 & 0x7f) as u8);
            if length > 0x3fff {
                out[1] |= 0x80;
                out.push((length >> 14) as u8);
            }
        }
        out
    }

    /// Four zlib streams that last across rectangles, as a server keeps them.
    pub struct TightEncoder(pub Vec<Compress>);

    impl TightEncoder {
        pub fn new() -> Self {
            Self(
                (0..STREAMS)
                    .map(|_| Compress::new(Compression::default(), true))
                    .collect(),
            )
        }

        /// The data part of a basic rectangle: as is when short, else a
        /// compact length and `data` compressed with a sync flush.
        pub fn data(&mut self, stream: usize, data: &[u8]) -> Vec<u8> {
            if data.len() < MIN_TO_COMPRESS {
                return data.to_vec();
            }
            let compress = &mut self.0[stream];
            let mut zipped = Vec::with_capacity(data.len() + 1024);
            let mut consumed = 0;
            loop {
                let before = compress.total_in();
                zipped.reserve(4096);
                compress
                    .compress_vec(&data[consumed..], &mut zipped, FlushCompress::Sync)
                    .unwrap();
                consumed += (compress.total_in() - before) as usize;
                if consumed == data.len() && zipped.len() < zipped.capacity() {
                    break;
                }
            }
            let mut out = compact(zipped.len());
            out.extend_from_slice(&zipped);
            out
        }
    }

    fn reader(bytes: Vec<u8>) -> RfbReader {
        RfbReader::new(Box::new(io::Cursor::new(bytes)))
    }

    fn read(decoder: &mut TightDecoder, bytes: Vec<u8>, rect: &Rect) -> io::Result<Paint> {
        let mut reader = reader(bytes);
        let paint = decoder.read(&mut reader, rect)?;
        // Nothing of the rectangle may be left unread.
        assert!(reader.u8().is_err(), "unread bytes after the rectangle");
        Ok(paint)
    }

    fn pixels(paint: Paint) -> Vec<[u8; 4]> {
        match paint {
            Paint::Pixels(bytes) => bytes.as_chunks::<4>().0.to_vec(),
            other => panic!("not pixels: {other:?}"),
        }
    }

    const RED: [u8; 4] = [0, 0, 200, 0xff];
    const BLUE: [u8; 4] = [200, 0, 0, 0xff];

    #[test]
    fn compact_lengths_round_trip_at_every_width() {
        for length in [0, 1, 127, 128, 300, 16_383, 16_384, MAX_COMPACT_LENGTH] {
            let mut reader = reader(compact(length));
            assert_eq!(compact_length(&mut reader).unwrap(), length);
        }
    }

    #[test]
    fn fill_copy_palette_and_gradient_across_shared_streams() {
        let mut encoder = TightEncoder::new();
        let mut decoder = TightDecoder::new();
        let rect = Rect::new(0, 0, 4, 2);
        // Fill.
        assert_eq!(
            read(&mut decoder, vec![FILL << 4, 200, 0, 0], &rect).unwrap(),
            Paint::Fill(RED)
        );
        // Copy, short: 1x3 pixels are 9 bytes, sent without zlib.
        let short = Rect::new(0, 0, 1, 3);
        let mut message = vec![0x00];
        message.extend_from_slice(&[200, 0, 0, 0, 0, 200, 1, 2, 3]);
        assert_eq!(
            pixels(read(&mut decoder, message, &short).unwrap()),
            [RED, BLUE, [3, 2, 1, 0xff]]
        );
        // Copy through stream 1, twice: the stream lasts between rectangles.
        let copy: Vec<u8> = [[200, 0, 0], [0, 0, 200]].repeat(4).concat();
        for _ in 0..2 {
            let mut message = vec![0x10];
            message.extend(encoder.data(1, &copy));
            assert_eq!(
                pixels(read(&mut decoder, message, &rect).unwrap()),
                [RED, BLUE].repeat(4)
            );
        }
        // Two colours at one bit per pixel, rows padded to a byte, stream 2
        // with an explicit filter.
        let mono = Rect::new(0, 0, 9, 2);
        let bits = [0b1010_1010, 0b1000_0000, 0b0101_0101, 0b0000_0000];
        let mut message = vec![0x40 | 0x02 << 4, FILTER_PALETTE, 1, 200, 0, 0, 0, 0, 200];
        message.extend(encoder.data(2, &bits));
        let got = pixels(read(&mut decoder, message, &mono).unwrap());
        let first: Vec<[u8; 4]> = (0..9)
            .map(|x| if x % 2 == 0 { BLUE } else { RED })
            .collect();
        let second: Vec<[u8; 4]> = (0..9)
            .map(|x| if x % 2 == 0 { RED } else { BLUE })
            .collect();
        assert_eq!(got, [first, second].concat());
        // Three colours at a byte per pixel, stream 3.
        let mut message = vec![
            0x40 | 0x03 << 4,
            FILTER_PALETTE,
            2,
            200,
            0,
            0,
            0,
            0,
            200,
            9,
            9,
            9,
        ];
        message.extend(encoder.data(3, &[0, 1, 2, 2, 1, 0, 0, 1]));
        assert_eq!(
            pixels(read(&mut decoder, message, &rect).unwrap()),
            [
                RED,
                BLUE,
                [9, 9, 9, 0xff],
                [9, 9, 9, 0xff],
                BLUE,
                RED,
                RED,
                BLUE
            ]
        );
        // Gradient on stream 0: a smooth ramp sends small differences.
        let ramp = Rect::new(0, 0, 3, 2);
        let source: [[u8; 3]; 6] = [
            [10, 20, 30],
            [20, 30, 40],
            [30, 40, 50],
            [20, 30, 40],
            [30, 40, 50],
            [40, 50, 255],
        ];
        let filtered = gradient_filter(&source, 3);
        let mut message = vec![0x40, FILTER_GRADIENT];
        message.extend(encoder.data(0, &filtered));
        let expected: Vec<[u8; 4]> = source.iter().map(|p| rgb(p)).collect();
        assert_eq!(
            pixels(read(&mut decoder, message, &ramp).unwrap()),
            expected
        );
    }

    /// The server side of the gradient filter, for the test.
    fn gradient_filter(source: &[[u8; 3]], width: usize) -> Vec<u8> {
        let at = |x: usize, y: usize, c: usize| i32::from(source[y * width + x][c]);
        let mut out = Vec::new();
        for y in 0..source.len() / width {
            for x in 0..width {
                for c in 0..3 {
                    let above = if y > 0 { at(x, y - 1, c) } else { 0 };
                    let left = if x > 0 { at(x - 1, y, c) } else { 0 };
                    let corner = if x > 0 && y > 0 {
                        at(x - 1, y - 1, c)
                    } else {
                        0
                    };
                    let estimate = (left + above - corner).clamp(0, 255);
                    out.push((at(x, y, c) - estimate).rem_euclid(256) as u8);
                }
            }
        }
        out
    }

    #[test]
    fn a_reset_starts_a_stream_over() {
        let mut encoder = TightEncoder::new();
        let mut decoder = TightDecoder::new();
        let rect = Rect::new(0, 0, 4, 2);
        let copy = [200_u8, 0, 0].repeat(8);
        let mut message = vec![0x00];
        message.extend(encoder.data(0, &copy));
        read(&mut decoder, message, &rect).unwrap();
        // The server starts stream 0 again and says so with bit 0.
        encoder.0[0] = Compress::new(Compression::default(), true);
        let mut message = vec![0x01];
        message.extend(encoder.data(0, &copy));
        assert_eq!(
            pixels(read(&mut decoder, message, &rect).unwrap()),
            [RED; 8]
        );
        // Without the reset bit, a new stream's header is not valid there.
        let mut fresh = TightEncoder::new();
        let mut message = vec![0x00];
        message.extend(fresh.data(0, &copy));
        let error = read(&mut decoder, message, &rect).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData, "{error}");
    }

    #[test]
    fn jpeg_rectangles_decode_to_bgrx_of_their_exact_size() {
        let mut decoder = TightDecoder::new();
        let rect = Rect::new(8, 4, 32, 16);
        let mut message = vec![JPEG << 4];
        message.extend(compact(RED_BLUE_JPEG.len()));
        message.extend_from_slice(RED_BLUE_JPEG);
        let got = pixels(read(&mut decoder, message, &rect).unwrap());
        assert_eq!(got.len(), 32 * 16);
        // Lossy, so within a margin, away from the edge between the halves.
        let near = |pixel: [u8; 4], want: [u8; 4]| {
            pixel.iter().zip(want).all(|(a, b)| a.abs_diff(b) <= 24)
        };
        for y in 0..16 {
            assert!(
                near(got[y * 32 + 3], [0, 0, 220, 0xff]),
                "{:?}",
                got[y * 32 + 3]
            );
            assert!(
                near(got[y * 32 + 28], [220, 0, 0, 0xff]),
                "{:?}",
                got[y * 32 + 28]
            );
        }
        // A JPEG of another size, a corrupt one, and a truncated one: refused.
        for (bytes, size) in [
            (RED_BLUE_JPEG.to_vec(), Rect::new(0, 0, 16, 16)),
            (RED_BLUE_JPEG.to_vec(), Rect::new(0, 0, 64, 16)),
            ([&RED_BLUE_JPEG[..20], &[0xff; 200][..]].concat(), rect),
            (RED_BLUE_JPEG[..RED_BLUE_JPEG.len() / 2].to_vec(), rect),
            (vec![0xff, 0xd8, 0xff, 0xd9], rect),
        ] {
            assert!(
                decode_jpeg(&bytes, &size).is_err(),
                "{} bytes accepted",
                bytes.len()
            );
        }
    }

    #[test]
    fn malformed_rectangles_are_refused_before_allocation() {
        let mut decoder = TightDecoder::new();
        let rect = Rect::new(0, 0, 4, 2);
        let refused = |decoder: &mut TightDecoder, bytes: Vec<u8>| {
            let error = read(decoder, bytes, &rect).unwrap_err();
            assert!(
                matches!(
                    error.kind(),
                    io::ErrorKind::InvalidData | io::ErrorKind::UnexpectedEof
                ),
                "{error:?}"
            );
        };
        // PNG (0xA) and unknown compression types were never asked for.
        refused(&mut decoder, vec![0xA0, 0]);
        refused(&mut decoder, vec![0xF0]);
        // An unknown filter, a one-colour palette, an index past the palette.
        refused(&mut decoder, vec![0x40, 7]);
        refused(&mut decoder, vec![0x40, FILTER_PALETTE, 0, 1, 2, 3]);
        let mut message = vec![0x40, FILTER_PALETTE, 2, 1, 1, 1, 2, 2, 2, 3, 3, 3];
        message.extend_from_slice(&[0, 1, 2, 3, 0, 0, 0, 0]);
        refused(&mut decoder, message);
        // Data that inflates to more, or less, than the rectangle needs.
        let mut encoder = TightEncoder::new();
        let mut message = vec![0x01];
        message.extend(encoder.data(0, &[7_u8; 25]));
        refused(&mut decoder, message);
        let mut encoder = TightEncoder::new();
        let mut message = vec![0x01];
        message.extend(encoder.data(0, &[7_u8; 23]));
        refused(&mut decoder, message);
        // A length beyond the 22-bit limit cannot be expressed; the largest
        // one is refused unread when the stream ends early.
        let mut message = vec![JPEG << 4];
        message.extend(compact(MAX_COMPACT_LENGTH));
        refused(&mut decoder, message);
    }
}
