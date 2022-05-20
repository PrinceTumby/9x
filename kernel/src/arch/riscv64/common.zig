pub const KernelArgs = extern struct {
    kernel_elf: extern struct {
        ptr: [*]const u8,
        len: usize,
    },

    pub const Framebuffer = extern struct {
        ptr: ?[*]volatile u32,
        size: u32,
        width: u32,
        height: u32,
        scanline: u32,
        color_format: ColorFormat,
        /// Bitmasks for specifying color positions in u32.
        /// All values are undefined if color_info_format != .Bitmask
        color_bitmask: ColorBitmask = undefined,

        pub const ColorFormat = enum(u32) {
            /// Red, Green, Blue, Reserved - 8 bits per color
            RGBR8,
            /// Blue, Green, Red, Reserved - 8 bits per color
            BGRR8,
            Bitmask,
        };

        /// Bitmasks for specifying color positions in u32.
        /// All values are undefined if color_format != .Bitmask
        pub const ColorBitmask = extern struct {
            red_mask: u32,
            green_mask: u32,
            blue_mask: u32,
            reserved_mask: u32,
        };
    };
};

pub inline fn waitForInterrupt() void {
    asm volatile ("wfi");
}
