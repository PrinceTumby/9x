use crate::core_graphics::FRAMEBUFFER;
use alloc::collections::TryReserveError;
use alloc::vec::Vec;
use spin::Mutex;

pub mod psf {
    use core::mem::size_of;

    pub const MAGIC: u32 = 0x864AB572;
    pub const VERSION: u32 = 0x0;

    #[derive(Clone, Copy, Debug)]
    pub struct Header {
        pub magic: u32,
        pub version: u32,
        pub header_size: u32,
        pub flags: u32,
        pub num_glyphs: u32,
        pub bytes_per_glyph: u32,
        pub height: u32,
        pub width: u32,
    }

    impl Header {
        /// Parses a PSF header from bytes, returns `Err(())` if the magic or version does not
        /// match.
        pub fn from_bytes(bytes: [u8; size_of::<Header>()]) -> Result<Self, ()> {
            let magic = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            let version = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
            if magic != MAGIC || version != VERSION {
                return Err(());
            }
            Ok(Self {
                magic,
                version,
                header_size: u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]),
                flags: u32::from_le_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]),
                num_glyphs: u32::from_le_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]),
                bytes_per_glyph: u32::from_le_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]),
                height: u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]),
                width: u32::from_le_bytes([bytes[28], bytes[29], bytes[30], bytes[31]]),
            })
        }
    }

    #[derive(Clone, Copy)]
    pub struct Font<'a> {
        pub header: Header,
        pub font_data: &'a [u8],
    }

    impl<'a> Font<'a> {
        pub fn new(file: &'a [u8]) -> Result<Self, &str> {
            let header_slice = &file[0..size_of::<Header>()];
            let header = Header::from_bytes(header_slice.try_into().map_err(|_| "file too small")?)
                .map_err(|_| "invalid magic")?;
            if header.bytes_per_glyph != 16 {
                return Err("invalid bytes per glyph");
            }
            Ok(Self {
                header,
                font_data: &file[32..],
            })
        }

        #[inline]
        pub fn get_character(&self, character: char) -> &[u8] {
            let mut character_usize = character as usize;
            // Replace unknown characters with '?' if exists
            if character_usize >= self.header.num_glyphs as usize {
                character_usize = '?' as usize;
            }
            let start_pos = self.header.bytes_per_glyph as usize * character_usize;
            let end_pos = start_pos + self.header.bytes_per_glyph as usize;
            if end_pos >= self.font_data.len() {
                return &[];
            }
            return &self.font_data[start_pos..end_pos];
        }
    }
}

static VGA_COLORS: [u32; 8] = [
    0x000000, 0xAA0000, 0x00AA00, 0xAAAA00, 0x0000AA, 0xAA00AA, 0x00AAAA, 0xAAAAAA,
];

static VGA_BRIGHT_COLORS: [u32; 8] = [
    0x555555, 0xFF5555, 0x55FF55, 0xFFFF55, 0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF,
];

#[derive(Clone, Copy, PartialEq, Eq)]
struct ScreenChar {
    pub character: char,
    pub foreground_color: u32,
    pub background_color: u32,
}

impl Default for ScreenChar {
    fn default() -> Self {
        Self {
            character: ' ',
            foreground_color: VGA_BRIGHT_COLORS[7],
            background_color: VGA_COLORS[0],
        }
    }
}

struct TerminalState {
    pub mode: TerminalMode,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub foreground_color: u32,
    pub background_color: u32,
}

impl Default for TerminalState {
    fn default() -> Self {
        Self {
            mode: TerminalMode::Text,
            cursor_x: 0,
            cursor_y: 0,
            foreground_color: VGA_BRIGHT_COLORS[7],
            background_color: VGA_COLORS[0],
        }
    }
}

enum TerminalMode {
    Text,
    Escape1,
    Escape2,
    FirstArgument(u32),
    FirstArgumentEnd(u32),
    SecondArgument([u32; 2]),
    SecondArgumentEnd([u32; 2]),
    ThirdArgument([u32; 3]),
    ThirdArgumentEnd([u32; 3]),
    FourthArgument([u32; 4]),
    FourthArgumentEnd([u32; 4]),
    FifthArgument([u32; 5]),
}

pub static TERMINAL: Mutex<Option<Terminal<'static>>> = Mutex::new(None);

pub struct Terminal<'a> {
    pub font: psf::Font<'a>,
    pub width: u16,
    pub height: u16,
    front_buffer: Vec<ScreenChar>,
    back_buffer: Vec<ScreenChar>,
    current_state: TerminalState,
}

impl<'a> Terminal<'a> {
    pub fn new(font: psf::Font<'a>) -> Result<Self, TryReserveError> {
        let framebuffer_lock = FRAMEBUFFER.lock();
        let framebuffer = framebuffer_lock.as_ref().unwrap();
        let width = (framebuffer.width / font.header.width) as u16;
        let height = (framebuffer.height / font.header.height) as u16;
        let buffer_len = width as usize * height as usize;
        let mut front_buffer = Vec::new();
        let mut back_buffer = Vec::new();
        front_buffer.try_reserve_exact(buffer_len)?;
        back_buffer.try_reserve_exact(buffer_len)?;
        for _ in 0..buffer_len {
            front_buffer.push(ScreenChar::default());
            back_buffer.push(ScreenChar::default());
        }
        Ok(Self {
            font,
            width,
            height,
            front_buffer,
            back_buffer,
            current_state: TerminalState::default(),
        })
    }

    pub fn render(&mut self) {
        let mut framebuffer_lock = FRAMEBUFFER.lock();
        let framebuffer = framebuffer_lock.as_mut().unwrap();
        for (i, screen_char) in self.front_buffer.iter().enumerate() {
            let old_screen_char = self.back_buffer[i];
            if *screen_char != old_screen_char {
                let y_pos = (i / self.width as usize) as u32;
                let x_pos = (i % self.width as usize) as u32;
                if screen_char.character == ' ' {
                    framebuffer.fill_box(
                        (
                            x_pos * self.font.header.width,
                            y_pos * self.font.header.height,
                        ),
                        (self.font.header.width, self.font.header.height),
                        screen_char.background_color,
                    );
                } else {
                    let char_bitmap = self.font.get_character(screen_char.character);
                    for line_i in 0..self.font.header.height {
                        let mut line = char_bitmap[line_i as usize];
                        for bit in 0..8 {
                            line >>= 1;
                            // Branchless code to calculate whether to use the background or
                            // foreground color
                            let mask = (line & 1) as u32;
                            let foreground = mask * screen_char.foreground_color;
                            let background = (1 - mask) * screen_char.background_color;
                            let color = foreground | background;
                            framebuffer.set(
                                (
                                    x_pos * self.font.header.width + (7 - bit),
                                    y_pos * self.font.header.height + line_i,
                                ),
                                color,
                            );
                        }
                    }
                }
                self.back_buffer[i] = *screen_char;
            }
        }
    }

    pub fn reset(&mut self) {
        FRAMEBUFFER.lock().as_mut().unwrap().clear();
        self.current_state = Default::default();
        self.front_buffer.as_mut_slice().fill(Default::default());
        self.back_buffer.as_mut_slice().fill(Default::default());
    }

    pub fn reset_attributes(&mut self) {
        self.current_state.background_color = VGA_COLORS[0];
        self.current_state.foreground_color = VGA_BRIGHT_COLORS[7];
    }

    pub fn new_line(&mut self) {
        let cursor_y = &mut self.current_state.cursor_y;
        *cursor_y += 1;
        // Check if scrolling is required
        if *cursor_y >= self.height {
            let buffer_size = self.front_buffer.len();
            *cursor_y = self.height - 1;
            // Scroll display
            self.front_buffer
                .copy_within(self.width as usize..buffer_size, 0);
            // Clear bottom
            self.front_buffer[buffer_size - self.width as usize..].fill(Default::default());
        }
        // Render after every line printed (current preference)
        self.render();
    }

    pub fn write(&mut self, text: &str) {
        for character in text.chars() {
            match self.current_state.mode {
                TerminalMode::Text => match character {
                    '\x1B' => self.current_state.mode = TerminalMode::Escape1,
                    '\n' => {
                        self.new_line();
                        self.current_state.cursor_x = 0;
                    }
                    '\r' => self.current_state.cursor_x = 0,
                    '\t' => self.current_state.cursor_x = (self.current_state.cursor_x % 8 + 1) * 8,
                    character => {
                        let i =
                            self.current_state.cursor_y * self.width + self.current_state.cursor_x;
                        self.front_buffer[i as usize] = ScreenChar {
                            character,
                            foreground_color: self.current_state.foreground_color,
                            background_color: self.current_state.background_color,
                        };
                        self.current_state.cursor_x += 1;
                        if self.current_state.cursor_x >= self.width {
                            self.current_state.cursor_x -= 1;
                            self.new_line();
                            self.current_state.cursor_x = 0;
                        }
                    }
                },
                TerminalMode::Escape1 => {
                    self.current_state.mode = match character {
                        '[' => TerminalMode::Escape2,
                        _ => TerminalMode::Text,
                    }
                }
                TerminalMode::Escape2 => {
                    self.current_state.mode = match character {
                        '0'..='9' => TerminalMode::FirstArgument(character as u32 - 48),
                        ';' => TerminalMode::FirstArgumentEnd(0),
                        'm' => {
                            self.reset_attributes();
                            TerminalMode::Text
                        }
                        _ => TerminalMode::Text,
                    }
                }
                TerminalMode::FirstArgument(arg) => {
                    self.current_state.mode = match character {
                        '0'..='9' => TerminalMode::FirstArgument(arg * 10 + character as u32 - 48),
                        ';' => TerminalMode::FirstArgumentEnd(arg),
                        'm' => {
                            match arg {
                                0 => self.reset_attributes(),
                                30..=37 => {
                                    self.current_state.foreground_color =
                                        VGA_COLORS[arg as usize - 30]
                                }
                                40..=47 => {
                                    self.current_state.background_color =
                                        VGA_COLORS[arg as usize - 40]
                                }
                                _ => {}
                            }
                            TerminalMode::Text
                        }
                        _ => TerminalMode::Text,
                    }
                }
                TerminalMode::FirstArgumentEnd(arg) => {
                    self.current_state.mode = match character {
                        '0'..='9' => TerminalMode::SecondArgument([arg, character as u32 - 48]),
                        ';' => TerminalMode::SecondArgumentEnd([arg, 0]),
                        _ => TerminalMode::Text,
                    }
                }
                TerminalMode::SecondArgument(args @ [arg1, arg2]) => {
                    self.current_state.mode = match character {
                        '0'..='9' => {
                            TerminalMode::SecondArgument([arg1, arg2 * 10 + character as u32 - 48])
                        }
                        ';' => TerminalMode::SecondArgumentEnd(args),
                        _ => TerminalMode::Text,
                    }
                }
                TerminalMode::SecondArgumentEnd([arg1, arg2]) => {
                    self.current_state.mode = match character {
                        '0'..='9' => {
                            TerminalMode::ThirdArgument([arg1, arg2, character as u32 - 48])
                        }
                        ';' => TerminalMode::ThirdArgumentEnd([arg1, arg2, 0]),
                        _ => TerminalMode::Text,
                    }
                }
                TerminalMode::ThirdArgument(args @ [arg1, arg2, arg3]) => {
                    self.current_state.mode = match character {
                        '0'..='9' => TerminalMode::ThirdArgument([
                            arg1,
                            arg2,
                            arg3 * 10 + character as u32 - 48,
                        ]),
                        ';' => TerminalMode::ThirdArgumentEnd(args),
                        'm' => {
                            if (arg1 != 38 && arg1 != 48) || arg2 != 5 {
                                self.current_state.mode = TerminalMode::Text;
                                continue;
                            }
                            let color = match arg1 {
                                38 => &mut self.current_state.foreground_color,
                                48 => &mut self.current_state.background_color,
                                _ => unreachable!(),
                            };
                            *color = match arg3 {
                                0..=7 => VGA_COLORS[arg3 as usize],
                                8..=15 => VGA_BRIGHT_COLORS[arg3 as usize - 8],
                                16..=231 => {
                                    let cube_index = (arg3 - 16) as u8 as u32;
                                    let r_index = cube_index / 36;
                                    let g_index = (cube_index % 36) / 6;
                                    let b_index = cube_index % 6;
                                    let scale_factor = 255 / 5;
                                    let r = (r_index * scale_factor) << 16;
                                    let g = (g_index * scale_factor) << 8;
                                    let b = b_index * scale_factor;
                                    r | g | b
                                }
                                232..=255 => {
                                    let grey = (0xFF * arg3 - 232) / 23;
                                    let r = grey << 16;
                                    let g = grey << 8;
                                    let b = grey;
                                    r | g | b
                                }
                                _ => {
                                    self.current_state.mode = TerminalMode::Text;
                                    continue;
                                }
                            };
                            TerminalMode::Text
                        }
                        _ => TerminalMode::Text,
                    }
                }
                TerminalMode::ThirdArgumentEnd([arg1, arg2, arg3]) => {
                    self.current_state.mode = match character {
                        '0'..='9' => {
                            TerminalMode::FourthArgument([arg1, arg2, arg3, character as u32 - 48])
                        }
                        ';' => TerminalMode::FourthArgumentEnd([arg1, arg2, arg3, 0]),
                        _ => TerminalMode::Text,
                    }
                }
                TerminalMode::FourthArgument(args @ [arg1, arg2, arg3, arg4]) => {
                    self.current_state.mode = match character {
                        '0'..='9' => TerminalMode::FourthArgument([
                            arg1,
                            arg2,
                            arg3,
                            arg4 * 10 + character as u32 - 48,
                        ]),
                        ';' => TerminalMode::FourthArgumentEnd(args),
                        _ => TerminalMode::Text,
                    }
                }
                TerminalMode::FourthArgumentEnd([arg1, arg2, arg3, arg4]) => {
                    self.current_state.mode = match character {
                        '0'..='9' => TerminalMode::FifthArgument([
                            arg1,
                            arg2,
                            arg3,
                            arg4,
                            character as u32 - 48,
                        ]),
                        _ => TerminalMode::Text,
                    }
                }
                TerminalMode::FifthArgument([arg1, arg2, arg3, arg4, arg5]) => {
                    self.current_state.mode = match character {
                        '0'..='9' => TerminalMode::FifthArgument([
                            arg1,
                            arg2,
                            arg3,
                            arg4,
                            arg5 * 10 + character as u32 - 48,
                        ]),
                        'm' => {
                            if (arg1 != 38 && arg1 != 48) || arg2 != 2 {
                                self.current_state.mode = TerminalMode::Text;
                                continue;
                            }
                            let r = (arg3 & 0xFF) << 16;
                            let g = (arg4 & 0xFF) << 8;
                            let b = arg5 & 0xFF;
                            let color = r | g | b;
                            match arg1 {
                                38 => self.current_state.foreground_color = color,
                                48 => self.current_state.background_color = color,
                                _ => unreachable!(),
                            }
                            TerminalMode::Text
                        }
                        _ => TerminalMode::Text,
                    }
                }
            }
        }
    }
}

impl<'a> core::fmt::Write for Terminal<'a> {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        self.write(s);
        Ok(())
    }
}
