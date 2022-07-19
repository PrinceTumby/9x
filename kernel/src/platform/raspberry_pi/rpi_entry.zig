const std = @import("std");
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

const MMIO_BASE: usize = 0x20000000;
const GPFSEL0 = @intToPtr(*volatile u32, MMIO_BASE+0x00200000);
const GPFSEL1 = @intToPtr(*volatile u32, MMIO_BASE+0x00200004);
const GPFSEL2 = @intToPtr(*volatile u32, MMIO_BASE+0x00200008);
const GPFSEL3 = @intToPtr(*volatile u32, MMIO_BASE+0x0020000C);
const GPFSEL4 = @intToPtr(*volatile u32, MMIO_BASE+0x00200010);
const GPFSEL5 = @intToPtr(*volatile u32, MMIO_BASE+0x00200014);
const GPSET0 = @intToPtr(*volatile u32, MMIO_BASE+0x0020001C);
const GPSET1 = @intToPtr(*volatile u32, MMIO_BASE+0x00200020);
const GPCLR0 = @intToPtr(*volatile u32, MMIO_BASE+0x00200028);
const GPLEV0 = @intToPtr(*volatile u32, MMIO_BASE+0x00200034);
const GPLEV1 = @intToPtr(*volatile u32, MMIO_BASE+0x00200038);
const GPEDS0 = @intToPtr(*volatile u32, MMIO_BASE+0x00200040);
const GPEDS1 = @intToPtr(*volatile u32, MMIO_BASE+0x00200044);
const GPHEN0 = @intToPtr(*volatile u32, MMIO_BASE+0x00200064);
const GPHEN1 = @intToPtr(*volatile u32, MMIO_BASE+0x00200068);
const GPPUD = @intToPtr(*volatile u32, MMIO_BASE+0x00200094);
const GPPUDCLK0 = @intToPtr(*volatile u32, MMIO_BASE+0x00200098);
const GPPUDCLK1 = @intToPtr(*volatile u32, MMIO_BASE+0x0020009C);
const UART0_DR = @intToPtr(*volatile u32, MMIO_BASE+0x00201000);
const UART0_FR = @intToPtr(*volatile u32, MMIO_BASE+0x00201018);
const UART0_IBRD = @intToPtr(*volatile u32, MMIO_BASE+0x00201024);
const UART0_FBRD = @intToPtr(*volatile u32, MMIO_BASE+0x00201028);
const UART0_LCRH = @intToPtr(*volatile u32, MMIO_BASE+0x0020102C);
const UART0_CR = @intToPtr(*volatile u32, MMIO_BASE+0x00201030);
const UART0_IMSC = @intToPtr(*volatile u32, MMIO_BASE+0x00201038);
const UART0_ICR = @intToPtr(*volatile u32, MMIO_BASE+0x00201044);
const AUX_ENABLE = @intToPtr(*volatile u32, MMIO_BASE+0x00215004);
const MBOX_READ = @intToPtr(*volatile u32, MMIO_BASE+0x0000B880+0x0);
const MBOX_WRITE = @intToPtr(*volatile u32, MMIO_BASE+0x0000B880+0x20);
const MBOX_STATUS = @intToPtr(*volatile u32, MMIO_BASE+0x0000B880+0x18);

const MBOX_FULL = 0x80000000;
const MBOX_EMPTY = 0x40000000;

pub const mbox align(16) = [9]u32{
    8 * 4,
    0,
    0x38002,
    12,
    8,
    2,
    4000000,
    0,
    0,
};

fn uartSend(c: u8) void {
    while (UART0_FR.* & 0x20 != 0) asm volatile ("nop");
    UART0_DR.* = c;
}

fn uartGetC() u8 {
    while (UART0_FR.* & 0x10 != 0) asm volatile ("nop");
    return @truncate(u8, UART0_DR.*);
}

inline fn delay(count: usize) void {
    var i = count;
    while (i > 0) : (i -= 1) asm volatile("nop");
}

fn entrypoint32(_r0: usize, _r1: usize, atags_ptr: ?*atags.TagHeader) callconv(.C) noreturn {
    const mbox_r = (@truncate(u32, @ptrToInt(&mbox)) & ~@as(u32, 0xF)) | 8;
    UART0_CR.* = 0;
    AUX_ENABLE.* = 0;
    while (MBOX_STATUS.* & MBOX_FULL != 0) asm volatile ("nop");
    MBOX_WRITE.* = mbox_r;
    while (MBOX_STATUS.* & MBOX_EMPTY != 0 or mbox_r != MBOX_READ.*) asm volatile ("nop");
    var r = GPFSEL1.*;
    r &= ~@as(u32, (7 << 12) | (7 << 15));
    r |= (4 << 12) | (4 << 15);
    GPFSEL1.* = r;
    GPPUD.* = 0;
    delay(150);
    GPPUDCLK0.* = (1 << 14) | (1 << 15);
    delay(150);
    GPPUDCLK0.* = 0;
    UART0_ICR.* = 0x7FF;
    UART0_IBRD.* = 2;
    UART0_FBRD.* = 0xB;
    UART0_LCRH.* = 0x3 << 5;
    UART0_CR.* = 0x301;
    uartSend('T');
    uartSend('E');
    uartSend('S');
    uartSend('T');
    uartSend('\r');
    uartSend('\n');
    while (true) {}
}

// fn entrypoint32(_r0: usize, _r1: usize, atags_ptr: ?*atags.TagHeader) callconv(.C) noreturn {
//     // Setup MMIO
//     // const model = getRaspberryPiModel() orelse @panic("Unknown RPi model");
//     const model = getRaspberryPiModel() orelse .one;
//     mmio.init(model);
//     // Enable serial debugging
//     mmio.uart0.init(model);
//     raspberry_pi.loggers.logger_enabled_list[0] = true;
//     logger.debug("Hello, world!", .{});
//     logger.debug("r0: 0x{X}, r1: 0x{X}, ATAGS: {*}", .{_r0, _r1, atags_ptr});
//     // atags.parse(@intToPtr(*atags.TagHeader, 0x100));
//     // const framebuffer_info = mmio.mailbox.framebuffer_old.init(1920, 1080, 24);
//     // const framebuffer_ptr = framebuffer_info.ptr orelse @panic("No framebuffer pointer");
//     // {
//     //     var x: usize = 200;
//     //     while (x < 4000) : (x += 1) {
//     //         framebuffer_ptr[115_200 + x] = 0xFF;
//     //     }
//     // }
//     // {
//     //     var x: usize = 200;
//     //     while (x < 4000) : (x += 1) {
//     //         framebuffer_ptr[230_400 + x] = 0xFF;
//     //     }
//     // }
//     // const Framebuffer = @import("root").Framebuffer;
//     // var fb = Framebuffer.init(.{
//     //     .ptr = framebuffer_info.ptr orelse @panic("FB ptr null"),
//     //     .ptr_type = .Linear,
//     //     .size = framebuffer_info.size,
//     //     .width = framebuffer_info.virtual_width,
//     //     .height = framebuffer_info.virtual_height,
//     //     .scanline = framebuffer_info.pitch / 3,
//     //     .color_format = .RGB8,
//     // });
//     while (true) {}
// }

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
