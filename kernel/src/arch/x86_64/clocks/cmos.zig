const std = @import("std");
const root = @import("root");
const logging = root.logging;
const logger = std.log.scoped(.x86_64_cmos);

pub const cmos_registers = struct {
    pub const seconds: u8 = 0x0;
    pub const minutes: u8 = 0x2;
    pub const hours: u8 = 0x4;
    pub const weekday: u8 = 0x6;
    pub const day_of_month: u8 = 0x7;
    pub const month: u8 = 0x8;
    pub const year: u8 = 0x9;
    pub const status_register_a: u8 = 0xA;
    pub const status_register_b: u8 = 0xB;
};

pub fn calibrationSleep(startTimer: fn() void) u32 {
    // Wait until next second has just started
    asm volatile (
        \\1:
        \\movb $0xA, %%al
        \\outb %%al, $0x70
        \\inb $0x71, %%al
        \\testb $0x80, %%al
        \\jz 1b
        \\2:
        \\movb $0xA, %%al
        \\outb %%al, $0x70
        \\inb $0x71, %%al
        \\testb $0x80, %%al
        \\jnz 2b
        :
        :
        : "al"
    );
    // Run measurement function
    startTimer();
    // Wait until current second has ended
    asm volatile (
        \\1:
        \\movb $0xA, %%al
        \\outb %%al, $0x70
        \\inb $0x71, %%al
        \\testb $0x80, %%al
        \\jz 1b
        \\2:
        \\movb $0xA, %%al
        \\outb %%al, $0x70
        \\inb $0x71, %%al
        \\testb $0x80, %%al
        \\jnz 2b
        :
        :
        : "al"
    );
    return 1_000_000;
}
