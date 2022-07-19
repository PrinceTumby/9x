const std = @import("std");

pub fn Writer(comptime port: type) type {
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
