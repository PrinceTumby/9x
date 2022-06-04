const std = @import("std");
const root = @import("root");
const tls = @import("tls.zig");
const asmSymbolFmt = root.zig_extensions.asmSymbolFmt;

const logger = std.log.scoped(.x86_64_syscall);

pub extern fn syscallEntrypoint() callconv(.Naked) void;

pub const SystemCall = enum(u64) {
    Debug,
    _,

    comptime {
        @setEvalBranchQuota(5000);
        inline for (@typeInfo(SystemCall).Enum.fields) |system_call| {
            asm(asmSymbolFmt("SystemCall." ++ system_call.name, system_call.value));
        }
    }
};

pub fn handleSystemCall() void {
    const tls_ptr = tls.getThreadLocalVariables();
    const process_registers = &tls_ptr.current_process.registers;
    switch (@intToEnum(SystemCall, process_registers.rax)) {
        .Debug => {
            const message_ptr = @intToPtr([*]const u8, process_registers.rdi);
            const message_len = process_registers.rsi;
            logger.debug("{s}", .{message_ptr[0..message_len]});
            process_registers.rax = 0;
        },
        else => @panic("kernel bug: unknown zig system call"),
    }
}
