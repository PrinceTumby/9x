//! Kernel handling of the Task State Segment structure

const std = @import("std");
const common = @import("common.zig");
const DescriptorTablePointer = common.DescriptorTablePointer;
const gdt_module = @import("gdt.zig");

pub const TaskStateSegment = packed struct {
    reserved_1: u32 = 0,
    privilege_stack_table: [3]u64 = [1]u64{0} ** 3,
    reserved_2: u64 = 0,
    interrupt_stack_table: [7]u64 = [1]u64{0} ** 7,
    reserved_3: u64 = 0,
    reserved_4: u16 = 0,
    iopb_base: u16 = @byteOffsetOf(TaskStateSegment, "iopb") +
        @byteOffsetOf(IoPermissionBitmap, "map"),
    iopb: IoPermissionBitmap = .{},
};

pub const IoPermissionBitmap = extern struct {
    map: [8192]u8 = [1]u8{std.math.maxInt(u8)} ** 8192,

    pub inline fn allowPort(self: *IoPermissionBitmap, port_num: u16) void {
        const group_index = port_num / 8;
        const index_in_group = @truncate(u3, port_num % 8);
        const mask = ~(@as(u8, 1) << index_in_group);
        self.map[group_index] &= mask;
    }

    pub inline fn disallowPort(self: *IoPermissionBitmap, port_num: u16) void {
        const group_index = port_num / 8;
        const index_in_group = @truncate(u3, port_num % 8);
        const bit = @as(u8, 1) << index_in_group;
        self.map[group_index] |= bit;
    }
};

// Interrupt Stack Table stacks

pub const IstIndex = enum(u3) {
    GenericStack,
    DoubleFault,
    PageFault,
    GeneralProtectionFault,
};

var generic_stack: [4096]u8 align(16) = undefined;
var double_fault_stack: [4096]u8 align(16) = undefined;
var page_fault_stack: [4096]u8 align(16) = undefined;
var general_protection_fault_stack: [4096]u8 align(16) = undefined;

// Stack used for executing system calls
var system_call_stack: [4096]u8 align(16) = undefined;

pub var tss: TaskStateSegment = undefined;
pub const iopb_ptr = @alignCast(@alignOf(IoPermissionBitmap), &tss.iopb);

fn getStackEnd(stack: []align(16) u8) usize {
    return (@ptrToInt(stack.ptr) + stack.len) & ~@as(u64, 0xF);
}

fn initTss() void {
    tss = TaskStateSegment{};
    tss.privilege_stack_table[0] = getStackEnd(&system_call_stack);
    tss.interrupt_stack_table[@enumToInt(IstIndex.GenericStack)] = getStackEnd(&generic_stack);
    tss.interrupt_stack_table[@enumToInt(IstIndex.DoubleFault)] = getStackEnd(&double_fault_stack);
    tss.interrupt_stack_table[@enumToInt(IstIndex.PageFault)] = getStackEnd(&page_fault_stack);
    tss.interrupt_stack_table[@enumToInt(IstIndex.GeneralProtectionFault)] =
        getStackEnd(&general_protection_fault_stack);
}

pub fn loadTssIntoGdt() void {
    // Get GDT
    var ptr: DescriptorTablePointer align(8) = DescriptorTablePointer{
        .base = 0,
        .limit = 0,
    };
    asm volatile ("sgdt (%[ptr])" :: [ptr] "r" (&ptr) : "memory");
    const gdt = @intToPtr(*[8]u64, ptr.base);
    // Load TSS into GDT
    initTss();
    const tss_descriptor = gdt_module.Descriptor.tssSegment(&tss).system_segment;
    gdt[gdt_module.offset.tss / 8] = tss_descriptor[0];
    gdt[gdt_module.offset.tss / 8 + 1] = tss_descriptor[1];
    // Reload GDT
    asm volatile ("lgdt (%[ptr])" :: [ptr] "r" (&ptr) : "memory");
    // Reload segment descriptors and TSS
    asm volatile (
        \\pushq $8
        \\leaq cs_set(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\cs_set:
        \\movw $16, %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%ss
        \\movw $24, %%ax
        \\ltr %%ax
        :
        :
        : "rax", "memory"
    );
}
