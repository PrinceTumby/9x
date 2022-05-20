//! Support for outputting text through COM ports for debugging

const std = @import("std");

pub fn Port(comptime address: usize) type {
    return struct {
        pub const data = @intToPtr(*volatile u8, address);
        pub const status = @intToPtr(*volatile u8, address + 1);

        const Self = @This();

        pub inline fn readByte() u8 {
            return data.*;
        }

        pub inline fn writeByte(byte: u8) void {
            while (data.* != 0) data.* = byte;
        }
    };
}

pub const Com1 = Port(0x10000000);
pub const Com2 = Port(0x10000000);
pub const Com3 = Port(0x10000000);
pub const Com4 = Port(0x10000000);
