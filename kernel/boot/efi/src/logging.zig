const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const root = @import("root");
const Framebuffer = root.Framebuffer;
const text_lib = root.text_lib;

const ConsoleWriter = struct {
    console: *uefi.protocols.SimpleTextOutputProtocol,

    const Self = @This();

    pub const Error = error {};

    pub fn writeAll(self: Self, bytes: []const u8) Error!void {
        var iterator = std.unicode.Utf8Iterator{
            .bytes = bytes,
            .i = 0,
        };
        while (iterator.nextCodepoint()) |codepoint| {
            const mini_string = if (codepoint > 0xFFFF)
                [2]u16{0xFFFD, 0} // Unicode replacement character
            else
                [2]u16{@truncate(u16, codepoint), 0};
            if (codepoint == '\n') {
                const carriage_return = [1:0]u16{'\r'};
                _ = self.console.outputString(&carriage_return);
            }
            _ = self.console.outputString(@ptrCast(*const [1:0]u16, &mini_string));
        }
    }

    pub fn writeByte(self: Self, byte: u8) !void {
        const array = [1]u8{byte};
        return self.writeAll(&array);
    }

    pub fn writeByteNTimes(self: Self, byte: u8, n: usize) Error!void {
        var bytes: [256]u8 = undefined;
        std.mem.set(u8, bytes[0..], byte);

        var remaining: usize = n;
        while (remaining > 0) {
            const to_write = std.math.min(remaining, bytes.len);
            try self.writeAll(bytes[0..to_write]);
            remaining -= to_write;
        }
    }
};

const SerialWriter = struct {
    pub const port: u16 = 0x3f8;
    pub const data: u16 = port;
    pub const line_status_reg: u16 = port + 5;

    const Self = @This();

    pub const Error = error {};

    pub fn writeAll(self: Self, bytes: []const u8) Error!void {
        for (bytes) |byte| {
            try self.writeByte(byte);
        }
    }

    pub fn writeByte(self: Self, byte: u8) Error!void {
        // Wait until serial port ready
        while (asm volatile ("inb %%dx, %[out]"
                : [out] "={al}" (-> u8)
                : [line_status_reg] "{dx}" (line_status_reg)
        ) & 0x20 == 0) {}

        if (byte == '\n') {
            try self.writeByte('\r');
        }

        // Send byte
        asm volatile ("outb %[byte], %%dx" :: [byte] "{al}" (byte), [data] "{dx}" (data));
    }

    pub fn writeByteNTimes(self: Self, byte: u8, n: usize) Error!void {
        var bytes: [256]u8 = undefined;
        std.mem.set(u8, bytes[0..], byte);

        var remaining: usize = n;
        while (remaining > 0) {
            const to_write = std.math.min(remaining, bytes.len);
            try self.writeAll(bytes[0..to_write]);
            remaining -= to_write;
        }
    }
};

const ScreenWriter = struct {
    text_display: *text_lib.TextDisplay(Framebuffer),

    const Self = @This();

    pub const Error = error {};

    pub fn writeAll(self: Self, bytes: []const u8) Error!void {
        self.text_display.write(bytes);
    }

    pub fn writeByte(self: Self, byte: u8) Error!void {
        const char = [1]u8{byte};
        self.text_display.write(&byte);
    }

    pub fn writeByteNTimes(self: Self, byte: u8, n: usize) Error!void {
        var bytes: [256]u8 = undefined;
        std.mem.set(u8, bytes[0..], byte);

        var remaining: usize = n;
        while (remaining > 0) {
            const to_write = std.math.min(remaining, bytes.len);
            try self.writeAll(bytes[0..to_write]);
            remaining -= to_write;
        }
    }
};

var con_writer_maybe: ?ConsoleWriter = null;
var screen_writer_maybe: ?ScreenWriter = null;
var serial_writer: SerialWriter = .{};

pub fn setScreenLogger(text_display: *text_lib.TextDisplay(Framebuffer)) void {
    screen_writer_maybe = .{.text_display = text_display};
}

pub fn setLogDevice(device: *uefi.protocols.SimpleTextOutputProtocol) void {
    con_writer_maybe = .{.console = device};
}

pub fn removeLogDevice() void {
    con_writer_maybe = null;
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ @tagName(level) ++ "] (" ++ @tagName(scope) ++ "): ";
    if (con_writer_maybe) |writer| {
        std.fmt.format(writer, prefix ++ format ++ "\n", args) catch return;
    } else {
        std.fmt.format(serial_writer, prefix ++ format ++ "\n", args) catch return;
        if (screen_writer_maybe) |writer| {
            std.fmt.format(writer, prefix ++ format ++ "\n", args) catch return;
        }
    }
}
