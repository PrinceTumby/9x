const std = @import("std");

pub fn assertEqual(comptime left: anytype, comptime right: anytype) void {
    comptime {
        if (left != right) {
            var buf: [4096]u8 = undefined;
            const message = std.fmt.bufPrint(
                &buf,
                "Equal assertion failed: Left = {}, Right = {}",
                .{left, right}
            ) catch unreachable;
            // @compileLog(message);
            @compileError(message);
            // @compileLog("Equal assertion failed: Left = ", left, ", Right = ", right);
        }
    }
}
