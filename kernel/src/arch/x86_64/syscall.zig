const std = @import("std");
const root = @import("root");
const tls = @import("tls.zig");
const asmSymbolFmt = root.zig_extensions.asmSymbolFmt;

const logger = std.log.scoped(.x86_64_syscall);

pub const Error = error {
    InvalidArgument,
    OutOfMemory,
};

pub const ErrorValue = enum(usize) {
    unknown_syscall,
    invalid_argument,
    out_of_memory,

    pub fn fromErr(zig_error: Error) ErrorValue {
        return switch (zig_error) {
            Error.InvalidArgument => .invalid_argument,
            Error.OutOfMemory => .out_of_memory,
        };
    }

    pub fn fromErrNeg(zig_error: Error) usize {
        // logger.debug("Translated {} to {}", .{
        //     zig_error,
        //     @bitCast(isize, -%(@enumToInt(ErrorValue.fromErr(zig_error)) + 1)),
        // });
        return -%(@enumToInt(ErrorValue.fromErr(zig_error)) + 1);
    }
};

pub extern fn syscallEntrypoint() callconv(.Naked) void;

pub const SystemCall = enum(u64) {
    set_break,
    move_break,
    debug,
    _,

    comptime {
        @setEvalBranchQuota(5000);
        inline for (@typeInfo(SystemCall).Enum.fields) |system_call| {
            asm (asmSymbolFmt("SystemCall." ++ system_call.name, system_call.value));
        }
    }
};

pub fn handleSystemCall() void {
    const tls_ptr = tls.getThreadLocalVariables();
    const current_process = &tls_ptr.current_process;
    const process_registers = &tls_ptr.current_process.registers;
    switch (@intToEnum(SystemCall, process_registers.rax)) {
        .set_break => process_registers.rax = setBreak(process_registers.rdi)
            catch |err| ErrorValue.fromErrNeg(err),
        .move_break => {
            const previous_break = current_process.program_break_location;
            const requested_move_delta = process_registers.rdi;
            if (requested_move_delta == 0) {
                process_registers.rax = previous_break;
                return;
            }
            const requested_break = previous_break +% requested_move_delta;
            _ = setBreak(requested_break) catch |err| {
                logger.debug("1", .{});
                process_registers.rax = ErrorValue.fromErrNeg(err);
                return;
            };
            process_registers.rax = previous_break;
        },
        .debug => {
            const message_ptr = @intToPtr([*]const u8, process_registers.rdi);
            const message_len = process_registers.rsi;
            root.logging.logRaw("{s}", .{message_ptr[0..message_len]});
            process_registers.rax = 0;
        },
        else => @panic("kernel bug: unknown zig system call"),
    }
}

pub fn handleException() void {
    const tls_ptr = tls.getThreadLocalVariables();
    const current_process = &tls_ptr.current_process;
    const process_registers = &current_process.registers;
    const info = tls_ptr.yield_info;
    switch (info.exception_type) {
        .page_fault => {
            // If process attempted to access a non-existent stack page, allocate it
            const address = info.page_fault_address;
            const stack_lower_limit = current_process.stack_lower_limit;
            const stack_upper_limit = current_process.stack_upper_limit;
            const break_lower_limit = current_process.program_break_lower_limit;
            const break_current_location = current_process.program_break_location;
            if (stack_lower_limit <= address and address <= stack_upper_limit) {
                tls_ptr.kernel_main_process.page_allocator_ptr.loadAddressSpace();
                const page_address = address & ~@as(usize, 0xFFF);
                current_process.page_mapper.mapMemCopyFromBuffer(
                    page_address,
                    0x1000,
                    &[0]u8{},
                ) catch @panic("out of memory");
                current_process.page_mapper.changeFlags(
                    page_address,
                    current_process.stack_flags,
                    0x1000,
                );
            } else if (break_lower_limit <= address and address < break_current_location) {
                tls_ptr.kernel_main_process.page_allocator_ptr.loadAddressSpace();
                const page_address = address & ~@as(usize, 0xFFF);
                current_process.page_mapper.mapMemCopyFromBuffer(
                    page_address,
                    0x1000,
                    &[0]u8{},
                ) catch @panic("out of memory");
                current_process.page_mapper.changeFlags(
                    page_address,
                    current_process.stack_flags,
                    0x1000,
                );
            } else {
                // Page fault was actually due to invalid memory access
                logger.emerg("User process crashed - {}", .{info.exception_type});
                logger.emerg("Exception error code - 0x{X}", .{info.exception_error_code});
                logger.emerg("Caused by access to address 0x{x}", .{info.page_fault_address});
                logger.emerg("By instruction at 0x{x}", .{process_registers.rip});
                @panic("User exceptions currently unhandled");
            }
        },
        else => {
            logger.emerg("User process crashed - {}", .{info.exception_type});
            logger.emerg("Exception error code - 0x{X}", .{info.exception_error_code});
            logger.emerg("Caused by instruction at 0x{x}", .{process_registers.rip});
            @panic("User exceptions currently unhandled");
        },
    }
}

fn setBreak(new_break: usize) Error!usize {
    const tls_ptr = tls.getThreadLocalVariables();
    const current_process = &tls_ptr.current_process;
    if (new_break < current_process.program_break_lower_limit or
        new_break > current_process.program_break_upper_limit)
    {
        return error.InvalidArgument;
    }
    // Correct and set new break location
    const old_break = current_process.program_break_location;
    current_process.program_break_location = new_break;
    // Allocate or free pages depending on program break change
    const old_break_page = std.mem.alignBackward(old_break, 4096);
    const new_break_page = std.mem.alignBackward(new_break, 4096);
    if (new_break_page < old_break_page) {
        tls_ptr.kernel_main_process.page_allocator_ptr.loadAddressSpace();
        current_process.page_mapper.unmapMem(
            new_break_page + 4096,
            old_break_page - new_break_page,
        );
    }
    return new_break;
}
