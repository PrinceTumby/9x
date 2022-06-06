const std = @import("std");

const logger = std.log.scoped(.main);

fn debugKernelPrint(message: []const u8) void {
    asm volatile ("syscall"
        :
        : [syscall] "{rax}" (@as(u64, 1)),
          [message_ptr] "{rdi}" (@ptrToInt(message.ptr)),
          [message_len] "{rsi}" (message.len)
        : "rax"
    );
}

fn getPidSyscall() usize {
    return asm ("syscall"
        : [out] "={rax}" (-> usize)
        : [syscall] "{rax}" (@as(u64, 0))
    );
}

const KernelDebugWriter = struct {
    var write_buffer: [256]u8 = undefined;

    pub const Error = error {};

    pub fn writeAll(self: KernelDebugWriter, bytes: []const u8) Error!void {
        debugKernelPrint(bytes);
    }

    pub fn writeByte(self: KernelDebugWriter, byte: u8) Error!void {
        const char = [1]u8{byte};
        debugKernelPrint(&char);
    }

    pub fn writeByteNTimes(self: KernelDebugWriter, byte: u8, n: usize) Error!void {
        std.mem.set(u8, write_buffer[0..], byte);

        var remaining: usize = n;
        while (remaining > 0) {
            const to_write = std.math.min(remaining, write_buffer.len);
            debugKernelPrint(write_buffer[0..to_write]);
            remaining -= to_write;
        }
    }
};

const kernel_debug_writer = KernelDebugWriter{};

pub const log_level: std.log.Level = .debug;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ @tagName(level) ++ "] (" ++ @tagName(scope) ++ "): ";
    std.fmt.format(kernel_debug_writer, prefix ++ format ++ "\n", args) catch {};
}

export fn _start() void {
    logger.debug("Hello from usermode Zig!", .{});
    logger.debug("This is process {}", .{getPidSyscall()});
    // var stack_buffer: [4080]u8 = undefined;
    // for (@ptrCast([*]volatile u8, &stack_buffer)[0..stack_buffer.len]) |*byte| {
    //     byte.* = 0;
    // }
    while (true) {}
}

pub fn panic(message: []const u8, trace_maybe: ?*std.builtin.StackTrace) noreturn {
    debugKernelPrint(message);
    while (true) {}
}
