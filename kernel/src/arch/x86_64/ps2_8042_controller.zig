const port = @import("common.zig").port;
const logger = @import("std").log.scoped(.ps2);

pub const status_flags = struct {
    pub const output_buffer_full: u8 = 1;
    pub const input_buffer_full: u8 = 1 << 1;
    pub const system_flag: u8 = 1 << 2;
    pub const data_or_command: u8 = 1 << 3;
    pub const timeout_error: u8 = 1 << 6;
    pub const parity_error: u8 = 1 << 7;
};

pub const Command = enum(u8) {
    ReadControllerConfigByte = 0x20,
    WriteControllerConfigByte = 0x60,
    DisablePort2 = 0xA7,
    EnablePort2 = 0xA8,
    /// Responds 0x00 if the test passed, 0x01...0x04 if the test failed
    TestPort2 = 0xA9,
    /// Responds 0x55 if the test passed, 0xFC if the test failed
    TestController = 0xAA,
    /// Responds 0x00 if the test passed, 0x01...0x04 if the test failed
    TestPort1 = 0xAB,
    DisablePort1 = 0xAD,
    EnablePort1 = 0xAE,
    /// Responds with the Controller Output Port byte
    ReadOutputPort = 0xC0,
    /// Writes the next byte sent to the Controller Output Port
    WriteOutputPort = 0xD1,
    /// Writes the next byte sent to port 2
    WritePort2 = 0xD4,
    ResetCpu = 0xFE,
};

pub inline fn resetCpu() noreturn {
    sendCommand(.ResetCpu);
    @panic("We're still here?");
}

pub inline fn readStatus() u8 {
    return port.readByte(port.ps2_status);
}

pub inline fn sendCommand(command: Command) void {
    port.writeByte(port.ps2_command, @enumToInt(command));
}

pub inline fn readDataByte() u8 {
    // Wait for output buffer to fill
    while (readStatus() & status_flags.output_buffer_full == 0) {}
    // Read data byte
    return port.readByte(port.ps2_data);
}

pub inline fn sendDataByte(byte: u8) void {
    // Wait for input buffer to clear
    while (readStatus() & status_flags.input_buffer_full != 0) {}
    // Send data byte
    port.writeByte(port.ps2_data, byte);
}

pub fn setInterruptMasks(port_1_interrupts: bool, port_2_interrupts: bool) void {
    sendCommand(.ReadControllerConfigByte);
    const original_config = readDataByte();
    const port_1_mask: u8 = if (port_1_interrupts) 0b01 else 0;
    const port_2_mask: u8 = if (port_2_interrupts) 0b10 else 0;
    sendCommand(.WriteControllerConfigByte);
    sendDataByte((original_config & 0b11111100) | port_1_mask | port_2_mask);
}

pub const PortInformation = struct {
    port_1_working: bool = false,
    port_2_working: bool = false,
};

pub fn tryInit() PortInformation {
    logger.debug("Status register: {b:0>8}", .{readStatus()});
    // Disable PS/2 ports
    sendCommand(.DisablePort1);
    sendCommand(.DisablePort2);
    // Flush output buffer
    while (readStatus() & status_flags.output_buffer_full != 0) {
        _ = port.readByte(port.ps2_data);
    }
    // Read Controller Configuration Byte, initial check for two ports
    sendCommand(.ReadControllerConfigByte);
    const controller_config_byte = readDataByte();
    var port_2_exists: bool = controller_config_byte & (1 << 5) != 0;
    const fixed_controller_config_byte = controller_config_byte & 0b00110100;
    // Disable port interrupts, disable translation
    sendCommand(.WriteControllerConfigByte);
    sendDataByte(fixed_controller_config_byte);
    // Perform controller self test
    sendCommand(.TestController);
    const controller_test_result = readDataByte();
    if (controller_test_result != 0x55) return .{};
    logger.debug("Tested controller: received 0x{X}", .{controller_test_result});
    // Check if there are two ports
    if (port_2_exists) {
        sendCommand(.EnablePort2);
        sendCommand(.ReadControllerConfigByte);
        port_2_exists = readDataByte() & (1 << 5) == 0;
        sendCommand(.DisablePort2);
    }
    if (port_2_exists)
        logger.debug("Port 2 exists", .{})
    else
        logger.debug("Port 2 does not exist", .{});
    var port_info = PortInformation {};
    sendCommand(.TestPort1);
    port_info.port_1_working = readDataByte() == 0x00;
    if (port_2_exists) {
        sendCommand(.TestPort2);
        port_info.port_2_working = readDataByte() == 0x00;
    }
    return port_info;
}
