const root = @import("root");
const tls = @import("tls.zig");
const platform = root.arch.platform;
const comptimeFmt = root.zig_extensions.comptimeFmt;
const UserProcess = root.process.UserProcess;
const ThreadLocalVariables = tls.ThreadLocalVariables;

pub const page_size = 4096;

// Ideally this will be automated in the future, but currently changing the layout of
// this struct also requires changes to definitions in the following files (with paths
// starting at kernel directory):
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
        /// Length of the memory map in bytes
        len: usize,
        /// Size of area represented by map
        mapped_size: usize,
    },
    initrd: extern struct {
        ptr: [*]const u8,
        len: usize,
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

    // Export offset of page table ptr in kernel arguments for assembly
    comptime {
        asm (comptimeFmt(
            0,
            \\.global KernelArgs.page_table_ptr
            \\KernelArgs.page_table_ptr = {}
            , .{@byteOffsetOf(KernelArgs, "page_table_ptr")}
        ));
    }

    pub const PtrType = enum(u32) {
        Physical,
        Linear,
    };

    pub const Framebuffer = extern struct {
        ptr: [*]volatile u32,
        ptr_type: PtrType = .Physical,
        size: u32,
        width: u32,
        height: u32,
        scanline: u32,
        color_format: ColorFormat = .BGRR8,
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

pub const process = struct {
    pub const RegisterStore = extern struct {
        rax: u64 = 0,
        rbx: u64 = 0,
        rcx: u64 = 0,
        rdx: u64 = 0,
        rsi: u64 = 0,
        rdi: u64 = 0,
        rbp: u64 = 0,
        rsp: u64 = 0,
        r8: u64 = 0,
        r9: u64 = 0,
        r10: u64 = 0,
        r11: u64 = 0,
        r12: u64 = 0,
        r13: u64 = 0,
        r14: u64 = 0,
        r15: u64 = 0,
        rip: u64 = 0,
        rflags: u64 = 0x202,
        fs: u64 = 0,
        gs: u64 = 0,
        fxsave_area: [32]u128 = [1]u128{0} ** 32,

        pub const start_register_offset = @byteOffsetOf(RegisterStore, "rax");
        pub const end_register_offset = @byteOffsetOf(RegisterStore, "gs");
        pub const vector_store_offset = @byteOffsetOf(RegisterStore, "fxsave_area");

        pub const RegisterOverrides = struct {
            instruction_pointer: u64 = 0,
            stack_pointer: u64 = 0,
        };

        pub fn init(register_overrides: RegisterOverrides) RegisterStore {
            return RegisterStore{
                .rip = register_overrides.instruction_pointer,
                .rbp = register_overrides.stack_pointer,
                .rsp = register_overrides.stack_pointer,
            };
        }
    };

    pub const KernelMainRegisterStore = extern struct {
        rbx: u64 = undefined,
        rcx: u64 = undefined,
        rdx: u64 = undefined,
        rbp: u64 = undefined,
        rsp: u64 = undefined,
        r8: u64 = undefined,
        r9: u64 = undefined,
        r12: u64 = undefined,
        r13: u64 = undefined,
        r14: u64 = undefined,
        r15: u64 = undefined,
        rip: u64 = undefined,
        fs: u64 = undefined,
        fxsave_area: [32]u128 = undefined,

        pub const start_register_offset = @byteOffsetOf(KernelMainRegisterStore, "rbx");
        pub const end_register_offset = @byteOffsetOf(KernelMainRegisterStore, "fs");
        pub const vector_store_offset = @byteOffsetOf(KernelMainRegisterStore, "fxsave_area");
    };

    pub const highest_user_address: usize = 0x00007fffffffffff;

    /// 4GiB stack size
    pub const stack_size_limit: usize = 1 << 32;

    pub const highest_program_segment_address: usize = highest_user_address - stack_size_limit;

    pub fn isUserAddressValid(address: usize) bool {
        return address < highest_user_address;
    }

    pub fn isProgramSegmentAddressValid(address: usize) bool {
        return address < highest_program_segment_address;
    }
};
