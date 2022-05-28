const std = @import("std");
const root = @import("root");
const logging = root.logging;
const common = @import("../common.zig");
const port = common.port;

const logger = std.log.scoped(.x86_64_cmos);

pub const nmi_and_register_port: u16 = 0x70;
pub const data_port: u16 = 0x71;

pub const registers = struct {
    pub const seconds: u8 = 0x0;
    pub const minutes: u8 = 0x2;
    pub const hours: u8 = 0x4;
    pub const weekday: u8 = 0x6;
    pub const day_of_month: u8 = 0x7;
    pub const month: u8 = 0x8;
    pub const year: u8 = 0x9;
    pub const status_register_a: u8 = 0xA;
    pub const status_register_b: u8 = 0xB;
    pub const status_register_c: u8 = 0xC;
};

pub fn readByte(disable_nmi: bool, register: u8) u8 {
    const nmi_bit: u8 = if (disable_nmi) 0x80 else 0x00;
    port.writeByte(nmi_and_register_port, register | nmi_bit);
    return port.readByte(data_port);
}

pub fn writeByte(disable_nmi: bool, register: u8, byte: u8) void {
    const nmi_bit: u8 = if (disable_nmi) 0x80 else 0x00;
    port.writeByte(nmi_and_register_port, register | nmi_bit);
    port.writeByte(data_port, byte);
}

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
