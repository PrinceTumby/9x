const std = @import("std");
const common = @import("common.zig");

pub const Writer = struct {
    var write_buffer: [256]u8 = undefined;

    pub const Error = error {};

    pub fn tryInit(self: Writer) bool {
        return common.port.readByte(0xE9) == 0xE9;
    }

    inline fn writeByteOut(byte: u8) void {
        asm volatile ("outb %[byte], $0xE9" :: [byte] "{al}" (byte));
    }

    pub fn writeAll(self: Writer, bytes: []const u8) Error!void {
        for (bytes) |byte| {
            try self.writeByte(byte);
        }
    }

    pub inline fn writeByte(self: Writer, byte: u8) Error!void {
        if (byte == '\n') writeByteOut('\r');
        writeByteOut(byte);
    }

    pub fn writeByteNTimes(self: Writer, byte: u8, n: usize) Error!void {
        std.mem.set(u8, write_buffer[0..], byte);

        var remaining: usize = n;
        while (remaining > 0) {
            const to_write = std.math.min(remaining, write_buffer.len);
            try self.writeAll(write_buffer[0..to_write]);
            remaining -= to_write;
        }
    }
};
