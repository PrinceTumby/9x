//! Collection of modules related to kernel handling of the RV64GC architecture

// Architecture internal support

pub const common = @import("riscv64/common.zig");
pub const serial = @import("riscv64/serial.zig");

// Initialisation steps

const std = @import("std");
const logger = std.log.scoped(.riscv64);

pub fn stage1Init(_args: *KernelArgs) void {
    @panic("Stage 1 init unimplemented");
}

pub fn stage2Init(_args: *KernelArgs) void {
    @panic("Stage 2 init unimplemented");
}

const sbi = struct {
    pub fn console_putchar(character: usize) usize {
        return asm volatile (
            "ecall" 
            : [out] "=(a0)" (-> usize)
            : [extension_id] "(a7)" (@as(usize, 1)),
              [argument] "(a0)" (character)
        );
    }
};

export fn test_entry() callconv(.Naked) void {
    // logger.debug("Hello world!", .{});
    // if (true) while (true) {};
    for ("Hello world!\r\n") |byte| {
        serial.Com1.writeByte(byte);
        // _ = sbi.console_putchar(byte);
    }
    while (true) {
        // serial.Com1.writeByte(serial.Com1.readByte());
    }
}
