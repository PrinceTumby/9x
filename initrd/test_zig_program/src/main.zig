const std = @import("std");
const serial = @import("serial.zig");

const logger = std.log.scoped(.main);

const syscall = struct {
    pub const Error = error {
        UnknownSyscall,
        InvalidArgument,
        OutOfMemory,
        UnknownError,
    };

    fn errorFromNegativeValue(value: usize) Error {
        // logger.debug("Translating {}", .{-%(value +% 1)});
        return switch (@intToEnum(ErrorValue, -%(value +% 1))) {
            .unknown_syscall => Error.UnknownSyscall,
            .invalid_argument => Error.InvalidArgument,
            .out_of_memory => Error.OutOfMemory,
            else => Error.UnknownError,
        };
    }

    pub const ErrorValue = enum(usize) {
        unknown_syscall,
        invalid_argument,
        out_of_memory,
        _,
    };

    pub const Syscall = enum(usize) {
        get_pid,
        yield,
        set_break,
        move_break,
        debug,
    };

    pub fn getPid() usize {
        return asm ("syscall"
            : [out] "={rax}" (-> usize)
            : [syscall] "{rax}" (@enumToInt(Syscall.get_pid))
            : "rcx", "r11"
        );
    }

    pub fn setBreak(new_break_address: usize) !usize {
        const addr_or_err = asm ("syscall"
            : [out] "={rax}" (-> usize)
            : [syscall] "{rax}" (@enumToInt(Syscall.set_break)),
              [new_break_address] "{rdi}" (new_break_address)
            : "rcx", "r11", "memory"
        );
        const isize_return = @bitCast(isize, addr_or_err);
        if (-128 <= isize_return and isize_return <= -1) {
            return errorFromNegativeValue(return_value);
        } else {
            return return_value;
        }
    }

    pub fn moveBreak(move_delta: isize) !usize {
        const addr_or_err = asm ("syscall"
            : [out] "={rax}" (-> usize)
            : [syscall] "{rax}" (@enumToInt(Syscall.move_break)),
              [move_delta] "{rdi}" (move_delta)
            : "rcx", "r11", "memory"
        );
        const isize_return = @bitCast(isize, addr_or_err);
        if (-128 <= isize_return and isize_return <= -1) {
            return errorFromNegativeValue(addr_or_err);
        } else {
            return addr_or_err;
        }
    }

    pub fn debugKernelPrint(message: []const u8) void {
        _ = asm volatile ("syscall"
            : [out] "={rax}" (-> usize)
            : [syscall] "{rax}" (@enumToInt(Syscall.debug)),
              [message_ptr] "{rdi}" (@ptrToInt(message.ptr)),
              [message_len] "{rsi}" (message.len)
            : "rcx", "r11"
        );
    }
};


const KernelDebugWriter = struct {
    var write_buffer: [256]u8 = undefined;

    pub const Error = error {};

    pub fn writeAll(self: KernelDebugWriter, bytes: []const u8) Error!void {
        syscall.debugKernelPrint(bytes);
    }

    pub fn writeByte(self: KernelDebugWriter, byte: u8) Error!void {
        const char = [1]u8{byte};
        syscall.debugKernelPrint(&char);
    }

    pub fn writeByteNTimes(self: KernelDebugWriter, byte: u8, n: usize) Error!void {
        std.mem.set(u8, write_buffer[0..], byte);

        var remaining: usize = n;
        while (remaining > 0) {
            const to_write = std.math.min(remaining, write_buffer.len);
            syscall.debugKernelPrint(write_buffer[0..to_write]);
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
    const prefix = "[test_zig_program - " ++ @tagName(level) ++ "] (" ++ @tagName(scope) ++ "): ";
    std.fmt.format(kernel_debug_writer, prefix ++ format ++ "\n", args) catch {};
}

export fn _start() void {
    logger.debug("Hello from usermode Zig!", .{});
    logger.debug("This is process {}", .{syscall.getPid()});
    // logger.debug("Testing COM1 port...", .{});
    // for ("Hello world!\r\n") |byte| serial.Com1.writeByte(byte);
    // logger.debug("COM1 test succeeded!", .{});
    runHeapTests() catch |err| {
        logger.emerg("Heap testing returned {}", .{err});
        @panic("heap testing failed");
    };
    while (true) {}
}

fn runHeapTests() !void {
    logger.debug("Heap tests!", .{});
    logger.debug("Current program break: 0x{x}", .{try syscall.moveBreak(0)});
    const ptr_1 = @intToPtr(*u64, try syscall.moveBreak(8));
    const ptr_2 = @intToPtr(*u64, try syscall.moveBreak(8));
    logger.debug("{*}, {*}", .{ptr_1, ptr_2});
    ptr_1.* = 1;
    ptr_2.* = 2;
    _ = try syscall.moveBreak(-8);
    _ = try syscall.moveBreak(-8);
    logger.debug("{}, {}", .{ptr_1.*, ptr_2.*});
}

pub fn panic(message: []const u8, trace_maybe: ?*std.builtin.StackTrace) noreturn {
    logger.emerg("{s}", .{message});
    while (true) {}
}
