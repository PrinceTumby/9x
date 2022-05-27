//! Standard Zig logging function support

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const smp = root.smp;
const arch = root.arch;
const Framebuffer = root.Framebuffer;
const text_lib = root.text_lib;
const BoundedArray = root.zig_extensions.BoundedArray;
// const fmt = @import("fmt.zig");
const fmt = std.fmt;
const serial = arch.serial;

pub fn SerialWriter(comptime port: type) type {
    return struct {
        var write_buffer: [256]u8 = undefined;

        const Self = @This();

        pub const Error = error {};

        pub fn tryInit() ?Self {
            return if (port.init()) Self{} else null;
        }

        pub fn writeAll(self: Self, bytes: []const u8) Error!void {
            for (bytes) |byte| {
                if (byte == '\n') port.writeByte('\r');
                port.writeByte(byte);
            }
        }

        pub fn writeByte(self: Self, byte: u8) Error!void {
            if (byte == '\n') port.writeByte('\r');
            port.writeByte(byte);
        }

        pub fn writeByteNTimes(self: Self, byte: u8, n: usize) Error!void {
            std.mem.set(u8, write_buffer[0..], byte);

            var remaining: usize = n;
            while (remaining > 0) {
                const to_write = std.math.min(remaining, write_buffer.len);
                try self.writeAll(write_buffer[0..to_write]);
                remaining -= to_write;
            }
        }
    };
}

pub const BochsWriter = struct {
    var write_buffer: [256]u8 = undefined;

    pub const Error = error {};

    inline fn writeByteOut(byte: u8) void {
        asm volatile ("outb %[byte], $0xE9" :: [byte] "{al}" (byte));
    }

    pub fn writeAll(self: BochsWriter, bytes: []const u8) Error!void {
        for (bytes) |byte| {
            try self.writeByte(byte);
        }
    }

    pub inline fn writeByte(self: BochsWriter, byte: u8) Error!void {
        if (byte == '\n') writeByteOut('\r');
        writeByteOut(byte);
    }

    pub fn writeByteNTimes(self: BochsWriter, byte: u8, n: usize) Error!void {
        std.mem.set(u8, write_buffer[0..], byte);

        var remaining: usize = n;
        while (remaining > 0) {
            const to_write = std.math.min(remaining, write_buffer.len);
            try self.writeAll(write_buffer[0..to_write]);
            remaining -= to_write;
        }
    }
};

const ScreenWriter = struct {
    text_display: *text_lib.TextDisplay(Framebuffer),

    const Self = @This();

    pub const Error = error {};

    pub fn writeAll(self: Self, bytes: []const u8) Error!void {
        self.text_display.write(bytes, null);
    }

    pub fn writeByte(self: Self, byte: u8) Error!void {
        const char = [1]u8{byte};
        self.text_display.write(&char, null);
    }

    pub fn writeByteNTimes(self: Self, byte: u8, n: usize) Error!void {
        var write_buffer: [256]u8 = undefined;
        std.mem.set(u8, write_buffer[0..], byte);

        const lock = self.text_display.lock.acquire();
        defer lock.release();
        var remaining: usize = n;
        while (remaining > 0) {
            const to_write = std.math.min(remaining, write_buffer.len);
            self.text_display.write(write_buffer[0..to_write], lock);
            remaining -= to_write;
        }
    }
};

pub const LogWriter = struct {
    var write_buffer: [256]u8 = undefined;

    pub const Error = error {};

    pub fn writeAll(self: LogWriter, bytes: []const u8) Error!void {
        logRaw("{s}", .{bytes});
    }

    pub fn writeByte(self: LogWriter, byte: u8) Error!void {
        logRaw("{c}", .{byte});
    }
    
    pub fn writeByteNTimes(self: LogWriter, byte: u8, n: usize) Error!void {
        std.mem.set(u8, write_buffer[0..], byte);

        var remaining: usize = n;
        while (remaining > 0) {
            const to_write = std.math.min(remaining, write_buffer.len);
            try self.writeAll(write_buffer[0..to_write]);
            remaining -= to_write;
        }
    }
};

pub const AbstractWriter = struct {
    writer_pointer: *c_void,
    writeAllFunc: fn(self: *c_void, bytes: []const u8) Error!void,
    writeByteFunc: fn(self: *c_void, byte: u8) Error!void,
    writeByteNTimesFunc: fn(self: *c_void, byte: u8, n: usize) Error!void,

    pub const Error = error {};

    pub inline fn writeAll(self: AbstractWriter, bytes: []const u8) Error!void {
        try self.writeAllFunc(self.writer_pointer, bytes);
    }

    pub inline fn writeByte(self: AbstractWriter, byte: u8) Error!void {
        try self.writeByteFunc(self.writer_pointer, byte);
    }

    pub inline fn writeByteNTimes(self: AbstractWriter, byte: u8, n: usize) Error!void {
        try self.writeByteNTimesFunc(self.writer_pointer, byte, n);
    }
};

pub const log_writer: LogWriter = .{};

pub var com1_writer: ?SerialWriter(serial.Com1) = null;
pub var com2_writer: ?SerialWriter(serial.Com2) = null;
pub var com3_writer: ?SerialWriter(serial.Com3) = null;
pub var com4_writer: ?SerialWriter(serial.Com4) = null;
pub var bochs_writer: ?BochsWriter = null;
// pub const bochs_writer: ?BochsWriter = null;
pub var abstract_writers = BoundedArray(AbstractWriter, 8){};
pub var screen_writer: ?ScreenWriter = null;
pub var writer_lock = smp.SpinLock.init();

pub fn tryEnableSerialWriters() void {
    com1_writer = SerialWriter(serial.Com1).tryInit();
    com2_writer = SerialWriter(serial.Com2).tryInit();
    com3_writer = SerialWriter(serial.Com3).tryInit();
    com4_writer = SerialWriter(serial.Com4).tryInit();
}

pub fn enableTextDisplayLogger(screen: *text_lib.TextDisplay(Framebuffer)) void {
    screen_writer = .{.text_display = screen};
}

pub fn removeLogDevice() void {
    screen_writer = null;
}

pub fn logRawLn(comptime format: []const u8, args: anytype) void {
    const lock = writer_lock.acquire();
    defer lock.release();
    if (bochs_writer) |writer| {
        fmt.format(writer, format ++ "\n", args) catch {};
    }
    if (com1_writer) |writer| {
        fmt.format(writer, format ++ "\n", args) catch {};
    }
    if (screen_writer) |writer| {
        fmt.format(writer, format ++ "\n", args) catch {};
    }
    for (abstract_writers.constSlice()) |writer| {
        fmt.format(writer, format ++ "\n", args) catch {};
    }
}

pub fn logRaw(comptime format: []const u8, args: anytype) void {
    const lock = writer_lock.acquire();
    defer lock.release();
    if (bochs_writer) |writer| {
        fmt.format(writer, format, args) catch {};
    }
    if (com1_writer) |writer| {
        fmt.format(writer, format, args) catch {};
    }
    if (screen_writer) |writer| {
        fmt.format(writer, format, args) catch {};
    }
    for (abstract_writers.constSlice()) |writer| {
        fmt.format(writer, format, args) catch {};
    }
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const lock = writer_lock.acquire();
    defer lock.release();
    const prefix = "[" ++ @tagName(level) ++ "] (" ++ @tagName(scope) ++ "): ";
    if (bochs_writer) |writer| {
        fmt.format(writer, prefix ++ format ++ "\n", args) catch {};
    }
    if (com1_writer) |writer| {
        fmt.format(writer, prefix ++ format ++ "\n", args) catch {};
    }
    if (screen_writer) |writer| {
        fmt.format(writer, prefix ++ format ++ "\n", args) catch {};
    }
    for (abstract_writers.constSlice()) |writer| {
        fmt.format(writer, prefix ++ format ++ "\n", args) catch {};
    }
}

pub fn logNoNewline(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const lock = writer_lock.acquire();
    defer lock.release();
    const prefix = "[" ++ @tagName(level) ++ "] (" ++ @tagName(scope) ++ "): ";
    if (bochs_writer) |writer| {
        fmt.format(writer, prefix ++ format, args) catch {};
    }
    if (com1_writer) |writer| {
        fmt.format(writer, prefix ++ format, args) catch {};
    }
    if (screen_writer) |writer| {
        fmt.format(writer, prefix ++ format, args) catch {};
    }
    for (abstract_writers.constSlice()) |writer| {
        fmt.format(writer, prefix ++ format, args) catch {};
    }
}

// HACK: The {s} format specifier currently doesn't work, so this is a workaround

pub fn logString(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime prefix_string: []const u8,
    string: []const u8,
) void {
    if (@enumToInt(level) > @enumToInt(std.log.level)) return;
    const lock = writer_lock.acquire();
    defer lock.release();
    const prefix = "[" ++ @tagName(level) ++ "] (" ++ @tagName(scope) ++ "): ";
    if (bochs_writer) |writer| {
        writer.writeAll(prefix ++ prefix_string) catch return;
        writer.writeAll(string) catch return;
        writer.writeByte('\n') catch return;
    }
    if (com1_writer) |writer| {
        writer.writeAll(prefix ++ prefix_string) catch return;
        writer.writeAll(string) catch return;
        writer.writeByte('\n') catch return;
    }
    if (screen_writer) |writer| {
        writer.writeAll(prefix ++ prefix_string) catch return;
        writer.writeAll(string) catch return;
        writer.writeByte('\n') catch return;
    }
    for (abstract_writers.constSlice()) |writer| {
        writer.writeAll(prefix ++ prefix_string) catch return;
        writer.writeAll(string) catch return;
        writer.writeByte('\n') catch return;
    }
}
