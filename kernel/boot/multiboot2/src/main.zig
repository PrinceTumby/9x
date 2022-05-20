const std = @import("std");
const logging = @import("logging.zig");
const mb = @import("multiboot2.zig");

// const kernel: []const u8 = @embedFile("../../../out/kernel");

// Logging
pub const log = logging.log;
pub const log_level: std.log.Level = .debug;
const logger = std.log.scoped(.main);

pub fn bochsBreakpoint() void {
    asm volatile ("xchgw %%bx, %%bx");
}

var stack_bytes: [4096]u8 align(16) = undefined;

export fn multiboot_main(multiboot_info: *mb.BootInformation) noreturn {
    bochsBreakpoint();
    var current_tag_address = @ptrToInt(&multiboot_info.first_tag);
    var current_tag = @intToPtr(*mb.tag.Basic, current_tag_address);
    while (!current_tag.isEndTag()) : ({
        current_tag_address = std.mem.alignForward(current_tag_address + current_tag.tag_size, 8);
        current_tag = @intToPtr(*mb.tag.Basic, current_tag_address);
    }) {
        logger.debug("Found tag: {}", .{current_tag.*});
    }
    while (true) bochsBreakpoint();
}
