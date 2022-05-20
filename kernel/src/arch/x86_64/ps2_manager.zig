const std = @import("std");
const common = @import("common.zig");
const idt = @import("idt.zig");
const interrupts = @import("interrupts.zig");
const clock_manager = @import("clock_manager.zig");
const Ps2Keyboard = @import("Ps2Keyboard.zig");
const controller = @import("ps2_8042_controller.zig");
const readDataByte = controller.readDataByte;
const sendDataByte = controller.sendDataByte;

const logger = std.log.scoped(.x86_64_ps2_manager);

/// Commands that all PS/2 devices support
const CommonCommand = enum(u8) {
    Echo = 0xEE,
    Identify = 0xF2,
    DisableScanning = 0xF5,
    Reset = 0xFF,
};

const ByteFifo = std.fifo.LinearFifo(u8, .{.Static = 16});

pub const Port = struct {
    byteReaderHandler: fn(*const idt.InterruptFrame) callconv(.Interrupt) void,
    writeByte: fn(byte: u8) void,
    byte_fifo: *ByteFifo,

    pub fn readByteBlocking(self: Port) u8 {
        while (self.byte_fifo.readableLength() == 0) {
            asm volatile ("sti; hlt; cli");
        }
        return self.byte_fifo.readItem().?;
    }

    pub fn readByteTimeout(self: Port, timeout_ms: u32) ?u8 {
        clock_manager.startCountdown(timeout_ms);
        while (true) {
            if (self.byte_fifo.readableLength() > 0) {
                clock_manager.stopCountdown();
                return self.byte_fifo.readItem();
            }
            if (clock_manager.getHasCountdownEnded()) {
                clock_manager.stopCountdown();
                return null;
            }
            asm volatile ("sti; hlt; cli");
        }
    }

    pub const Response = enum(u16) {
        SelfTestPassed = 0xAA,
        Echo = 0xEE,
        Acknowledged = 0xFA,
        SelfTestFailed1 = 0xFC,
        SelfTestFailed2 = 0xFD,
        Resend = 0xFE,
        /// Returned if reading a response times out
        Timeout = 0x100,
        /// Returned if a command has to be resent too many times
        TooManyResends = 0x101,
        _,
    };

    pub fn sendCommonCommand(self: Port, command: CommonCommand) Response {
        // Send command
        self.writeByte(@enumToInt(command));
        // Wait for response or timeout
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            switch (@intToEnum(Response, self.readByteTimeout(100) orelse return .Timeout)) {
                .Resend => continue,
                else => |response| return response,
            }
        }
        return .TooManyResends;
    }

    pub fn sendKeyboardCommand(
        self: Port,
        command: Ps2Keyboard.Command,
        data_byte: ?u8,
    ) !void {
        // Send command
        self.writeByte(@enumToInt(command));
        // Wait for response or timeout
        {
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                const response = self.readByteTimeout(100) orelse return error.Timeout;
                if (command == .Echo and response == @enumToInt(Response.Echo)) return;
                switch (@intToEnum(Response, response)) {
                    .Resend => continue,
                    .Acknowledged => break,
                    else => return error.UnknownResponse,
                }
            } else return error.TooManyResends;
        }
        // Send extra byte if passed in
        if (data_byte) |byte| {
            self.writeByte(byte);
            // Wait for response or timeout
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                const response = self.readByteTimeout(100) orelse return error.Timeout;
                switch (@intToEnum(Response, response)) {
                    .Resend => continue,
                    .Acknowledged => break,
                    else => return error.UnknownResponse,
                }
            } else return error.TooManyResends;
        }
    }

    pub fn readResponseByte(self: Port) Response {
        return @intToEnum(Response, self.readByteTimeout(100) orelse return .Timeout);
    }
};

const port_1 = struct {
    pub const port = Port {
        .byteReaderHandler = byteReaderHandler,
        .writeByte = writeByte,
        .byte_fifo = &byte_queue,
    };

    pub fn byteReaderHandler(_: *const idt.InterruptFrame) callconv(.Interrupt) void {
        const io_port = common.port;
        const next_byte = io_port.readByte(io_port.ps2_data);
        byte_queue.writeItem(next_byte) catch logger.warn("PS/2 FIFO byte discarded", .{});
        interrupts.signalEoi();
    }

    pub fn writeByte(byte: u8) void {
        sendDataByte(byte);
    }

    pub var byte_queue = ByteFifo.init();
};

const port_2 = struct {
    pub const port = Port {
        .byteReaderHandler = byteReaderHandler,
        .writeByte = writeByte,
        .byte_fifo = &byte_queue,
    };

    pub fn byteReaderHandler(_: *const idt.InterruptFrame) callconv(.Interrupt) void {
        const io_port = common.port;
        const next_byte = io_port.readByte(io_port.ps2_data);
        byte_queue.writeItem(next_byte) catch logger.warn("PS/2 FIFO byte discarded", .{});
        interrupts.signalEoi();
    }

    pub fn writeByte(byte: u8) void {
        controller.sendCommand(.WritePort2);
        sendDataByte(byte);
    }

    pub var byte_queue = ByteFifo.init();
};

pub var keyboard: ?Ps2Keyboard = null;

pub fn init() !void {
    const port_info = controller.tryInit();
    logger.debug("Controller initialised: {}", .{port_info});
    const port_1_enabled = if (port_info.port_1_working) blk: {
        const port = port_1.port;
        try interrupts.mapLegacyIrq(1, port.byteReaderHandler);
        logger.debug("1", .{});
        controller.setInterruptMasks(true, false);
        controller.sendCommand(.EnablePort1);
        // Reset device
        if (port.sendCommonCommand(.Reset) != .Acknowledged) break :blk false;
        if (port.readResponseByte() != .SelfTestPassed) break :blk false;
        logger.debug("Reset port 1, self test passed.", .{});
        // Disable scanning
        if (port.sendCommonCommand(.DisableScanning) != .Acknowledged) break :blk false;
        logger.debug("Port 1 scanning disabled", .{});
        // Identify device type
        // logger.debug("Identify: {}", .{port.sendCommonCommand(.Identify)});
        // sendDataByte(0xFF);
        // logger.debug("{X}", .{readDataByte()});
        // logger.debug("{X}", .{readDataByte()});
        // sendDataByte(0xF5);
        // logger.debug("{X}", .{readDataByte()});
        // sendDataByte(0xF2);
        // // logger.debug("{X}", .{readDataByte()});
        // // logger.debug("{X}", .{readDataByte()});
        // // logger.debug("{X}", .{readDataByte()});
        // // logger.debug("{X}", .{readDataByte()});
        // logger.debug("{X}", .{port.readByteTimeout(100)});
        // logger.debug("{X}", .{port.readByteTimeout(100)});
        // logger.debug("{X}", .{port.readByteTimeout(100)});
        // logger.debug("{X}", .{port.readByteTimeout(100)});
        // if (true) break :blk false;
        if (port.sendCommonCommand(.Identify) != .Acknowledged) break :blk false;
        const one: u16 = port.readByteTimeout(100) orelse 0x100;
        const two: u16 = if (one == 0x100) 0x100 else
            @as(u16, port.readByteTimeout(100) orelse 0x100);
        if (one == 0x100 and two == 0x100) {
            logger.err("Ancient AT keyboard support unimplemented", .{});
            break :blk false;
        } else if (one == 0x00 and two == 0x100) {
            logger.err("Standard PS/2 mouse support unimplemented", .{});
            break :blk false;
        } else if (one == 0x03 and two == 0x100) {
            logger.err("Mouse with scroll wheel support unimplemented", .{});
            break :blk false;
        } else if (one == 0x04 and two == 0x100) {
            logger.err("5-button mouse support unimplemented", .{});
            break :blk false;
        } else if (one == 0xAB and (two == 0x41 or two == 0xC1)) {
            logger.err("Standard keyboard with translation support unimplemented", .{});
            break :blk false;
        } else if (one == 0xAB and two == 0x83) {
            logger.debug("Standard MF2 keyboard found", .{});
            keyboard = try Ps2Keyboard.init(port);
            logger.debug("Initialised keyboard driver", .{});
        } else {
            logger.err("Unknown PS/2 device type: 0x{X} 0x{X}", .{one, two});
        }
        // while (true) {
        //     port_1_byte = null;
        //     asm volatile ("sti; hlt; cli");
        //     if (port_1_byte) |byte| {
        //         logger.debug("Received byte: 0x{X}", .{byte});
        //     }
        // }
        break :blk true;
    } else false;
    if (!port_1_enabled) logger.debug("Port 1 not enabled", .{});
}
