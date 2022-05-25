//! Types for the Global Descriptor Table and related concepts

// TODO Clean this up, document what GDT flags are for

const DescriptorTablePointer = @import("common.zig").DescriptorTablePointer;
const tss_module = @import("tss.zig");
const TaskStateSegment = tss_module.TaskStateSegment;

pub const SegmentSelector = packed struct {
    rpl: u4,
    index: u12,

    const Self = @This();

    pub fn new(index: u12, rpl: u4) Self {
        return Self{
            .rpl = rpl,
            .index = index,
        };
    }
};

pub const Descriptor = union(enum) {
    user_segment: u64,
    system_segment: [2]u64,

    const Self = @This();

    pub const Flags = struct {
        pub const accessed: u64 = 1 << 40;
        pub const writable: u64 = 1 << 41;
        pub const conforming: u64 = 1 << 42;
        pub const executable: u64 = 1 << 43;
        pub const user_segment_flag: u64 = 1 << 44;
        pub const dpl_ring_3: u64 = 3 << 45;
        pub const present: u64 = 1 << 47;
        pub const available: u64 = 1 << 52;
        pub const long_mode: u64 = 1 << 53;
        pub const default_size: u64 = 1 << 54;
        pub const granularity: u64 = 1 << 55;
        pub const limit_0_15: u64 = 0xFFFF;
        pub const limit_16_19: u64 = 0xF << 48;
        pub const base_0_23: u64 = 0xFF_FFFF << 16;
        pub const base_24_31: u64 = 0xFF << 56;
        
        // zig fmt: off
        const common: u64 = user_segment_flag
            | present
            | writable
            | limit_0_15
            | limit_16_19
            | granularity;
        // zig fmt: on
        pub const kernel_data: u64 = common | default_size;
        pub const kernel_code_32: u64 = common | executable | default_size;
        pub const kernel_code_64: u64 = common | executable | long_mode;
        pub const user_data: u64 = kernel_data | dpl_ring_3;
        pub const user_code_32: u64 = kernel_code_32 | dpl_ring_3;
        pub const user_code_64: u64 = kernel_code_64 | dpl_ring_3;
    };

    pub fn kernelCodeSegment() Self {
        return Self{ .user_segment = Flags.kernel_code_64 };
    }

    pub fn kernelDataSegment() Self {
        return Self{ .user_segment = Flags.kernel_data };
    }

    pub fn userDataSegment() Self {
        return Self{ .user_segment = Flags.user_data };
    }

    pub fn userCodeSegment() Self {
        return Self{ .user_segment = Flags.user_code_64 };
    }

    pub fn tssSegment(tss: *const TaskStateSegment) Self {
        const ptr = @ptrToInt(tss);
        var low = Flags.present;
        // Base
        low |= (ptr & 0xFFFFFF) << 16;
        low |= (ptr & 0xFF000000) << 32;
        // Limit
        low |= (@sizeOf(TaskStateSegment) - 1) & 0xFFFF;
        // Type
        low |= 0b1001 << 40;

        const high: u64 = (ptr & 0xFFFFFFFF00000000) >> 32;

        return Self{ .system_segment = [2]u64{ low, high } };
    }
};

var gdt: [9]u64 align(16) = [_]u64{
    // Null
    0x0001_0000_0000_FFFF,
    // Code
    Descriptor.Flags.kernel_code_64,
    // Data
    Descriptor.Flags.kernel_data,
    // TSS Lower
    0x0000_0000_0000_0000,
    // TSS Upper
    0x0000_0000_0000_0000,
    // Ring 3 32-Bit Code
    Descriptor.Flags.user_code_32,
    // Ring 3 Data for 32-Bit Code
    Descriptor.Flags.user_data,
    // Ring 3 64-Bit Code
    Descriptor.Flags.user_code_64,
    // Ring 3 Data for 64-Bit Code
    Descriptor.Flags.user_data,
};

pub const offset = struct {
    pub const kernel_code: u16 = 8;
    pub const kernel_data: u16 = 16;
    pub const tss: u16 = 24;
    pub const user_code_32: u16 = 40;
    pub const user_data_32: u16 = 48;
    pub const user_code_64: u16 = 56;
    pub const user_data_64: u16 = 64;
};

pub const index = struct {
    pub const kernel_code: u16 = 1;
    pub const kernel_data: u16 = 2;
    pub const tss: u16 = 3;
    pub const user_code_32: u16 = 5;
    pub const user_data_32: u16 = 6;
    pub const user_code_64: u16 = 7;
    pub const user_data_64: u16 = 8;
};

pub fn loadNoReloadSegmentDescriptors() void {
    var ptr: DescriptorTablePointer align(8) = DescriptorTablePointer{
        .base = @ptrToInt(&gdt),
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
    };
    asm volatile ("lgdt (%[ptr])" :: [ptr] "r" (&ptr) : "memory");
}

// pub fn reloadSegmentDescriptors() void {
//     asm volatile (
//         \\pushq $8
//         \\leaq cs_set(%%rip), %%rax
//         \\pushq %%rax
//         \\lretq
//         \\cs_set:
//         \\movw $16, %%ax
//         \\movw %%ax, %%ds
//         \\movw %%ax, %%es
//         \\movw %%ax, %%ss
//         :
//         :
//         : "rax", "memory"
//     );
// }
