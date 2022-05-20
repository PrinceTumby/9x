//! Interrupt handling tables and functions

const assertEqual = @import("root").misc.assertEqual;
const DescriptorTablePointer = @import("common.zig").DescriptorTablePointer;
const TaskStateSegment = @import("tss.zig").TaskStateSegment;

// Handler function types

pub const InterruptFrame = extern struct {
    instruction_ptr: usize,
    code_segment: usize,
    cpu_flags: usize,
    stack_ptr: usize,
    stack_segment: usize,
};

/// Handler function for an interrupt or exception without error code
pub const HandlerFunc = fn (interrupt_frame: *const InterruptFrame) callconv(.Interrupt) void;

/// Handler function for an interrupt or exception with error code
pub const HandlerFuncWithErrCode = fn (
    interrupt_frame: *const InterruptFrame,
    error_code: u32,
) callconv(.Interrupt) void;

/// Handler function for an interrupt or exception with page fault error code
pub const PageFaultHandlerFunc = HandlerFuncWithErrCode;

/// Handler function without error code that must not return
pub const DivergingHandlerFunc = fn (
    interrupt_frame: *const InterruptFrame,
) callconv(.Interrupt) noreturn;

/// Handler function with error code that must not return
pub const DivergingHandlerFuncWithErrCode = fn (
    interrupt_frame: *const InterruptFrame,
    error_code: u32,
) callconv(.Interrupt) noreturn;

pub const PageFaultErrorCode = packed struct {
    pub const protection_violation = 1;
    pub const caused_by_write = 1 << 1;
    pub const user_mode = 1 << 2;
    pub const malformed_table = 1 << 3;
    pub const instruction_fetch = 1 << 4;
};

/// An Interrupt Descriptor Table entry
pub fn Entry(comptime HandlerFunctionType: type) type {
    return extern struct {
        ptr_low: u16,
        gdt_selector: u16,
        options: Options,
        ptr_middle: u16,
        ptr_high: u32,
        __reserved: u32,

        // Note that the fields are in this order due to x86 being little endian
        pub const Options = packed struct {
            stack_index: u3,
            __reserved_1: u5,
            gate_type: u4,
            __reserved_2: u1,
            descriptor_privilege_level: u2,
            present: u1,

            const InnerSelf = @This();

            pub fn minimal() InnerSelf {
                return InnerSelf {
                    .stack_index = 0,
                    .__reserved_1 = 0,
                    .gate_type = 0b1110,
                    .__reserved_2 = 0,
                    .descriptor_privilege_level = 0,
                    .present = 0,
                };
            }

            pub fn setDisableInterrupts(self: *InnerSelf, disable: bool) void {
                self.gate_type |= if (disable) 0 else 1;
            }

            pub fn setPresent(self: *InnerSelf, present: bool) void {
                self.present = if (present) 1 else 0;
            }

            pub fn setStackIndex(self: *InnerSelf, index: u3) void {
                self.stack_index = index +% 1;
            }
        };

        pub const HandlerType = HandlerFunctionType;

        const Self = @This();

        pub fn missing() Self {
            return Self{
                .ptr_low = 0,
                .gdt_selector = 0,
                .ptr_middle = 0,
                .ptr_high = 0,
                .options = Options.minimal(),
                .__reserved = 0,
            };
        }

        /// Sets the handler address for the IDT entry and sets the present bit.
        ///
        /// For the code selector field, uses the code segment selector currently active in the
        /// CPU.
        pub fn setHandlerFn(self: *Self, handler: HandlerType) void {
            const handler_addr = @ptrToInt(handler);
            self.ptr_low = @truncate(u16, handler_addr);
            self.ptr_middle = @truncate(u16, handler_addr >> 16);
            self.ptr_high = @truncate(u32, handler_addr >> 32);
            self.gdt_selector = asm("mov %%cs, %[out]" : [out] "=r" (-> u16));
            self.options.setPresent(true);
        }

        /// Sets the handler address for the IDT entry and sets the present bit.
        ///
        /// For the code selector field, uses the code segment selector currently active in the
        /// CPU.
        ///
        /// Adds the given stack index.
        pub fn setHandlerFnWithStackIndex(self: *Self, handler: HandlerType, tss_index: u3) void {
            const handler_addr = @ptrToInt(handler);
            self.ptr_low = @truncate(u16, handler_addr);
            self.ptr_middle = @truncate(u16, handler_addr >> 16);
            self.ptr_high = @truncate(u32, handler_addr >> 32);
            self.gdt_selector = asm("mov %%cs, %[out]" : [out] "=r" (-> u16));
            self.options.setPresent(true);
            self.options.setStackIndex(tss_index);
        }

        comptime {
            assertEqual(@bitSizeOf(Self), 128);
            assertEqual(@sizeOf(Self), 16);
        }
    };
}

// TODO Add documentation, probably steal from
// https://docs.rs/x86_64/0.12.3/src/x86_64/structures/idt.rs.html
/// An Interrupt Descriptor Table with 256 entries
pub const InterruptDescriptorTable = extern struct {
    divide_by_zero: Entry(HandlerFunc),
    debug: Entry(HandlerFunc),
    non_maskable_interrupt: Entry(HandlerFunc),
    breakpoint: Entry(HandlerFunc),
    overflow: Entry(HandlerFunc),
    bound_range_exceeded: Entry(HandlerFunc),
    invalid_opcode: Entry(HandlerFunc),
    device_not_available: Entry(HandlerFunc),
    double_fault: Entry(DivergingHandlerFuncWithErrCode),
    coprocessor_segment_overrun: Entry(HandlerFunc),
    invalid_tss: Entry(HandlerFuncWithErrCode),
    segment_not_present: Entry(HandlerFuncWithErrCode),
    stack_segment_fault: Entry(HandlerFuncWithErrCode),
    general_protection_fault: Entry(HandlerFuncWithErrCode),
    page_fault: Entry(PageFaultHandlerFunc),
    reserved_1: Entry(HandlerFunc),
    x87_floating_point: Entry(HandlerFunc),
    alignment_check: Entry(HandlerFuncWithErrCode),
    machine_check: Entry(DivergingHandlerFunc),
    simd_floating_point: Entry(HandlerFunc),
    virtualization: Entry(HandlerFunc),
    reserved_2: [9]Entry(HandlerFunc),
    security: Entry(HandlerFuncWithErrCode),
    reserved_3: Entry(HandlerFunc),
    pic_interrupts: [16]Entry(HandlerFunc),
    reserved_interrupts: [80]Entry(HandlerFunc),
    apic_interrupts: [256 - 128]Entry(HandlerFunc),

    pub fn new() InterruptDescriptorTable {
        comptime const MissingHandler = Entry(HandlerFunc).missing();
        comptime const MissingErrCodeHandler = Entry(HandlerFuncWithErrCode).missing();
        comptime const MissingDivergingErrCodeHandler =
            Entry(DivergingHandlerFuncWithErrCode).missing();
        comptime const MissingDivergingHandler = Entry(DivergingHandlerFunc).missing();
        return InterruptDescriptorTable{
            .divide_by_zero = MissingHandler,
            .debug = MissingHandler,
            .non_maskable_interrupt = MissingHandler,
            .breakpoint = MissingHandler,
            .overflow = MissingHandler,
            .bound_range_exceeded = MissingHandler,
            .invalid_opcode = MissingHandler,
            .device_not_available = MissingHandler,
            .double_fault = MissingDivergingErrCodeHandler,
            .coprocessor_segment_overrun = MissingHandler,
            .invalid_tss = MissingErrCodeHandler,
            .segment_not_present = MissingErrCodeHandler,
            .stack_segment_fault = MissingErrCodeHandler,
            .general_protection_fault = MissingErrCodeHandler,
            .page_fault = Entry(PageFaultHandlerFunc).missing(),
            .reserved_1 = MissingHandler,
            .x87_floating_point = MissingHandler,
            .alignment_check = MissingErrCodeHandler,
            .machine_check = MissingDivergingHandler,
            .simd_floating_point = MissingHandler,
            .virtualization = MissingHandler,
            .reserved_2 = [_]Entry(HandlerFunc){MissingHandler} ** 9,
            .security = MissingErrCodeHandler,
            .reserved_3 = MissingHandler,
            .pic_interrupts = [_]Entry(HandlerFunc){MissingHandler} ** 16,
            .reserved_interrupts = [_]Entry(HandlerFunc){MissingHandler} ** 80,
            .apic_interrupts = [_]Entry(HandlerFunc){MissingHandler} ** (256 - 128),
        };
    }

    /// Resets all entries of this IDT in place
    pub fn reset(self: *InterruptDescriptorTable) void {
        self.* = InterruptDescriptorTable.new();
    }

    /// Loads the IDT into the CPU
    pub fn load(self: *const InterruptDescriptorTable) void {
        asm volatile("lidt (%[idt])" :: [idt] "r" (@ptrToInt(&self.pointer())));
    }

    /// Creates the descriptor pointer for this IDT.
    ///
    /// This pointer can only be used as long as the table is not modified or destroyed.
    pub fn pointer(self: *const InterruptDescriptorTable) DescriptorTablePointer {
        return DescriptorTablePointer {
            .limit = @truncate(u16, @sizeOf(InterruptDescriptorTable) - 1),
            .base = @ptrToInt(self),
        };
    }

    comptime {
        assertEqual(
            @sizeOf(InterruptDescriptorTable),
            @sizeOf(Entry(HandlerFunc)) * 256,
        );
    }
};
