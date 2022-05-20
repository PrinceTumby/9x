//! Support for outputting text through COM ports for debugging

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

        // TODO Implement checking if serial port is already initialised
        pub fn init() bool {
            return asm volatile (
                \\// Disable all interrupts
                \\movw %[interrupt_reg], %%dx
                \\movb $0x00, %%al
                \\outb %%al, %%dx
                \\// Enable DLAB and set baud rate divisor
                \\movw %[line_control_reg], %%dx
                \\movb $0x80, %%al
                \\outb %%al, %%dx
                \\movw %[div_low], %%dx
                \\movb $0x01, %%al
                \\outb %%al, %%dx
                \\movw %[div_high], %%dx
                \\movb $0x00, %%al
                \\outb %%al, %%dx
                \\// Disable DLAB, set 8 bits, no parity, 1 stop bit
                \\movw %[line_control_reg], %%dx
                \\movb $0x03, %%al
                \\outb %%al, %%dx
                \\// Enable FIFOs, clear them, with 14-byte threshold
                \\movw %[fifo_reg], %%dx
                \\movb $0xC7, %%al
                \\outb %%al, %%dx
                \\// Enable IRQs, RTS/DSR set
                \\movw %[modem_control_reg], %%dx
                \\movb $0x0B, %%al
                \\outb %%al, %%dx
                \\// Set in loopback mode, test serial chip
                \\movw %[modem_control_reg], %%dx
                \\movb $0x1E, %%al
                \\outb %%al, %%dx
                \\// Test serial chip (send 0xAE and check if same byte is returned)
                \\movw %[data], %%dx
                \\movb $0xAE, %%al
                \\outb %%al, %%dx
                \\inb %%dx, %%al
                \\cmpb $0xAE, %%al
                \\jnz loopback_failed
                \\// Serial not faulty, set normal operation
                \\// (normal mode, IRQs enabled, OUT#1 and OUT#2 bits enabled)
                \\movw %[modem_control_reg], %%dx
                \\movb $0x0F, %%al
                \\outb %%al, %%dx
                \\movb $1, %[out]
                \\jmp end
                \\loopback_failed:
                \\movb $0, %[out]
                \\end:
                : [out] "=r" (-> u8)
                : [data] "i" (data),
                  [interrupt_reg] "i" (interrupt_enable_reg),
                  [line_control_reg] "i" (line_control_reg),
                  [div_low] "i" (divisor_low),
                  [div_high] "i" (divisor_high),
                  [fifo_reg] "i" (fifo_control_reg),
                  [modem_control_reg] "i" (modem_control_reg)
                : "al", "dx"
            ) == 1;
        }

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
