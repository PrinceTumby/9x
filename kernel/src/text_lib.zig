// Functions and data structures to use PSF fonts and draw characters onto screen

const std = @import("std");
const root = @import("root");
const smp = root.smp;
const page_allocator = root.arch.page_allocation.page_allocator_ptr;

const logger = std.log.scoped(.text_lib);

const psf_magic = 0x864ab572;
const psf_version = 0x0;

const blank_char_8_16: [16]u8 = [_]u8 { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

const PSFHeader = packed struct {
    magic: u32 = psf_magic,
    version: u32 = psf_version,
    header_size: u32,
    flags: u32,
    num_glyph: u32,
    bytes_per_glyph: u32,
    height: u32,
    width: u32,
};

pub const Font = struct {
    num_glyph: u32,
    bytes_per_glyph: u32,
    width: u32,
    height: u32,
    font_data: []const u8,

    pub fn init(font_file: []const u8) ?Font {
        const header = @ptrCast(*const PSFHeader, font_file);
        if (header.magic != psf_magic or header.version != psf_version) {
            return null;
        }
        return Font{
            .num_glyph = header.num_glyph,
            .bytes_per_glyph = header.bytes_per_glyph,
            .width = header.width,
            .height = header.height,
            .font_data = font_file[32..font_file.len],
        };
    }

    pub inline fn getCharacter(self: Font, char: u32) []const u8 {
        const index_start: usize = self.bytes_per_glyph * char;
        const index_end: usize = self.bytes_per_glyph * (char + 1);
        if (index_end >= self.font_data.len) {
            return &blank_char_8_16;
        }
        return self.font_data[index_start .. index_end];
    }
};

pub fn TextDisplay(comptime FrameBuffer: type) type {
    return struct {
        lock: smp.SpinLock = smp.SpinLock.init(),
        allocator: std.mem.Allocator,
        font: Font,
        framebuffer: *FrameBuffer,
        text_buffer: []ScreenChar,
        text_buffer_old: []ScreenChar,
        width: u16,
        height: u16,
        current_state: State = .text,
        cursor_x: u16 = 0,
        cursor_y: u16 = 0,
        background_colour: u32 = vga_colours[0],
        foreground_colour: u32 = vga_bright_colours[7],

        const ScreenChar = extern struct {
            char: u32,
            background_colour: u32,
            foreground_colour: u32,

            const blank_char = ScreenChar{
                .char = ' ',
                .background_colour = vga_colours[0],
                .foreground_colour = vga_bright_colours[7],
            };
        };

        const vga_colours = &[8]u32{
            0x000000,
            0xAA0000,
            0x00AA00,
            0xAAAA00,
            0x0000AA,
            0xAA00AA,
            0x00AAAA,
            0xAAAAAA,
        };

        const vga_bright_colours = &[8]u32{
            0x555555,
            0xFF5555,
            0x55FF55,
            0xFFFF55,
            0x5555FF,
            0xFF55FF,
            0x55FFFF,
            0xFFFFFF,
        };

        const State = union(enum) {
            text: void,
            escape_1: void,
            escape_2: void,
            first_argument: usize,
            first_argument_end: usize,
            second_argument: [2]usize,
            second_argument_end: [2]usize,
            third_argument: [3]usize,
            third_argument_end: [3]usize,
            fourth_argument: [4]usize,
            fourth_argument_end: [4]usize,
            fifth_argument: [5]usize,
        };

        const Self = @This();

        pub fn init(fb: *FrameBuffer, font: Font, allocator: std.mem.Allocator) !Self {
            const width = @truncate(u16, fb.width / font.width);
            const height = @truncate(u16, fb.height / font.height);
            const text_buffer_len = @as(usize, width) * @as(usize, height);
            const text_buffer = try allocator.alloc(ScreenChar, text_buffer_len);
            errdefer allocator.free(text_buffer);
            const text_buffer_old = try allocator.alloc(ScreenChar, text_buffer_len);
            for (text_buffer) |*new_char, i| {
                new_char.* = ScreenChar.blank_char;
                text_buffer_old[i] = ScreenChar.blank_char;
            }
            return Self{
                .allocator = allocator,
                .framebuffer = fb,
                .text_buffer = text_buffer,
                .text_buffer_old = text_buffer_old,
                .font = font,
                .width = width,
                .height = height,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.text_buffer);
            self.allocator.free(self.text_buffer_old);
        }

        pub fn render(self: *Self, held: ?smp.SpinLock.Held) void {
            @setRuntimeSafety(false);
            const lock = held orelse self.lock.acquire();
            defer if (held == null) lock.release();
            for (self.text_buffer) |char, i| {
                const old_char = self.text_buffer_old[i];
                if (!std.meta.eql(char, old_char)) {
                    const y_pos = @truncate(u32, i / self.width);
                    const x_pos = @truncate(u32, i % self.width);
                    if (char.char == ' ') {
                        self.framebuffer.drawBox(
                            x_pos * self.font.width,
                            y_pos * self.font.height,
                            self.font.width,
                            self.font.height,
                            char.background_colour,
                        );
                    } else {
                        const char_bitmap = self.font.getCharacter(char.char);
                        var line_i: u8 = 0;
                        while (line_i < self.font.height) : (line_i += 1) {
                            var line = char_bitmap[line_i];
                            comptime var bit: u8 = 0;
                            inline while (bit < 8) : (bit += 1) {
                                line >>= 1;
                                // Branchless code to calculate whether to use the
                                // foreground or background colour
                                const mask = @as(u32, line & 1);
                                const foreground = mask * char.foreground_colour;
                                const background = (1 - mask) * char.background_colour;
                                const colour = foreground + background;
                                self.framebuffer.set(
                                    x_pos * self.font.width + (7 - bit),
                                    y_pos * self.font.height + line_i,
                                    colour,
                                );
                            }
                        }
                    }
                    self.text_buffer_old[i] = char;
                }
            }
            self.framebuffer.buffer_dirty = true;
        }

        pub fn reset(self: *Self, held: ?smp.SpinLock.Held) void {
            @setRuntimeSafety(false);
            const lock = held orelse self.lock.acquire();
            defer if (held == null) lock.release();
            self.cursor_x = 0;
            self.cursor_y = 0;
            self.background_colour = vga_colours[0];
            self.foreground_colour = vga_bright_colours[7];
            for (self.text_buffer) |*new_char, i| {
                new_char.* = ScreenChar.blank_char;
                self.text_buffer_old[i] = ScreenChar.blank_char;
            }
            self.framebuffer.clear();
        }

        pub fn resetAttributes(self: *Self, held: ?smp.SpinLock.Held) void {
            const lock = held orelse self.lock.acquire();
            defer if (held == null) lock.release();
            self.background_colour = vga_colours[0];
            self.foreground_colour = vga_bright_colours[7];
        }

        pub fn newLine(self: *Self, held: ?smp.SpinLock.Held) void {
            const lock = held orelse self.lock.acquire();
            defer if (held == null) lock.release();
            self.cursor_y += 1;
            // Check if scrolling is required
            if (self.cursor_y >= self.height) {
                self.cursor_y = self.height - 1;
                // Scroll display
                var src_pos: usize = self.width;
                var dest_pos: usize = 0;
                while (src_pos < self.text_buffer.len) : ({src_pos += 1; dest_pos += 1;}) {
                    self.text_buffer[dest_pos] = self.text_buffer[src_pos];
                }
                // Clear bottom
                while (dest_pos < self.text_buffer.len) : (dest_pos += 1) {
                    self.text_buffer[dest_pos] = ScreenChar.blank_char;
                }
            }
            self.render(lock);
        }

        pub fn setX(self: *Self, x: u16, held: ?smp.SpinLock.Held) void {
            const lock = held orelse self.lock.acquire();
            defer if (held == null) lock.release();
            if (x >= self.width) {
                self.cursor_x = self.width - 1;
            } else {
                self.cursor_x = x;
            }
        }

        pub fn setY(self: *Self, y: u16, held: ?smp.SpinLock.Held) void {
            const lock = held orelse self.lock.acquire();
            defer if (held == null) lock.release();
            if (y >= self.height) {
                self.cursor_y = self.height - 1;
            } else {
                self.cursor_y = y;
            }
        }

        pub fn setPos(self: *Self, x: u16, y: u16, held: ?smp.SpinLock.Held) void {
            const lock = held orelse self.lock.acquire();
            defer if (held == null) lock.release();
            self.setX(x, lock);
            self.setY(y, lock);
        }

        pub fn write(self: *Self, text: []const u8, held: ?smp.SpinLock.Held) void {
            @setRuntimeSafety(false);
            // Acquire display lock if not passed in
            const lock = held orelse self.lock.acquire();
            defer if (held == null) lock.release();
            // Loop through codepoints
            var char_iter = std.unicode.Utf8Iterator{
                .bytes = text,
                .i = 0,
            };
            while (char_iter.nextCodepoint()) |char| {
                switch (self.current_state) {
                    .text => switch (char) {
                        '\x1B' => self.current_state = .escape_1,
                        '\n' => {self.newLine(lock); self.cursor_x = 0;},
                        '\r' => self.cursor_x = 0,
                        '\t' => self.cursor_x = (self.cursor_x % 8 + 1) * 8,
                        else => {
                            const i = self.cursor_y * self.width + self.cursor_x;
                            self.text_buffer[i] = ScreenChar{
                                .char = char,
                                .foreground_colour = self.foreground_colour,
                                .background_colour = self.background_colour,
                            };
                            self.cursor_x += 1;
                            if (self.cursor_x >= self.width) {
                                self.cursor_x -= 1;
                                self.newLine(lock);
                                self.cursor_x = 0;
                            }
                        },
                    },
                    .escape_1 => switch (char) {
                        '[' => self.current_state = .escape_2,
                        else => self.current_state = .text,
                    },
                    .escape_2 => switch (char) {
                        '0'...'9' => self.current_state = .{.first_argument = char - 48},
                        ';' => self.current_state = .{.first_argument_end = 0},
                        'm' => {self.resetAttributes(lock); self.current_state = .text;},
                        else => self.current_state = .text,
                    },
                    .first_argument => |arg| switch (char) {
                        '0'...'9' => self.current_state =
                            .{.first_argument = arg * 10 + (char - 48)},
                        ';' => self.current_state = .{.first_argument_end = arg},
                        'm' => {
                            switch (arg) {
                                0 => self.resetAttributes(lock),
                                30...37 => {
                                    self.foreground_colour = vga_colours[arg - 30];
                                },
                                40...47 => self.background_colour = vga_colours[arg - 40],
                                else => {},
                            }
                            self.current_state = .text;
                        },
                        else => self.current_state = .text,
                    },
                    .first_argument_end => |arg| switch (char) {
                        '0'...'9' => self.current_state = .{.second_argument = .{arg, char - 48}},
                        ';' => self.current_state = .{.second_argument_end = .{arg, 0}},
                        else => self.current_state = .text,
                    },
                    .second_argument => |args| switch (char) {
                        '0'...'9' => self.current_state =
                            .{.second_argument = .{args[0], args[1] * 10 + (char - 48)}},
                        ';' => self.current_state = .{.second_argument_end = args},
                        else => self.current_state = .text,
                    },
                    .second_argument_end => |args| switch (char) {
                        '0'...'9' => self.current_state =
                            .{.third_argument = .{args[0], args[1], char - 48}},
                        ';' => self.current_state =
                            .{.third_argument_end = .{args[0], args[1], 0}},
                        else => self.current_state = .text,
                    },
                    .third_argument => |args| switch (char) {
                        '0'...'9' => self.current_state =
                            .{.third_argument = .{args[0], args[1], args[2] * 10 + (char - 48)}},
                        ';' => self.current_state = .{.third_argument_end = args},
                        'm' => {
                            if ((args[0] != 38 and args[0] != 48) or args[1] != 5) {
                                self.current_state = .text;
                                continue;
                            }
                            const colour = switch (args[0]) {
                                38 => &self.foreground_colour,
                                48 => &self.background_colour,
                                else => unreachable,
                            };
                            switch (args[2]) {
                                0...7 => colour.* = vga_colours[args[2]],
                                8...15 => colour.* = vga_bright_colours[args[2] - 8],
                                16...231 => {
                                    const cube_index = @truncate(u8, args[2] - 16);
                                    const r_index: u32 = cube_index / 36;
                                    const g_index: u32 = (cube_index % 36) / 6;
                                    const b_index: u32 = cube_index % 6;
                                    const scale_factor = 255 / 5;
                                    const r: u32 = (r_index * scale_factor) << 16;
                                    const g: u32 = (g_index * scale_factor) << 8;
                                    const b: u32 = b_index * scale_factor;
                                    colour.* = r | g | b;
                                },
                                232...255 => {
                                    const grey = (0xFF * @truncate(u32, args[2] - 232)) / 23;
                                    const r = grey << 16;
                                    const g = grey << 8;
                                    const b = grey;
                                    colour.* = r | g | b;
                                },
                                else => {},
                            }
                            self.current_state = .text;
                        },
                        else => self.current_state = .text,
                    },
                    .third_argument_end => |args| switch (char) {
                        '0'...'9' => self.current_state =
                            .{.fourth_argument = .{args[0], args[1], args[2], char - 48}},
                        ';' => self.current_state =
                            .{.fourth_argument_end = .{args[0], args[1], args[2], 0}},
                        else => self.current_state = .text,
                    },
                    .fourth_argument => |args| switch (char) {
                        '0'...'9' => self.current_state = .{.fourth_argument =
                            .{args[0], args[1], args[2], args[3] * 10 + (char - 48)}
                        },
                        ';' => self.current_state = .{.fourth_argument_end = args},
                        else => self.current_state = .text,
                    },
                    .fourth_argument_end => |args| switch (char) {
                        '0'...'9' => self.current_state =
                            .{.fifth_argument = .{args[0], args[1], args[2], args[3], char - 48}},
                        else => self.current_state = .text,
                    },
                    .fifth_argument => |args| switch (char) {
                        '0'...'9' => self.current_state = .{.fifth_argument =
                            .{args[0], args[1], args[2], args[3], args[4] * 10 + (char - 48)}
                        },
                        'm' => {
                            if ((args[0] != 38 and args[0] != 48) or args[1] != 2) {
                                self.current_state = .text;
                                continue;
                            }
                            const r: u32 = (@truncate(u32, args[2]) & 0xFF) << 16;
                            const g: u32 = (@truncate(u32, args[3]) & 0xFF) << 8;
                            const b: u32 = @truncate(u32, args[4]) & 0xFF;
                            const colour: u32 = r | g | b;
                            switch (args[0]) {
                                38 => self.foreground_colour = colour,
                                48 => self.background_colour = colour,
                                else => unreachable,
                            }
                            self.current_state = .text;
                        },
                        else => self.current_state = .text,
                    },
                }
            }
            self.render(lock);
        }
        
        pub fn writeLn(self: *Self, text: []const u8) void {
            const lock = self.lock.acquire();
            defer lock.release();
            self.write(text, lock);
            self.newLine(lock);
        }
    };
}
