const std = @import("std");
const serial = @import("serial.zig");

const syscall = struct {
    pub const Error = error{
        UnknownSyscall,
        InvalidArgument,
        OutOfMemory,
        UnknownError,
    };

    fn errorFromNegativeValue(value: usize) Error {
        // logger.debug("Translating {}", .{-%(value +% 1)});
        return switch (@as(ErrorValue, @enumFromInt(-%(value +% 1)))) {
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
            : [out] "={rax}" (-> usize),
            : [syscall] "{rax}" (@intFromEnum(Syscall.get_pid)),
            : .{ .rcx = true, .r11 = true }
        );
    }

    pub fn setBreak(new_break_address: usize) !usize {
        const addr_or_err = asm volatile ("syscall"
            : [out] "={rax}" (-> usize),
            : [syscall] "{rax}" (@intFromEnum(Syscall.set_break)),
              [new_break_address] "{rdi}" (new_break_address),
            : .{ .rcx = true, .r11 = true, .memory = true }
        );
        const isize_return: isize = @bitCast(addr_or_err);
        if (-128 <= isize_return and isize_return <= -1) {
            return errorFromNegativeValue(addr_or_err);
        } else {
            return addr_or_err;
        }
    }

    pub fn moveBreak(move_delta: isize) !usize {
        const addr_or_err = asm ("syscall"
            : [out] "={rax}" (-> usize),
            : [syscall] "{rax}" (@intFromEnum(Syscall.move_break)),
              [move_delta] "{rdi}" (move_delta),
            : .{ .rcx = true, .r11 = true, .memory = true }
        );
        const isize_return: isize = @bitCast(addr_or_err);
        if (-128 <= isize_return and isize_return <= -1) {
            return errorFromNegativeValue(addr_or_err);
        } else {
            return addr_or_err;
        }
    }

    pub fn debugKernelPrint(message: []const u8) void {
        _ = asm volatile ("syscall"
            : [out] "={rax}" (-> usize),
            : [syscall] "{rax}" (@intFromEnum(Syscall.debug)),
              [message_ptr] "{rdi}" (message.ptr),
              [message_len] "{rsi}" (message.len),
            : .{ .rcx = true, .r11 = true }
        );
    }
};

fn kernelDebugWriterDrain(w: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
    // Write buffered data.
    const initial_data = w.buffer[0..w.end];
    syscall.debugKernelPrint(initial_data);
    w.end = 0;
    // Write rest of the data.
    var data_bytes_written: usize = 0;
    if (data.len > 1) {
        for (data[0..data.len - 1]) |data_slice| {
            syscall.debugKernelPrint(data_slice);
            data_bytes_written += data_slice.len;
        }
    }
    for (0..splat) |i| {
        _ = i;
        const data_slice = data[data.len - 1];
        syscall.debugKernelPrint(data_slice);
        data_bytes_written += data_slice.len;
    }
    return data_bytes_written;
}

var kernel_debug_writer_buffer: [256]u8 = undefined;
var kernel_debug_writer = std.io.Writer{
    .vtable = &.{
        .drain = &kernelDebugWriterDrain,
    },
    .buffer = &kernel_debug_writer_buffer,
};

pub const log_level: std.log.Level = .debug;

fn customLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = "(" ++ @tagName(scope) ++ "): ";
    const prefix = "[test_zig_program - " ++ comptime level.asText() ++ "]" ++ scope_prefix;
    kernel_debug_writer.print(prefix ++ format ++ "\n", args) catch {};
}

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = customLog,
};

const logger = std.log.scoped(.main);

export fn _start() void {
    logger.debug("Hello from usermode Zig!", .{});
    logger.debug("This is process {}", .{syscall.getPid()});
    // logger.debug("Testing COM1 port...", .{});
    // for ("Hello world!\r\n") |byte| serial.Com1.writeByte(byte);
    // logger.debug("COM1 test succeeded!", .{});
    runHeapTests() catch |err| {
        logger.err("Heap testing returned {}", .{err});
        @panic("heap testing failed");
    };
    while (true) {
        // logger.debug("Hello, world!", .{});
    }
}

fn runHeapTests() !void {
    logger.debug("Heap tests!", .{});
    logger.debug("Current program break: 0x{x}", .{try syscall.moveBreak(0)});
    const ptr_1: *u64 = @ptrFromInt(try syscall.moveBreak(8));
    const ptr_2: *u64 = @ptrFromInt(try syscall.moveBreak(8));
    logger.debug("{*}, {*}", .{ ptr_1, ptr_2 });
    ptr_1.* = 1;
    ptr_2.* = 2;
    _ = try syscall.moveBreak(-8);
    _ = try syscall.moveBreak(-8);
    logger.debug("{}, {}", .{ ptr_1.*, ptr_2.* });
    logger.debug("Tests done!", .{});
}

pub const panic = std.debug.FullPanic(customPanic);

fn customPanic(message: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    logger.err("Panic - {s}", .{message});
    while (true) {}
}
