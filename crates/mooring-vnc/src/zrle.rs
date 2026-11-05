//! ZRLE (encoding 16): one zlib stream per connection, carrying 64x64 tiles
//! of raw, solid, packed-palette, RLE and palette-RLE pixels.
//!
//! With Mooring's 32-bit pixel format (depth 24), a compressed pixel is the
//! three low bytes: blue, green, red. Decompressed output is bounded by the
//! largest valid encoding of the rectangle, so a hostile stream cannot make
//! Mooring allocate without limit.

use crate::framebuffer::{BYTES_PER_PIXEL, Framebuffer, Rect};
use flate2::{Decompress, FlushDecompress, Status};

const TILE: u16 = 64;
/// Compressed bytes for one rectangle beyond this are refused.
pub const MAX_COMPRESSED_BYTES: u32 = 64 << 20;

pub struct ZrleDecoder {
    inflater: Decompress,
    output: Vec<u8>,
}

impl Default for ZrleDecoder {
    fn default() -> Self {
        Self::new()
    }
}

/// The most bytes a valid ZRLE rectangle can decompress to: per tile a
/// subencoding byte and a 127-colour palette, and at most 4 bytes per pixel
/// (a 3-byte pixel and a 1-byte run length).
pub fn max_decompressed(rect: &Rect) -> usize {
    let tiles = usize::from(rect.width.div_ceil(TILE)) * usize::from(rect.height.div_ceil(TILE));
    tiles * (1 + 127 * 3) + rect.pixels() * 4
}

struct Input<'a> {
    data: &'a [u8],
    at: usize,
}

impl<'a> Input<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8], String> {
        let end = self
            .at
            .checked_add(count)
            .filter(|end| *end <= self.data.len())
            .ok_or("ZRLE data ended inside a tile")?;
        let slice = &self.data[self.at..end];
        self.at = end;
        Ok(slice)
    }

    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }

    fn pixel(&mut self) -> Result<[u8; 4], String> {
        let bytes = self.take(3)?;
        Ok([bytes[0], bytes[1], bytes[2], 0xff])
    }

    fn palette(&mut self, size: usize) -> Result<Vec<[u8; 4]>, String> {
        (0..size).map(|_| self.pixel()).collect()
    }

    /// 1 + the sum of bytes, where 255 means another byte follows.
    fn run_length(&mut self, limit: usize) -> Result<usize, String> {
        let mut length = 1_usize;
        loop {
            let byte = self.u8()?;
            length += usize::from(byte);
            if length > limit {
                return Err("a ZRLE run is longer than its tile".into());
            }
            if byte != 255 {
                return Ok(length);
            }
        }
    }
}

impl ZrleDecoder {
    pub fn new() -> Self {
        Self {
            inflater: Decompress::new(true),
            output: Vec::new(),
        }
    }

    fn inflate(&mut self, compressed: &[u8], limit: usize) -> Result<(), String> {
        self.output.clear();
        self.output
            .reserve(limit.min(compressed.len().saturating_mul(1032)).max(4096));
        let mut consumed = 0;
        while consumed < compressed.len() {
            if self.output.len() == self.output.capacity() {
                if self.output.len() >= limit {
                    return Err("ZRLE data decompresses to more than its rectangle can hold".into());
                }
                let more = (self.output.len()).max(4096).min(limit - self.output.len());
                self.output.reserve(more);
            }
            let before = self.inflater.total_in();
            let status = self
                .inflater
                .decompress_vec(
                    &compressed[consumed..],
                    &mut self.output,
                    FlushDecompress::Sync,
                )
                .map_err(|error| format!("ZRLE data is not valid zlib: {error}"))?;
            consumed += (self.inflater.total_in() - before) as usize;
            if self.output.len() > limit {
                return Err("ZRLE data decompresses to more than its rectangle can hold".into());
            }
            if status == Status::StreamEnd && consumed < compressed.len() {
                return Err("the ZRLE zlib stream ended early".into());
            }
        }
        Ok(())
    }

    /// Decode one ZRLE rectangle into `framebuffer`. `rect` has been checked
    /// to lie inside it.
    pub fn decode(
        &mut self,
        compressed: &[u8],
        rect: &Rect,
        framebuffer: &mut Framebuffer,
    ) -> Result<(), String> {
        self.inflate(compressed, max_decompressed(rect))?;
        let output = std::mem::take(&mut self.output);
        let result = decode_tiles(&output, rect, framebuffer);
        self.output = output;
        result
    }
}

fn decode_tiles(data: &[u8], rect: &Rect, framebuffer: &mut Framebuffer) -> Result<(), String> {
    let mut input = Input { data, at: 0 };
    let mut tile_pixels: Vec<u8> =
        Vec::with_capacity(usize::from(TILE) * usize::from(TILE) * BYTES_PER_PIXEL);
    for tile_y in (0..rect.height).step_by(usize::from(TILE)) {
        for tile_x in (0..rect.width).step_by(usize::from(TILE)) {
            let tile = Rect::new(
                rect.x + tile_x,
                rect.y + tile_y,
                (rect.width - tile_x).min(TILE),
                (rect.height - tile_y).min(TILE),
            );
            let count = tile.pixels();
            let subencoding = input.u8()?;
            match subencoding {
                0 => {
                    tile_pixels.clear();
                    for _ in 0..count {
                        tile_pixels.extend_from_slice(&input.pixel()?);
                    }
                    framebuffer.put(&tile, &tile_pixels);
                }
                1 => {
                    let pixel = input.pixel()?;
                    framebuffer.fill(&tile, pixel);
                }
                2..=16 => {
                    let palette = input.palette(usize::from(subencoding))?;
                    let bits = match subencoding {
                        2 => 1,
                        3 | 4 => 2,
                        _ => 4,
                    };
                    let row_bytes = (usize::from(tile.width) * bits).div_ceil(8);
                    tile_pixels.clear();
                    for _ in 0..tile.height {
                        let row = input.take(row_bytes)?;
                        for x in 0..usize::from(tile.width) {
                            let bit = x * bits;
                            let index = (row[bit / 8] >> (8 - bits - bit % 8)) & ((1 << bits) - 1);
                            let pixel = palette
                                .get(usize::from(index))
                                .ok_or("a ZRLE palette index is out of range")?;
                            tile_pixels.extend_from_slice(pixel);
                        }
                    }
                    framebuffer.put(&tile, &tile_pixels);
                }
                128 => {
                    tile_pixels.clear();
                    while tile_pixels.len() < count * BYTES_PER_PIXEL {
                        let pixel = input.pixel()?;
                        let left = count - tile_pixels.len() / BYTES_PER_PIXEL;
                        let length = input.run_length(left)?;
                        for _ in 0..length {
                            tile_pixels.extend_from_slice(&pixel);
                        }
                    }
                    framebuffer.put(&tile, &tile_pixels);
                }
                130..=255 => {
                    let palette = input.palette(usize::from(subencoding - 128))?;
                    tile_pixels.clear();
                    while tile_pixels.len() < count * BYTES_PER_PIXEL {
                        let byte = input.u8()?;
                        let pixel = palette
                            .get(usize::from(byte & 0x7f))
                            .ok_or("a ZRLE palette index is out of range")?;
                        let left = count - tile_pixels.len() / BYTES_PER_PIXEL;
                        let length = if byte & 0x80 != 0 {
                            input.run_length(left)?
                        } else {
                            1
                        };
                        for _ in 0..length {
                            tile_pixels.extend_from_slice(pixel);
                        }
                    }
                    framebuffer.put(&tile, &tile_pixels);
                }
                other => return Err(format!("ZRLE subencoding {other} is not valid")),
            }
        }
    }
    if input.at != data.len() {
        return Err("ZRLE data has bytes left over after its tiles".into());
    }
    Ok(())
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use flate2::{Compress, Compression, FlushCompress};

    /// A server's side of the zlib stream, for tests.
    pub struct ZrleEncoder(Compress);

    impl Default for ZrleEncoder {
        fn default() -> Self {
            Self::new()
        }
    }

    impl ZrleEncoder {
        pub fn new() -> Self {
            Self(Compress::new(Compression::default(), true))
        }

        /// Compress `tiles` with a sync flush, as a server does per rectangle.
        pub fn rect(&mut self, tiles: &[u8]) -> Vec<u8> {
            let mut out = Vec::with_capacity(tiles.len() + 1024);
            let mut consumed = 0;
            loop {
                let before = self.0.total_in();
                out.reserve(4096);
                self.0
                    .compress_vec(&tiles[consumed..], &mut out, FlushCompress::Sync)
                    .unwrap();
                consumed += (self.0.total_in() - before) as usize;
                if consumed == tiles.len() && out.len() < out.capacity() {
                    return out;
                }
            }
        }
    }

    const R: [u8; 3] = [0, 0, 200];
    const G: [u8; 3] = [0, 200, 0];
    const B: [u8; 3] = [200, 0, 0];

    fn px(c: [u8; 3]) -> [u8; 4] {
        [c[0], c[1], c[2], 0xff]
    }

    #[test]
    fn decodes_every_subencoding_across_rects_of_one_stream() {
        let mut framebuffer = Framebuffer::new(70, 3);
        let mut encoder = ZrleEncoder::new();
        let mut decoder = ZrleDecoder::new();
        // Rect 1: 70x1 is two tiles: raw (64 pixels), then solid (6).
        let mut tiles = vec![0_u8];
        for i in 0..64 {
            tiles.extend_from_slice(if i % 2 == 0 { &R } else { &G });
        }
        tiles.push(1);
        tiles.extend_from_slice(&B);
        decoder
            .decode(
                &encoder.rect(&tiles),
                &Rect::new(0, 0, 70, 1),
                &mut framebuffer,
            )
            .unwrap();
        assert_eq!(framebuffer.pixel(0, 0), px(R));
        assert_eq!(framebuffer.pixel(1, 0), px(G));
        assert_eq!(framebuffer.pixel(69, 0), px(B));
        // Rect 2: packed palette of 2 colours, 1 bit per pixel, 3x2.
        let mut tiles = vec![2_u8];
        tiles.extend_from_slice(&R);
        tiles.extend_from_slice(&B);
        tiles.extend_from_slice(&[0b1010_0000, 0b0100_0000]);
        decoder
            .decode(
                &encoder.rect(&tiles),
                &Rect::new(0, 1, 3, 2),
                &mut framebuffer,
            )
            .unwrap();
        assert_eq!(framebuffer.pixel(0, 1), px(B));
        assert_eq!(framebuffer.pixel(1, 1), px(R));
        assert_eq!(framebuffer.pixel(2, 1), px(B));
        assert_eq!(framebuffer.pixel(1, 2), px(B));
        // Rect 3, 65x16 in the same stream: a 64x16 tile of plain RLE (one
        // run of 1024 = 1 + 255 * 4 + 3), then a 1x16 tile of palette RLE
        // (a run of 15 blue, then one red).
        let mut tiles = vec![128_u8];
        tiles.extend_from_slice(&G);
        tiles.extend_from_slice(&[255, 255, 255, 255, 3]);
        tiles.push(130);
        tiles.extend_from_slice(&R);
        tiles.extend_from_slice(&B);
        tiles.extend_from_slice(&[0x81, 14, 0]);
        let mut framebuffer = Framebuffer::new(65, 16);
        decoder
            .decode(
                &encoder.rect(&tiles),
                &Rect::new(0, 0, 65, 16),
                &mut framebuffer,
            )
            .unwrap();
        assert_eq!(framebuffer.pixel(0, 0), px(G));
        assert_eq!(framebuffer.pixel(63, 15), px(G));
        assert_eq!(framebuffer.pixel(64, 0), px(B));
        assert_eq!(framebuffer.pixel(64, 14), px(B));
        assert_eq!(framebuffer.pixel(64, 15), px(R));
    }

    #[test]
    fn malformed_and_oversized_data_is_refused() {
        let rect = Rect::new(0, 0, 4, 4);
        let mut framebuffer = Framebuffer::new(4, 4);
        for tiles in [
            vec![17_u8],                                              // unused subencoding
            vec![129_u8],                                             // unused subencoding
            vec![1_u8, 0, 0],                                         // solid pixel cut short
            vec![2_u8, 0, 0, 0, 0, 0, 0],                             // palette, no indices
            [vec![128_u8], R.to_vec(), vec![255, 255]].concat(),      // run too long
            [vec![130_u8], R.to_vec(), G.to_vec(), vec![5]].concat(), // index 5 of 2
            [vec![1_u8], R.to_vec(), vec![9]].concat(),               // bytes left over
        ] {
            let mut decoder = ZrleDecoder::new();
            let compressed = ZrleEncoder::new().rect(&tiles);
            assert!(
                decoder
                    .decode(&compressed, &rect, &mut framebuffer)
                    .is_err(),
                "{tiles:?}"
            );
        }
        // A zlib bomb: far more output than a 4x4 rect can need.
        let bomb = ZrleEncoder::new().rect(&vec![0_u8; 1 << 20]);
        assert!(bomb.len() < 4096);
        let error = ZrleDecoder::new()
            .decode(&bomb, &rect, &mut framebuffer)
            .unwrap_err();
        assert!(error.contains("more than its rectangle"), "{error}");
        assert!(
            ZrleDecoder::new()
                .decode(b"not zlib", &rect, &mut framebuffer)
                .is_err()
        );
    }
}
