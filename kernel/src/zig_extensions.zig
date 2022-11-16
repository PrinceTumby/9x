// TODO Turn this into a seperate package
pub const Interface = @import("zig_extensions/Interface.zig");
pub const overridable_properties = @import("zig_extensions/overridable_properties.zig");

const std = @import("std");

pub fn range(len: usize) []const void {
    return @as([*]void, undefined)[0..len];
}

pub fn comptimeFmt(
    comptime buf_extra_len: usize,
    comptime fmt: []const u8,
    comptime args: anytype,
) []const u8 {
    var buf: [fmt.len + buf_extra_len]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buf,
        fmt,
        args,
    ) catch @compileError("Provided buffer size too small");
    return message;
}

pub fn compileErrorFmt(comptime fmt: []const u8, comptime args: anytype) void {
    comptime {
        var buf: [4096]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buf,
            fmt,
            args,
        ) catch unreachable;
        @compileError(message);
    }
}

pub fn asmSymbolFmt(comptime name: []const u8, comptime value: usize) []const u8 {
    var value_text_buffer: [32]u8 = undefined;
    const buffer_used = std.fmt.formatIntBuf(&value_text_buffer, value, 10, false, .{});
    return ".global " ++
        name ++
        "\n" ++
        name ++
        " = " ++
        value_text_buffer[0..buffer_used];
}

pub fn BoundedArray(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        buffer: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub const Error = error{OutOfSpace};

        pub fn append(self: *Self, item: T) Error!void {
            if (self.len >= capacity) return error.OutOfSpace;

            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub inline fn capacity(self: Self) usize {
            return capacity;
        }

        pub fn get(self: *const Self, i: usize) T {
            return self.buffer[i];
        }

        pub fn set(self: *Self, i: usize, item: T) void {
            self.buffer[i] = item;
        }

        pub fn orderedRemove(self: *Self, i: usize) T {
            const item = self.buffer[i];
            if (i + 1 < self.len) {
                for (self.buffer[i + 1 .. len]) |*move_item, move_i| {
                    self.buffer[move_i] = move_item.*;
                }
            }
            self.len -= 1;
            return item;
        }

        pub fn constSlice(self: *const Self) []const T {
            return @ptrCast([*]const T, &self.buffer)[0..self.len];
        }

        pub fn slice(self: *Self) []T {
            return self.buffer[0..self.len];
        }
    };
}
