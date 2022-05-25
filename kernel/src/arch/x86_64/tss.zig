//! Kernel handling of the Task State Segment structure

const DescriptorTablePointer = @import("common.zig").DescriptorTablePointer;
const gdt_module = @import("gdt.zig");

pub const TaskStateSegment = packed struct {
    reserved_1: u32,
    privilege_stack_table: [3]u64,
    reserved_2: u64,
    interrupt_stack_table: [7]u64,
    reserved_3: u64,
    reserved_4: u16,
    iomap_base: u16,

    const Self = @This();

    pub fn new() Self {
        return Self{
            .privilege_stack_table = [1]u64{0} ** 3,
            .interrupt_stack_table = [1]u64{0} ** 7,
            .iomap_base = 0,
            .reserved_1 = 0,
            .reserved_2 = 0,
            .reserved_3 = 0,
            .reserved_4 = 0,
        };
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

var tss: TaskStateSegment = undefined;

fn getStackEnd(stack: []align(16) u8) usize {
    return (@ptrToInt(stack.ptr) + stack.len) & ~@as(u64, 0xF);
}

pub fn initTss() *const TaskStateSegment {
    tss = TaskStateSegment.new();
    tss.privilege_stack_table[0] = getStackEnd(&system_call_stack);
    tss.interrupt_stack_table[@enumToInt(IstIndex.GenericStack)] = getStackEnd(&generic_stack);
    tss.interrupt_stack_table[@enumToInt(IstIndex.DoubleFault)] = getStackEnd(&double_fault_stack);
    tss.interrupt_stack_table[@enumToInt(IstIndex.PageFault)] = getStackEnd(&page_fault_stack);
    tss.interrupt_stack_table[@enumToInt(IstIndex.GeneralProtectionFault)] =
        getStackEnd(&general_protection_fault_stack);
    return &tss;
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
    _ = initTss();
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
