//! Support for outputting text through COM1 for debugging

const std = @import("std");

pub fn Port(comptime port: u16) type {
    return struct {
        pub const data: u16 = port;
        pub const interrupt_enable_reg: u16 = port + 1;
        pub const divisor_low: u16 = port;
        pub const divisor_high: u16 = port + 1;
        pub const fifo_control_reg: u16 = port + 2;
        pub const line_control_reg: u16 = port + 3;
        pub const modem_control_reg: u16 = port + 4;
        pub const line_status_reg: u16 = port + 5;
        pub const modem_status_reg: u16 = port + 6;
        pub const scratch_reg: u16 = port + 7;

        const Self = @This();

        pub inline fn readByte() u8 {
            // Wait until serial port ready
            while (asm volatile ("inb %[line_status_reg], %[out]"
                    : [out] "={al}" (-> u8)
                    : [line_status_reg] "{dx}" (line_status_reg)
            ) & 0x01 == 0) {}

            // Receive byte
            return asm ("inb %%dx, %[out]"
                : [out] "={al}" (-> u8)
                : [data] "{dx}" (data));
        }

        pub inline fn writeByte(byte: u8) void {
            // Wait until serial port ready
            while (asm volatile ("inb %[line_status_reg], %[out]"
                    : [out] "={al}" (-> u8)
                    : [line_status_reg] "{dx}" (line_status_reg)
            ) & 0x20 == 0) {}

            // Send byte
            asm volatile ("outb %[byte], %[data]" 
                :
                : [byte] "{al}" (byte), [data] "{dx}" (data));
        }
    };
}

pub const Com1 = Port(0x3F8);
pub const Com2 = Port(0x2F8);
pub const Com3 = Port(0x3E8);
pub const Com4 = Port(0x2E8);
