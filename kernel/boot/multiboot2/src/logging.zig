//! Standard Zig logging function support

const std = @import("std");
const fmt = std.fmt;
const serial = @import("serial.zig");

pub const BochsWriter = struct {
    var write_buffer: [256]u8 = undefined;

    pub const Error = error {};

    fn writeByteToPort(byte: u8) void {
        asm volatile ("outb %[byte], $0xE9" :: [byte] "{al}" (byte));
    }

    pub fn writeAll(self: BochsWriter, bytes: []const u8) Error!void {
        for (bytes) |byte| {
            if (byte == '\n') writeByteToPort('\r');
            writeByteToPort(byte);
        }
    }

    pub fn writeByte(self: BochsWriter, byte: u8) Error!void {
        if (byte == '\n') writeByteToPort('\r');
        writeByteToPort(byte);
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

pub fn SerialWriter(comptime port: type) type {
    return struct {
        var write_buffer: [256]u8 = undefined;

        const Self = @This();

        pub const Error = error {};

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

pub const log_writer: LogWriter = .{};

// pub const com1_writer: SerialWriter(serial.Com1) = .{};
// pub const com2_writer: SerialWriter(serial.Com2) = .{};
// pub const com3_writer: SerialWriter(serial.Com3) = .{};
pub const com4_writer: SerialWriter(serial.Com4) = .{};
pub const bochs_writer = BochsWriter{};

pub fn logRawLn(comptime format: []const u8, args: anytype) void {
    fmt.format(bochs_writer, format ++ "\n", args) catch {};
}

pub fn logRaw(comptime format: []const u8, args: anytype) void {
    fmt.format(bochs_writer, format, args) catch {};
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ @tagName(level) ++ "] (" ++ @tagName(scope) ++ "): ";
    // fmt.format(bochs_writer, prefix ++ format ++ "\n", args) catch {};
    fmt.format(com4_writer, prefix ++ format ++ "\n", args) catch {};
}

pub fn logNoNewline(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ @tagName(level) ++ "] (" ++ @tagName(scope) ++ "): ";
    fmt.format(bochs_writer, prefix ++ format, args) catch {};
}
