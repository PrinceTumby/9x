//! Support for outputting text through COM ports for debugging

const std = @import("std");
const common = @import("common.zig");
const portReadByte = common.port.readByte;
const portWriteByte = common.port.writeByte;

pub const Com1 = Port(0x3F8);
pub const Com2 = Port(0x2F8);
pub const Com3 = Port(0x3E8);
pub const Com4 = Port(0x2E8);

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
            // Check if port exists by writing to scratch register
            const scratch_incremented = portReadByte(scratch_reg) +% 1;
            portWriteByte(scratch_reg, scratch_incremented);
            if (portReadByte(scratch_reg) != scratch_incremented) return false;
            // Wipe scratch register back to 0
            portWriteByte(scratch_reg, 0x00);
            // Disable all interrupts
            portWriteByte(interrupt_enable_reg, 0x00);
            // Enable DLAB, set rate to 115,200 baud
            portWriteByte(line_control_reg, 0x80);
            portWriteByte(divisor_low, 0x01);
            portWriteByte(divisor_high, 0x00);
            // Disable DLAB, set 8 bits, no parity, 1 stop bit
            portWriteByte(line_control_reg, 0x03);
            // Enable FIFOs, clear them, set 14-byte threshold
            portWriteByte(fifo_control_reg, 0xC7);
            // Set loopback mode
            portWriteByte(modem_control_reg, 0x10);
            // Send 0xAE, check if port returns same byte
            portWriteByte(data, 0xAE);
            if (readByte() != 0xAE) return false;
            // Set normal operation mode if serial is not faulty
            portWriteByte(modem_control_reg, 0x00);
            return true;
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

pub fn Writer(comptime port: type) type {
    return struct {
        var write_buffer: [256]u8 = undefined;

        const Self = @This();

        pub const Error = error {};

        pub fn tryInit(self: Self) bool {
            return port.init();
        }

        pub fn writeAll(self: Self, bytes: []const u8) Error!void {
            for (bytes) |byte| {
                if (byte == '\n') port.writeByte('\r');
                port.writeByte(byte);
            }
        }

        pub fn writeByte(self: Self, byte: u8) Error!void {
            if (byte == '\n') port.writeByte('\r');
            port.writeByte(byte);
        }

        pub fn writeByteNTimes(self: Self, byte: u8, n: usize) Error!void {
            std.mem.set(u8, write_buffer[0..], byte);

            var remaining: usize = n;
            while (remaining > 0) {
                const to_write = std.math.min(remaining, write_buffer.len);
                try self.writeAll(write_buffer[0..to_write]);
                remaining -= to_write;
            }
        }
    };
}
