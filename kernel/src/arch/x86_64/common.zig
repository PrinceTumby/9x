const platform = @import("root").arch.platform;

// Ideally this will be automated in the future, but currently changing the layout of
// this struct also requires changes to definitions in the following files (with paths
// starting at kernel directory):
// `src/arch/x86_64/init.s`
// `boot/efi/src/x86_64.zig`
/// Arguments passed to the kernel by the core loader
pub const KernelArgs = extern struct {
    kernel_elf: extern struct {
        ptr: [*]const u8,
        len: usize,
    },
    page_table_ptr: *[512]u64,
    environment: extern struct {
        ptr: [*]const u8,
        len: usize,
    },
    memory_map: extern struct {
        /// Pointer to the start of the memory map
        ptr: [*]u8,
        /// Size of the memory map in bytes
        size: usize,
        /// Size of area represented by map
        mapped_size: usize,
    },
    initrd: extern struct {
        ptr: [*]const u8,
        size: usize,
    },
    arch: extern struct {
        efi_ptr: ?[*]const u8,
        acpi_ptr: ?*platform.acpi.Rsdp,
        mp_ptr: ?[*]const u8,
        smbi_ptr: ?[*]const u8,
    },
    // fb: Framebuffer,
    framebuffers: extern struct {
        ptr: [*]const Framebuffer,
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

        pub const ColorFormat = extern enum(u32) {
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

// Internal x86_64 common functionality

pub const DescriptorTablePointer = packed struct {
    /// Size of the DT
    limit: u16,
    /// Pointer to the DT
    base: u64,
};

pub const msr = struct {
    pub inline fn read(msr_index: u32) u64 {
        return asm (
            \\rdmsr
            \\shlq $32, %%rdx
            \\orq %%rax, %%rdx
            : [out] "={rdx}" (-> u64)
            : [msr_index] "{ecx}" (msr_index)
            : "eax"
        );
    }

    pub inline fn write(msr_index: u32, value: u64) void {
        asm volatile ("wrmsr"
            :
            : [msr_index] "{ecx}" (msr_index),
              [low] "{eax}" (@truncate(u32, value)),
              [high] "{edx}" (@truncate(u32, value >> 32))
        );
    }

    // MSRs
    pub const fs_base: u32 = 0xC000_0100;
    pub const gs_base: u32 = 0xC000_0101;
    pub const kernel_gs_base: u32 = 0xC000_0102;
    pub const EFER: u32 = 0xC000_0080;
    pub const IA32_STAR: u32 = 0xC000_0081;
    pub const IA32_LSTAR: u32 = 0xC000_0082;
    pub const IA32_CSTAR: u32 = 0xC000_0083;
    pub const IA32_FMASK: u32 = 0xC000_0084;
};

pub const port = struct {
    pub inline fn readByte(port_num: u16) u8 {
        return asm volatile (
            "inb %[port], %[out]"
            : [out] "={al}" (-> u8)
            : [port] "{dx}" (port_num)
        );
    }

    pub inline fn writeByte(port_num: u16, byte: u8) void {
        asm volatile (
            "outb %[byte], %[port]"
            :
            : [byte] "{al}" (byte),
              [port] "{dx}" (port_num)
        );
    }

    pub const ps2_data: u16 = 0x60;
    pub const ps2_status: u16 = 0x64;
    pub const ps2_command: u16 = 0x64;
};

pub inline fn waitForInterrupt() void {
    asm volatile ("hlt");
}
