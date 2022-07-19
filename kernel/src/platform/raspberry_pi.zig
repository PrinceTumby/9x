// Platform internal support

pub const mmio = @import("raspberry_pi/mmio.zig");
pub const serial = @import("raspberry_pi/serial.zig");

pub const Model = enum {
    zero,
    one,
    two,
    three,
    four,
};

// Platform specific kernel feature implementation

pub const loggers = struct {
    pub const logger_list = .{
        serial.Writer(mmio.uart0){},
    };
    pub var logger_enabled_list = [_]bool{
        false,
    };
};

// Boot stubs

const rpi_entry = @import("raspberry_pi/rpi_entry.zig");
comptime {
    _ = rpi_entry;
}
