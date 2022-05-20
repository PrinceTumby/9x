// Core graphics primitives for drawing to the frame buffer
const FramebufferArgs = @import("root").KernelArgs.Framebuffer;

pub const FrameBuffer = struct {
    __fb: []volatile u8,
    width: u32,
    height: u32,
    scanline: u32,
    format: FramebufferArgs.ColorFormat,

    pub fn copy(
        self: *FrameBuffer,
        src_x: u32,
        src_y: u32,
        width: u32,
        height: u32,
        dst_x: u32,
        dst_y: u32,
    ) void {
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                if (dst_x + x >= self.width or
                    dst_y + y >= self.height)
                {
                    @panic("copy failure");
                }
                self.set(dst_x + x, dst_y + y, self.get(src_x + x, src_y + y));
            }
        }
    }

    pub fn fill(self: *FrameBuffer, x: u32, y: u32, end_x: u32, end_y: u32, val: u32) void {
        if (end_x >= self.width or end_y >= self.height) @panic("framebuffer fill incorrect args");
        var cur_y: u32 = y;
        while (cur_y < end_y) : (cur_y += 1) {
            var cur_x: u32 = x;
            while (cur_x < end_x) : (cur_x += 1) {
                self.set(cur_x, cur_y, val);
            }
        }
    }

    pub fn draw_box(self: *FrameBuffer, x: u32, y: u32, width: u32, height: u32, val: u32) void {
        const x_max: u32 = x + width;
        const y_max: u32 = y + height;
        var cur_y: u32 = y;
        while (cur_y < y_max) : (cur_y += 1) {
            var cur_x: u32 = x;
            while (cur_x < x_max) : (cur_x += 1) {
                if (cur_x >= self.width or cur_y >= self.height) @panic("draw failure");
                self.set(cur_x, cur_y, val);
            }
        }
    }

    pub inline fn set(self: *FrameBuffer, x: u32, y: u32, val: u32) void {
        const pixel_start = 4 * ((y * self.scanline) + x);
        self.__fb[pixel_start + 0] = @truncate(u8, val >> 0);
        self.__fb[pixel_start + 1] = @truncate(u8, val >> 8);
        self.__fb[pixel_start + 2] = @truncate(u8, val >> 16);
        // self.__fb[pixel_start + 3] = 0xFF;
        // self.__fb[(y * self.scanline) + x] = val;
    }

    pub inline fn get(self: FrameBuffer, x: u32, y: u32) u32 {
        const pixel_start = 4 * ((y * self.scanline) + x);
        return @as(u32, self.__fb[pixel_start + 0])
            | (@as(u32, self.__fb[pixel_start + 1]) << 8)
            | (@as(u32, self.__fb[pixel_start + 2]) << 16);
    }

    pub fn init(args: FramebufferArgs) FrameBuffer {
        return FrameBuffer{
            .__fb = args.ptr.?[0..args.size],
            .width = args.width,
            .height = args.height,
            .scanline = args.scanline,
            .format = args.color_format,
        };
    }
};
