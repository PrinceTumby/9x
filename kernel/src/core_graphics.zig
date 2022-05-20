// Core graphics primitives for drawing to the frame buffer

const std = @import("std");
const root = @import("root");
const PageTableEntry = root.arch.paging.PageTableEntry;
const FramebufferArgs = root.KernelArgs.Framebuffer;
const page_allocator = root.arch.page_allocation.page_allocator_ptr;

pub const FrameBuffer = struct {
    fb: []volatile u32,
    width: u32,
    height: u32,
    scanline: u32,
    format: FramebufferArgs.ColorFormat,
    manual_painting: bool = true,
    buffer_dirty: bool = false,

    pub fn init(args: FramebufferArgs) !FrameBuffer {
        const size: u32 = args.height * args.scanline;
        const fb_phys_addr = @ptrToInt(args.ptr);
        // Map the framebuffer in upper memory with write combining flags
        try page_allocator.offsetMapMem(
            fb_phys_addr,
            @ptrToInt(&root.FRAMEBUFFER_START),
            PageTableEntry.framebuffer_flags,
            size * 4,
        );
        return FrameBuffer{
            .fb = @ptrCast([*]volatile u32, &root.FRAMEBUFFER_START)[0..size],
            .width = args.width,
            .height = args.height,
            .scanline = args.scanline,
            .format = args.color_format,
        };
    }

    /// Clears the screen to all black
    pub fn clear(self: *FrameBuffer) void {
        for (self.fb) |*pixel| {
            pixel.* = 0;
        }
        self.buffer_dirty = false;
    }

    pub fn copy(
        self: *const FrameBuffer,
        src_x: u32,
        src_y: u32,
        width: u32,
        height: u32,
        dst_x: u32,
        dst_y: u32,
    ) void {
        // Bounds checks
        if (src_x + width > self.width or src_y + height > self.height) {
            @panic("fb copy: source rectangle out of bounds");
        }
        if (dst_x + width > self.width or dst_y + height > self.height) {
            @panic("fb copy: destination rectangle out of bounds");
        }
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                self.set(dst_x + x, dst_y + y, self.get(src_x + x, src_y + y));
            }
        }
    }

    pub fn fill(self: *const FrameBuffer, x: u32, y: u32, end_x: u32, end_y: u32, val: u32) void {
        if (end_x > self.width or end_y > self.height) @panic("framebuffer fill incorrect args");
        var cur_y: u32 = y;
        while (cur_y < end_y) : (cur_y += 1) {
            var cur_x: u32 = x;
            while (cur_x < end_x) : (cur_x += 1) {
                self.set(cur_x, cur_y, val);
            }
        }
    }

    pub fn drawBox(
        self: *const FrameBuffer,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        val: u32,
    ) void {
        const x_max: u32 = x + width;
        const y_max: u32 = y + height;
        var cur_y: u32 = y;
        while (cur_y < y_max) : (cur_y += 1) {
            var cur_x: u32 = x;
            while (cur_x < x_max) : (cur_x += 1) {
                self.set(cur_x, cur_y, val);
            }
        }
    }

    pub inline fn set(self: *const FrameBuffer, x: u32, y: u32, val: u32) void {
        @setRuntimeSafety(false);
        self.fb[y * self.scanline + x] = val;
    }

    pub inline fn get(self: *const FrameBuffer, x: u32, y: u32) u32 {
        @setRuntimeSafety(false);
        return self.fb[y * self.scanline + x];
    }
};
