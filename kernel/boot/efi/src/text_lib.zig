// Functions and data structures to use PSF fonts and draw characters onto screen

const std = @import("std");

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

fn Stack(comptime ItemType: type) type {
    return struct {
        array: []ItemType,
        top: usize,

        const Self = @This();

        pub fn new(backing_array: []ItemType) Self {
            return Self{
                .array = backing_array,
                .top = 0,
            };
        }

        pub fn push(self: *Self, item: ItemType) void {
            if (self.top >= self.array.len) {
                @panic("stack array overflow");
            }
            self.array[self.top] = item;
            self.top += 1;
        }

        pub fn pop(self: *Self) ?ItemType {
            if (self.top == 0) {
                return null;
            } else {
                defer self.top -= 1;
                return self.array[self.top];
            }
        }

        pub fn clear(self: *Self) void {
            self.top = 0;
        }

        pub fn getSlice(self: *const Self) []ItemType {
            return self.array[0..self.top];
        }
    };
}

pub fn TextDisplay(comptime FrameBuffer: type) type {
    return struct {
        framebuffer: *FrameBuffer,
        font: Font,
        width: u16,
        height: u16,
        cursor_x: u16,
        cursor_y: u16,

        const Self = @This();

        pub fn init(fb: *FrameBuffer, font: Font) Self {
            return Self{
                .framebuffer = fb,
                .font = font,
                .width = @truncate(u16, fb.width / font.width),
                .height = @truncate(u16, fb.height / font.height),
                .cursor_x = 0,
                .cursor_y = 0,
            };
        }

        pub fn newLine(self: *Self) void {
            self.cursor_x = 0;
            self.cursor_y += 1;
            // Check if scrolling is required
            if (self.cursor_y >= self.height) {
                self.cursor_y = self.height - 1;
                // Scroll framebuffer
                self.framebuffer.copy(
                    0,
                    self.font.height,
                    self.framebuffer.width - 1,
                    self.framebuffer.height - 1 - self.font.height,
                    0,
                    0,
                );
                // Clear bottom
                self.framebuffer.fill(
                    0,
                    self.framebuffer.height - self.font.height,
                    self.framebuffer.width - 1,
                    self.framebuffer.height - 1,
                    0x000000,
                );
            }
        }

        pub fn setPos(self: *Self, x: u16, y: u16) void {
            if (x >= self.width) {
                self.cursor_x = self.height - 1;
            } else {
                self.cursor_x = x;
            }
            if (y >= self.height) {
                self.cursor_y = self.height - 1;
            } else {
                self.cursor_y = y;
            }
        }

        // TODO Rewrite to support UTF-8
        // TODO Handle colour
        pub fn write(self: *Self, text: []const u8) void {
            for (text) |char| {
                switch (char) {
                    '\n' => self.newLine(),
                    ' ' => {
                        self.framebuffer.fill(
                            self.cursor_x * self.font.width,
                            self.cursor_y * self.font.height,
                            (self.cursor_x + 1) * self.font.width - 1,
                            (self.cursor_y + 1) * self.font.height - 1,
                            0x000000,
                        );
                        self.cursor_x += 1;
                        if (self.cursor_x >= self.width) {
                            self.newLine();
                        }
                    },
                    // TODO Handle different font sizes
                    else => {
                        const char_bitmap = self.font.getCharacter(char);
                        var line_i: u8 = 0;
                        while (line_i < self.font.height) : (line_i += 1) {
                            var line = char_bitmap[line_i];
                            const char_base_x = self.cursor_x * self.font.width;
                            const char_base_y = self.cursor_y * self.font.height;
                            comptime var bit: u8 = 0;
                            inline while (bit < 8) : (bit += 1) {
                                line >>= 1;
                                if (self.cursor_x * self.font.width + (7 - bit) > self.framebuffer.width - 1 or
                                    self.cursor_y * self.font.height + line_i > self.framebuffer.height - 1) {
                                    @panic("writing failure");
                                }
                                self.framebuffer.set(
                                    self.cursor_x * self.font.width + (7 - bit),
                                    self.cursor_y * self.font.height + line_i,
                                    @as(u32, line & 1) * 0xFFFFFF,
                                );
                            }
                        }
                        self.cursor_x += 1;
                        if (self.cursor_x >= self.width) {
                            self.newLine();
                        }
                    },
                }
            }
        }
        
        pub fn writeLn(self: *Self, text: []const u8) void {
            self.write(text);
            self.newLine();
        }
    };
}
