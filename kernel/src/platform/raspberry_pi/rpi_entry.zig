const std = @import("std");
const root = @import("root");
const raspberry_pi = @import("../raspberry_pi.zig");
const mmio = @import("mmio.zig");
const atags = @import("atags.zig");

const logger = std.log.scoped(.raspberry_pi_entry);

fn unknownArchError(comptime arch: std.Target.Cpu.Arch) noreturn {
    comptime {
        @compileError("Unknown CPU architecture for Raspberry Pi - " ++ @tagName(arch));
    }
}

fn getRaspberryPiModel() ?raspberry_pi.Model {
    const part_num = (switch (std.builtin.cpu.arch) {
        .arm => asm ("mrc p15,0,%[out],c0,c0,0" : [out] "=r" (-> usize)),
        .aarch64 => asm ("mrs %[out], midr_el1" : [out] "=r" (-> usize)),
        else => |arch| unknownArchError(arch),
    } >> 4) & 0xFFF;
    return switch (part_num) {
        0xB76 => .one,
        0xC07 => .two,
        0xD03 => .three,
        0xD08 => .four,
        else => null,
    };
}

fn entrypoint32(_r0: usize, _r1: usize, atags_ptr: ?*atags.TagHeader) callconv(.C) void {
    // Get MMIO base address for board
    const model = getRaspberryPiModel() orelse .one;
    mmio.init(model);
    // Enable serial debugging
    mmio.uart.init(model);
    if (model == .zero or model == .one) root.smp.SpinLock.changeFns(false);
    raspberry_pi.loggers.logger_enabled_list[0] = true;
    logger.debug("Hello, world!", .{});
    logger.debug("r0: 0x{X}, r1: 0x{X}, ATAGS: {*}", .{_r0, _r1, atags_ptr});
    const tags = mmio.mailbox.arm_vc_property_tags.initFramebuffer(
        1920,
        1080,
        32,
    ) catch |err| {
        logger.emerg("Got {}", .{err});
        @panic("error initialising framebuffer");
    };
    logger.debug(
        \\Framebuffer:
        \\  Buffer: ptr=0x{X}, len={}
        \\  Virtual Dims: width={}, height={}
        \\  BPP: {}
        \\  Pixel Order: {}
        \\  Alpha Mode: {}
        \\  Pitch: {}
        \\  Virtual Offset: x={}, y={}
        \\  Overscan: top={}, bottom={}, left={}, right={}
        , .{
            tags.allocate.alignment_or_framebuffer_base,
            tags.allocate.framebuffer_size,
            tags.virt_dims.width,
            tags.virt_dims.height,
            tags.depth.bpp,
            tags.pixel_order.order,
            tags.alpha_mode.mode,
            tags.pitch.pitch,
            tags.virtual_offset.x,
            tags.virtual_offset.y,
            tags.overscan.top,
            tags.overscan.bottom,
            tags.overscan.left,
            tags.overscan.right,
        }
    );
    while (true) {}
}

fn entrypoint64(dtb_ptr: usize, _x1: usize, _x2: usize, _x3: usize) callconv(.C) noreturn {
    // Setup MMIO for Raspberry Pi 3
    const model = getRaspberryPiModel() orelse @panic("Unknown RPi model");
    mmio.init(model);
    // Enable serial debugging
    mmio.uart0.init(model);
    raspberry_pi.loggers.logger_enabled_list[0] = true;
    logger.debug("Hello, world!", .{});
    while (true) {}
}

comptime {
    switch (std.builtin.cpu.arch) {
        .arm => @export(entrypoint32, .{ .name = "rpi_entrypoint", .linkage = .Strong }),
        .aarch64 => @export(entrypoint64, .{ .name = "rpi_entrypoint", .linkage = .Strong }),
        else => |arch| unknownArchError(arch),
    }
}
