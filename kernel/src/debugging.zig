const std = @import("std");
const root = @import("root");
const waitForInterrupt = root.arch.common.waitForInterrupt;
const logging = root.logging;
const elf = root.elf;

pub var disable_trace_logging = false;
pub var kernel_elf_file: ?[]const u8 = null;

// TODO Make this platform agnostic
fn stackTraceNext(trace: *std.debug.StackIterator) ?usize {
    // TODO Make this thread local
    const static_vars = struct {
        pub var last_fp: usize = 0;
    };
    if (trace.fp == static_vars.last_fp) return null;
    if (trace.fp == 0 or !std.mem.isAligned(trace.fp, @alignOf(usize)))
        return null;
    const new_fp = @intToPtr(*const usize, trace.fp).*;
    const new_pc = @intToPtr(
        *const usize,
        std.math.add(usize, trace.fp, @sizeOf(usize)) catch return null,
    ).*;
    static_vars.last_fp = trace.fp;
    trace.fp = new_fp;
    return if (new_pc != 0) new_pc else null;
}

pub noinline fn printStackTrace(trace_maybe: ?*std.builtin.StackTrace) void {
    // Get kernel ELF file for function names
    const kernel_elf_maybe: ?elf.Elf = blk: {
        const kernel_elf_file_slice = kernel_elf_file orelse break :blk null;
        const parsed_elf = elf.Elf.init(kernel_elf_file_slice) catch break :blk null;
        switch (parsed_elf) {
            .Bit64 => |elf_64| {
                if (elf_64.string_table == null) break :blk null;
                if (elf_64.symbol_table == null) break :blk null;
            },
        }
        break :blk parsed_elf;
    };
    // Print trace
    // std.fmt.format(
    //     logging.com4_writer,
    //     "0x{x}\n",
    //     .{asm ("leaq 0(%%rip), %[out]" : [out] "=r" (-> u64))},
    // ) catch {};
    // std.fmt.format(logging.com4_writer, "0x{x}\n", .{@returnAddress()}) catch {};
    if (trace_maybe) |trace| {
        if (kernel_elf_maybe) |kernel_elf| {
            for (trace.instruction_addresses) |address| {
                const function_maybe = kernel_elf.getFunctionAtAddress(address);
                if (function_maybe) |function| {
                    logging.logRawLn("  [0x{x}] {s}+0x{x}/0x{x}", .{
                        address,
                        function.name,
                        address - function.address,
                        function.size,
                    });
                } else {
                    logging.logRawLn("  [0x{x}] ???+??/??", .{address});
                }
                std.fmt.format(logging.bochs_writer, "0x{x}\n", .{address}) catch {};
                // std.fmt.format(logging.com4_writer, "0x{x}\n", .{address}) catch {};
            }
        } else {
            logging.logRawLn("Symbol table unavailable", .{});
            for (trace.instruction_addresses) |address| {
                logging.logRawLn("  [0x{x}] ???+??/??", .{address});
                std.fmt.format(logging.bochs_writer, "0x{x}\n", .{address}) catch {};
                // std.fmt.format(logging.com4_writer, "0x{x}\n", .{address}) catch {};
            }
        }
    } else {
        const first_trace_address = @frameAddress();
        var trace_iter = std.debug.StackIterator.init(
            null,
            first_trace_address,
        );
        if (kernel_elf_maybe) |kernel_elf| {
            while (stackTraceNext(&trace_iter)) |address| {
                const function_maybe = kernel_elf.getFunctionAtAddress(address);
                if (function_maybe) |function| {
                    logging.logRawLn("  [0x{x}] {s}+0x{x}/0x{x}", .{
                        address,
                        function.name,
                        address - function.address,
                        function.size,
                    });
                } else {
                    logging.logRawLn("  [0x{x}] ???+??/??", .{address});
                }
                std.fmt.format(logging.bochs_writer, "0x{x}\n", .{address}) catch {};
                // std.fmt.format(logging.com4_writer, "0x{x}\n", .{address}) catch {};
            }
        } else {
            logging.logRawLn("Symbol table unavailable", .{});
            while (stackTraceNext(&trace_iter)) |address| {
                logging.logRawLn("  [0x{x}] ???+??/??", .{address});
                std.fmt.format(logging.bochs_writer, "0x{x}\n", .{address}) catch {};
                // std.fmt.format(logging.com4_writer, "0x{x}\n", .{address}) catch {};
            }
        }
    }
}

var panic_depth: usize = 0;

pub noinline fn panic(message: []const u8, trace_maybe: ?*std.builtin.StackTrace) noreturn {
    switch (panic_depth) {
        0 => {},
        // Disable screen
        1 => root.logging.removeLogDevice(),
        2 => {
            logging.logString(.emerg, .main, "KERNEL PANIC: ", message);
            while (true) waitForInterrupt();
        },
        else => while (true) waitForInterrupt(),
    }
    panic_depth += 1;
    // logger.emerg("KERNEL PANIC: {s}", .{message});
    logging.logString(.emerg, .main, "KERNEL PANIC: ", message);
    // Print stack trace
    if (!disable_trace_logging) {
        logging.logRawLn("STACK TRACE:", .{});
        printStackTrace(trace_maybe);
        logging.logRawLn("END OF TRACE", .{});
    } else {
        logging.logRawLn("STACK TRACES DISABLED", .{});
    }
    while (true) waitForInterrupt();
}
