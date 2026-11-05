//! The remote desktop's pixels, as BGRA bytes with alpha always 255, and the
//! region changed since the viewer last copied it. Servers send the fourth
//! byte as padding (often 0); it is set to 255 so a viewer can display the
//! pixels directly as opaque BGRA.

use serde::Serialize;

pub const BYTES_PER_PIXEL: usize = 4;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Rect {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}

impl Rect {
    pub fn new(x: u16, y: u16, width: u16, height: u16) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.width == 0 || self.height == 0
    }

    fn right(&self) -> u32 {
        u32::from(self.x) + u32::from(self.width)
    }

    fn bottom(&self) -> u32 {
        u32::from(self.y) + u32::from(self.height)
    }

    pub fn union(&self, other: &Rect) -> Rect {
        if self.is_empty() {
            return *other;
        }
        if other.is_empty() {
            return *self;
        }
        let x = self.x.min(other.x);
        let y = self.y.min(other.y);
        let right = self.right().max(other.right());
        let bottom = self.bottom().max(other.bottom());
        Rect::new(
            x,
            y,
            (right - u32::from(x)) as u16,
            (bottom - u32::from(y)) as u16,
        )
    }

    pub fn pixels(&self) -> usize {
        usize::from(self.width) * usize::from(self.height)
    }
}

#[derive(Debug)]
pub struct Framebuffer {
    width: u16,
    height: u16,
    pixels: Vec<u8>,
    dirty: Rect,
    /// Increments on every resize, so a viewer knows to start over.
    layout: u64,
}

impl Framebuffer {
    pub fn new(width: u16, height: u16) -> Self {
        let mut framebuffer = Self {
            width: 0,
            height: 0,
            pixels: Vec::new(),
            dirty: Rect::default(),
            layout: 0,
        };
        framebuffer.resize(width, height);
        framebuffer
    }

    pub fn width(&self) -> u16 {
        self.width
    }

    pub fn height(&self) -> u16 {
        self.height
    }

    pub fn layout(&self) -> u64 {
        self.layout
    }

    pub fn bounds(&self) -> Rect {
        Rect::new(0, 0, self.width, self.height)
    }

    /// Start over at a new size, black, all of it changed.
    pub fn resize(&mut self, width: u16, height: u16) {
        self.width = width;
        self.height = height;
        self.pixels = [0, 0, 0, 0xff].repeat(usize::from(width) * usize::from(height));
        self.dirty = self.bounds();
        self.layout += 1;
    }

    /// Whether `rect` lies within the framebuffer.
    pub fn contains(&self, rect: &Rect) -> bool {
        rect.right() <= u32::from(self.width) && rect.bottom() <= u32::from(self.height)
    }

    fn offset(&self, x: u16, y: u16) -> usize {
        (usize::from(y) * usize::from(self.width) + usize::from(x)) * BYTES_PER_PIXEL
    }

    fn touch(&mut self, rect: &Rect) {
        self.dirty = self.dirty.union(rect);
    }

    /// Copy `rect.pixels()` BGRX pixels, row by row, from `source`.
    pub fn put(&mut self, rect: &Rect, source: &[u8]) {
        debug_assert!(self.contains(rect));
        debug_assert_eq!(source.len(), rect.pixels() * BYTES_PER_PIXEL);
        let row = usize::from(rect.width) * BYTES_PER_PIXEL;
        for (line, chunk) in source.chunks_exact(row).enumerate() {
            let start = self.offset(rect.x, rect.y + line as u16);
            let target = &mut self.pixels[start..start + row];
            target.copy_from_slice(chunk);
            for pixel in target.as_chunks_mut::<BYTES_PER_PIXEL>().0 {
                pixel[3] = 0xff;
            }
        }
        self.touch(rect);
    }

    /// Fill with `pixel`, made opaque.
    fn opaque(mut pixel: [u8; 4]) -> [u8; 4] {
        pixel[3] = 0xff;
        pixel
    }

    pub fn fill(&mut self, rect: &Rect, pixel: [u8; 4]) {
        debug_assert!(self.contains(rect));
        let pixel = Self::opaque(pixel);
        for line in 0..rect.height {
            let start = self.offset(rect.x, rect.y + line);
            let row = &mut self.pixels[start..start + usize::from(rect.width) * BYTES_PER_PIXEL];
            for chunk in row.as_chunks_mut::<BYTES_PER_PIXEL>().0 {
                *chunk = pixel;
            }
        }
        self.touch(rect);
    }

    /// CopyRect: move a region within the framebuffer. Overlap is handled.
    pub fn copy_within(&mut self, source_x: u16, source_y: u16, rect: &Rect) {
        let source = Rect::new(source_x, source_y, rect.width, rect.height);
        debug_assert!(self.contains(rect) && self.contains(&source));
        let row = usize::from(rect.width) * BYTES_PER_PIXEL;
        let lines: Box<dyn Iterator<Item = u16>> = if source_y < rect.y {
            Box::new((0..rect.height).rev())
        } else {
            Box::new(0..rect.height)
        };
        for line in lines {
            let from = self.offset(source_x, source_y + line);
            let to = self.offset(rect.x, rect.y + line);
            self.pixels.copy_within(from..from + row, to);
        }
        self.touch(rect);
    }

    /// The region changed since the last [`Framebuffer::copy_changes`].
    pub fn dirty(&self) -> Rect {
        self.dirty
    }

    /// Copy the changed region into `destination`, a `width` x `height` BGRX
    /// image with `stride` bytes per row, and clear it. Returns the region
    /// copied, or `None` if the destination's size does not match.
    pub fn copy_changes(
        &mut self,
        destination: &mut [u8],
        stride: usize,
        width: u16,
        height: u16,
    ) -> Option<Rect> {
        if width != self.width
            || height != self.height
            || stride < usize::from(width) * BYTES_PER_PIXEL
            || destination.len() < stride * usize::from(height)
        {
            return None;
        }
        let dirty = self.dirty;
        let row = usize::from(dirty.width) * BYTES_PER_PIXEL;
        for line in 0..dirty.height {
            let y = dirty.y + line;
            let from = self.offset(dirty.x, y);
            let to = usize::from(y) * stride + usize::from(dirty.x) * BYTES_PER_PIXEL;
            destination[to..to + row].copy_from_slice(&self.pixels[from..from + row]);
        }
        self.dirty = Rect::default();
        Some(dirty)
    }

    #[cfg(test)]
    pub fn pixel(&self, x: u16, y: u16) -> [u8; 4] {
        let at = self.offset(x, y);
        self.pixels[at..at + 4].try_into().unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RED: [u8; 4] = [0, 0, 255, 0xff];
    const BLUE: [u8; 4] = [255, 0, 0, 0xff];

    #[test]
    fn puts_fills_and_tracks_one_changed_region() {
        let mut framebuffer = Framebuffer::new(8, 4);
        assert_eq!(framebuffer.dirty(), Rect::new(0, 0, 8, 4));
        let mut image = vec![0_u8; 8 * 4 * 4];
        assert_eq!(
            framebuffer.copy_changes(&mut image, 32, 8, 4),
            Some(Rect::new(0, 0, 8, 4))
        );
        assert!(framebuffer.dirty().is_empty());
        framebuffer.fill(&Rect::new(1, 1, 2, 1), RED);
        // Padding bytes of 0 from the server are made opaque.
        framebuffer.put(
            &Rect::new(6, 2, 1, 2),
            &[[255, 0, 0, 0], [255, 0, 0, 0]].concat(),
        );
        assert_eq!(framebuffer.dirty(), Rect::new(1, 1, 6, 3));
        assert_eq!(
            framebuffer.copy_changes(&mut image, 32, 8, 4),
            Some(Rect::new(1, 1, 6, 3))
        );
        assert_eq!(&image[(8 + 1) * 4..(8 + 1) * 4 + 4], &RED);
        assert_eq!(&image[(3 * 8 + 6) * 4..(3 * 8 + 6) * 4 + 4], &BLUE);
        // A wrong-sized destination is refused, and the change is kept.
        framebuffer.fill(&Rect::new(0, 0, 1, 1), RED);
        assert_eq!(framebuffer.copy_changes(&mut image, 32, 7, 4), None);
        assert_eq!(framebuffer.dirty(), Rect::new(0, 0, 1, 1));
    }

    #[test]
    fn copy_rect_handles_overlap_in_both_directions() {
        let mut framebuffer = Framebuffer::new(4, 4);
        for y in 0..4 {
            framebuffer.fill(&Rect::new(0, y, 4, 1), [y as u8, 0, 0, 0]);
        }
        framebuffer.copy_within(0, 0, &Rect::new(0, 1, 4, 3));
        assert_eq!(
            (0..4)
                .map(|y| framebuffer.pixel(0, y)[0])
                .collect::<Vec<_>>(),
            [0, 0, 1, 2]
        );
        framebuffer.copy_within(0, 1, &Rect::new(0, 0, 4, 3));
        assert_eq!(
            (0..4)
                .map(|y| framebuffer.pixel(0, y)[0])
                .collect::<Vec<_>>(),
            [0, 1, 2, 2]
        );
    }

    #[test]
    fn resizing_starts_over() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let layout = framebuffer.layout();
        framebuffer.resize(3, 1);
        assert_eq!((framebuffer.width(), framebuffer.height()), (3, 1));
        assert_eq!(framebuffer.layout(), layout + 1);
        assert_eq!(framebuffer.dirty(), Rect::new(0, 0, 3, 1));
        assert!(framebuffer.contains(&Rect::new(0, 0, 3, 1)));
        assert!(!framebuffer.contains(&Rect::new(1, 0, 3, 1)));
        assert!(!framebuffer.contains(&Rect::new(u16::MAX, 0, 1, 1)));
    }
}
