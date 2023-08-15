use crate::arch::kernel_args;
use spin::Mutex;

pub static FRAMEBUFFER: Mutex<Option<Framebuffer>> = Mutex::new(None);

pub struct Framebuffer<'a> {
    pub buffer: &'a mut [u32],
    pub width: u32,
    pub height: u32,
    pub scanline_length: u32,
    pub color_format: kernel_args::ColorFormat,
}

impl<'a> Framebuffer<'a> {
    pub fn clear(&mut self) {
        self.buffer.fill(0);
    }

    pub fn fill_box(&mut self, start_pos: (u32, u32), dims: (u32, u32), color: u32) {
        for y in start_pos.1..start_pos.1 + dims.1 {
            for x in start_pos.0..start_pos.0 + dims.0 {
                self.set((x, y), color);
            }
        }
    }

    #[inline]
    pub fn get(&self, pos: (u32, u32)) -> u32 {
        self.buffer[(pos.1 * self.scanline_length + pos.0) as usize]
    }

    #[inline]
    pub fn set(&mut self, pos: (u32, u32), color: u32) {
        self.buffer[(pos.1 * self.scanline_length + pos.0) as usize] = color;
    }
}
