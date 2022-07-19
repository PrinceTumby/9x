pub const KernelArgs = extern struct {
    kernel_elf: extern struct {
        ptr: [*]const u8,
        len: usize,
    },

    pub const PtrType = enum(u32) {
        Physical,
        Linear,
    };

    pub const Framebuffer = extern struct {
        ptr: ?[*]volatile u8,
        ptr_type: PtrType = .Physical,
        size: u32,
        width: u32,
        height: u32,
        scanline: u32,
        color_format: ColorFormat,
        /// Bitmasks for specifying color positions in u32.
        /// All values are undefined if color_info_format != .Bitmask
        color_bitmask: ColorBitmask = undefined,

        pub const ColorFormat = enum(u32) {
            /// Red, Green, Blue, Reserved - 8 bits per color, 32 BPP
            RGBR8,
            /// Blue, Green, Red, Reserved - 8 bits per color, 32 BPP
            BGRR8,
            /// Red, Green, Blue - 8 bits per color, 24 BPP
            RGB8,
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
    asm volatile ("wfe");
}
