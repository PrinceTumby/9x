const std = @import("std");
const ps2_manager = @import("ps2_manager.zig");

port: ps2_manager.Port,

const logger = std.log.scoped(.x86_64_ps2_keyboard);

pub const Command = enum(u8) {
    SetLeds = 0xED,
    Echo = 0xEE,
    ModifyScanCodeSet = 0xF0,
    Identify = 0xF2,
    SetTypematicProperties = 0xF3,
    EnableScanning = 0xF4,
    DisableScanning = 0xF5,
    SetDefaultParameters = 0xF6,
    ResendLastByte = 0xFE,
    Reset = 0xFF,
};

const Self = @This();

pub fn init(port: ps2_manager.Port) !Self {
    // Get scan code set
    try port.sendKeyboardCommand(.ModifyScanCodeSet, 0);
    if ((port.readByteTimeout(100) orelse return error.Timeout) != 2) {
        return error.WrongScanCodeSet;
    }
    try port.sendKeyboardCommand(.EnableScanning, null);
    return Self {.port = port};
}

fn scanCodeToChar(code: u8) u8 {
    return switch (code) {
        0x1C => 'a',
        0x32 => 'b',
        0x21 => 'c',
        0x23 => 'd',
        0x24 => 'e',
        0x2B => 'f',
        0x34 => 'g',
        0x33 => 'h',
        0x43 => 'i',
        0x3B => 'j',
        0x42 => 'k',
        0x4B => 'l',
        0x3A => 'm',
        0x31 => 'n',
        0x44 => 'o',
        0x4D => 'p',
        0x15 => 'q',
        0x2D => 'r',
        0x1B => 's',
        0x2C => 't',
        0x3C => 'u',
        0x2A => 'v',
        0x1D => 'w',
        0x22 => 'x',
        0x35 => 'y',
        0x1A => 'z',
        0x29 => ' ',
        0x5A => '\n',
        else => '?',
    };
}

pub fn getNextCharacter(self: Self) u8 {
    // return self.port.readByteBlocking();
    while (true) {
        const byte = self.port.readByteBlocking();
        // Skip byte if release character
        if (byte == 0xF0) {
            _ = self.port.readByteBlocking();
            continue;
        }
        const char = scanCodeToChar(byte);
        // return char;
        if (char != '?') {
            return char;
        } else {
            logger.debug("Unknown code: 0x{X}", .{byte});
        }
    }
}
