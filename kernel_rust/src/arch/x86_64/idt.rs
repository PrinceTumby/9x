use super::gdt;
use super::tss;
use super::DescriptorTablePointer;
use core::arch::{asm, global_asm};

global_asm!(include_str!("exceptions.s"), options(raw, att_syntax));

#[repr(C)]
pub struct InterruptFrame {
    pub intruction_address: usize,
    pub code_segment: usize,
    pub cpu_flags: usize,
    pub stack_address: usize,
    pub stack_segment: usize,
}

/// Handler function for an interrupt or exception without error code
pub type HandlerFunc = unsafe extern "x86-interrupt" fn(interrupt_frame: InterruptFrame);

/// Handler function for an interrupt or exception with error code
pub type HandlerFuncWithErrCode =
    unsafe extern "x86-interrupt" fn(interrupt_frame: InterruptFrame, error_code: u64);

/// Handler function for an interrupt or exception with page fault error code
pub type PageFaultHandlerFunc = HandlerFuncWithErrCode;

/// Handler function without error code that must not return
pub type DivergingHandlerFunc =
    unsafe extern "x86-interrupt" fn(interrupt_frame: InterruptFrame) -> !;

/// Handler function with error code that must not return
pub type DivergingHandlerFuncWithErrCode =
    unsafe extern "x86-interrupt" fn(interrupt_frame: InterruptFrame, error_code: u64) -> !;

pub trait IdtHandler {
    fn get_address(self) -> usize;
}

macro_rules! impl_idt_handler {
    ($name:ident) => {
        impl IdtHandler for $name {
            fn get_address(self) -> usize {
                self as usize
            }
        }
    };
}

impl_idt_handler!(HandlerFunc);
impl_idt_handler!(HandlerFuncWithErrCode);
impl_idt_handler!(DivergingHandlerFunc);
impl_idt_handler!(DivergingHandlerFuncWithErrCode);

bitfield::bitfield! {
    #[derive(Clone, Copy, PartialEq, Eq)]
    #[repr(transparent)]
    pub struct PageFaultError(u64);
    impl Debug;
    pub protection_violation, _: 0;
    pub caused_by_write, _: 1;
    pub user_mode, _: 2;
    pub malformed_table, _: 3;
    pub instruction_fetch, _: 4;
}

#[derive(Clone, Copy)]
#[repr(C)]
pub struct Entry<F: IdtHandler> {
    ptr_low: u16,
    gdt_selector: u16,
    options: EntryOptions,
    ptr_middle: u16,
    ptr_high: u32,
    _reserved: u32,
    _handler_phantom: core::marker::PhantomData<F>,
}

impl<F: IdtHandler> Entry<F> {
    pub const fn missing() -> Self {
        Self {
            ptr_low: 0,
            gdt_selector: 0,
            options: EntryOptions::minimal(),
            ptr_middle: 0,
            ptr_high: 0,
            _reserved: 0,
            _handler_phantom: core::marker::PhantomData,
        }
    }

    /// Creates an IDT entry with the given handler address and the present bit set. Uses the
    /// `kernel_code` selector from `KernelGdt`.
    pub fn with_handler(handler: F) -> Self {
        let handler_address = handler.get_address();
        Self {
            ptr_low: handler_address as u16,
            gdt_selector: memoffset::offset_of!(gdt::KernelGdt, kernel_code) as u16,
            options: EntryOptions::present_minimal(),
            ptr_middle: (handler_address >> 16) as u16,
            ptr_high: (handler_address >> 32) as u32,
            _reserved: 0,
            _handler_phantom: core::marker::PhantomData,
        }
    }

    /// Creates an IDT entry with the given handler address and stack index, and with the present
    /// bit set. Uses the `kernel_code` selector from `KernelGdt`.
    pub fn with_handler_and_stack(handler: F, tss_index: u8) -> Self {
        let handler_address = handler.get_address();
        Self {
            ptr_low: handler_address as u16,
            gdt_selector: memoffset::offset_of!(gdt::KernelGdt, kernel_code) as u16,
            options: EntryOptions::present_with_stack_index(tss_index),
            ptr_middle: (handler_address >> 16) as u16,
            ptr_high: (handler_address >> 32) as u32,
            _reserved: 0,
            _handler_phantom: core::marker::PhantomData,
        }
    }

    /// Creates an IDT entry with the given handler address, and with the present bit set. Uses
    /// `GENERIC_STACK` from `InterruptStacks` and `kernel_code` selector from `KernelGdt`.
    pub fn with_handler_and_generic_stack(handler: F) -> Self {
        Self::with_handler_and_stack(
            handler,
            (memoffset::offset_of!(tss::InterruptStacks, generic) / 8) as u8,
        )
    }
}

impl<F: IdtHandler> core::fmt::Debug for Entry<F> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("Entry")
            .field("ptr_low", &self.ptr_low)
            .field("gdt_selector", &self.gdt_selector)
            .field("options", &self.options)
            .field("ptr_middle", &self.ptr_middle)
            .field("ptr_high", &self.ptr_high)
            .finish()
    }
}

bitfield::bitfield! {
    #[derive(Clone, Copy, PartialEq, Eq)]
    #[repr(transparent)]
    struct EntryOptions(u16);
    impl Debug;
    pub stack_index_minus_one, set_stack_index_minus_one: 2, 0;
    pub gate_type, set_gate_type: 11, 9;
    pub interrupts_enabled, set_interrupts_enabled: 8;
    pub discriptor_privilege_level, set_descriptor_privilege_level: 14, 13;
    pub present, set_present: 15;
}

impl EntryOptions {
    /// Returns a set of options with all zeros.
    pub const fn minimal() -> Self {
        Self(0b111 << 9)
    }

    /// Returns a set of options with all zeros, but with the gate type and present flag set.
    pub const fn present_minimal() -> Self {
        Self(1 << 15 | 0b111 << 9)
    }

    pub const fn present_with_stack_index(tss_index: u8) -> Self {
        Self(Self::present_minimal().0 | ((tss_index + 1) & 0b111) as u16)
    }
}

#[repr(C, align(16))]
pub struct InterruptDescriptorTable {
    pub divide_by_zero: Entry<HandlerFunc>,
    pub debug: Entry<HandlerFunc>,
    pub non_maskable_interrupt: Entry<HandlerFunc>,
    pub breakpoint: Entry<HandlerFunc>,
    pub overflow: Entry<HandlerFunc>,
    pub bound_range_exceeded: Entry<HandlerFunc>,
    pub invalid_opcode: Entry<HandlerFunc>,
    pub device_not_available: Entry<HandlerFunc>,
    pub double_fault: Entry<DivergingHandlerFuncWithErrCode>,
    pub coprocessor_segment_overrun: Entry<HandlerFunc>,
    pub invalid_tss: Entry<HandlerFuncWithErrCode>,
    pub segment_not_present: Entry<HandlerFuncWithErrCode>,
    pub stack_segment_fault: Entry<HandlerFuncWithErrCode>,
    pub general_protection_fault: Entry<HandlerFuncWithErrCode>,
    pub page_fault: Entry<PageFaultHandlerFunc>,
    pub reserved_1: Entry<HandlerFunc>,
    pub x87_floating_point: Entry<HandlerFunc>,
    pub alignment_check: Entry<HandlerFuncWithErrCode>,
    pub machine_check: Entry<DivergingHandlerFunc>,
    pub simd_floating_point: Entry<HandlerFunc>,
    pub virtualization: Entry<HandlerFunc>,
    pub reserved_2: [Entry<HandlerFunc>; 9],
    pub security: Entry<HandlerFuncWithErrCode>,
    pub reserved_3: Entry<HandlerFunc>,
    pub pic_interrupts: [Entry<HandlerFunc>; 16],
    pub reserved_interrupts: [Entry<HandlerFunc>; 80],
    pub apic_interrupts: [Entry<HandlerFunc>; 256 - 128],
}

// TODO Make `limine_entry` map the limine stack into a standard higher half location.
impl InterruptDescriptorTable {
    pub fn new() -> Self {
        use exception_handlers as handlers;
        let apic_interrupts = [Entry::missing(); 256 - 128];
        // apic_interrupts[0] = Entry::with_handler_and_generic_stack(handlers::dummy_apic_eoi_handler);
        Self {
            divide_by_zero: Entry::with_handler_and_generic_stack(handlers::divide_by_zero),
            debug: Entry::with_handler_and_generic_stack(handlers::debug),
            non_maskable_interrupt: Entry::with_handler_and_generic_stack(
                handlers::non_maskable_interrupt,
            ),
            breakpoint: Entry::with_handler_and_generic_stack(handlers::breakpoint),
            overflow: Entry::with_handler_and_generic_stack(handlers::overflow),
            bound_range_exceeded: Entry::with_handler_and_generic_stack(
                handlers::bound_range_exceeded,
            ),
            invalid_opcode: Entry::with_handler_and_generic_stack(handlers::invalid_opcode),
            device_not_available: Entry::with_handler_and_generic_stack(
                handlers::device_not_available,
            ),
            double_fault: Entry::with_handler_and_stack(
                handlers::double_fault,
                (memoffset::offset_of!(tss::InterruptStacks, double_fault) / 8) as u8,
            ),
            coprocessor_segment_overrun: Entry::missing(),
            invalid_tss: Entry::with_handler_and_generic_stack(handlers::invalid_tss),
            segment_not_present: Entry::with_handler_and_generic_stack(
                handlers::segment_not_present,
            ),
            stack_segment_fault: Entry::with_handler_and_generic_stack(
                handlers::stack_segment_fault,
            ),
            general_protection_fault: Entry::with_handler_and_stack(
                handlers::general_protection_fault,
                (memoffset::offset_of!(tss::InterruptStacks, general_protection_fault) / 8) as u8,
            ),
            page_fault: Entry::with_handler_and_stack(
                handlers::page_fault,
                (memoffset::offset_of!(tss::InterruptStacks, page_fault) / 8) as u8,
            ),
            reserved_1: Entry::missing(),
            x87_floating_point: Entry::with_handler_and_generic_stack(handlers::x87_floating_point),
            alignment_check: Entry::with_handler_and_generic_stack(handlers::alignment_exception),
            machine_check: Entry::with_handler_and_generic_stack(handlers::machine_check),
            simd_floating_point: Entry::with_handler_and_generic_stack(
                handlers::simd_floating_point,
            ),
            virtualization: Entry::with_handler_and_generic_stack(handlers::virtualization),
            reserved_2: [Entry::missing(); 9],
            security: Entry::with_handler_and_generic_stack(handlers::security),
            reserved_3: Entry::missing(),
            pic_interrupts: [Entry::missing(); 16],
            reserved_interrupts: [Entry::missing(); 80],
            apic_interrupts,
        }
    }

    /// Loads the IDT into the CPU.
    pub unsafe fn load(&self) {
        let ptr = DescriptorTablePointer::new(
            self as *const Self as u64,
            core::mem::size_of_val(self) as u16 - 1,
        );
        asm!("lidt [{}]", in(reg) ptr.as_ptr());
    }
}

/// Handlers for CPU exceptions
pub mod exception_handlers {
    use super::InterruptFrame;

    // Panicking exception helper functions

    #[no_mangle]
    unsafe extern "C" fn exception_message(msg_ptr: *const u8, msg_len: usize, rip: usize) -> ! {
        let msg = core::str::from_utf8_unchecked(core::slice::from_raw_parts(msg_ptr, msg_len));
        panic!(
            concat!("{msg}:\n", "- Caused by instruction at {rip:#x}\n",),
            msg = msg,
            rip = rip,
        );
    }

    #[no_mangle]
    unsafe extern "C" fn exception_message_with_err_code(
        msg_ptr: *const u8,
        msg_len: usize,
        error_code: u32,
        rip: usize,
    ) -> ! {
        let msg = core::str::from_utf8_unchecked(core::slice::from_raw_parts(msg_ptr, msg_len));
        panic!(
            concat!(
                "{msg}:\n",
                "- With error code {error_code:#X}\n",
                "- Caused by instruction at {rip:#x}\n",
            ),
            msg = msg,
            error_code = error_code,
            rip = rip,
        );
    }

    #[no_mangle]
    unsafe extern "C" fn page_fault_exception_message(
        msg_ptr: *const u8,
        msg_len: usize,
        error_code: u32,
        access_address: usize,
        rip: usize,
    ) -> ! {
        let msg = core::str::from_utf8_unchecked(core::slice::from_raw_parts(msg_ptr, msg_len));
        panic!(
            concat!(
                "{msg}:\n",
                "- With error code {error_code:#X}\n",
                "- Caused by access to address {access_address:#x} by instruction at {rip:#x}\n",
            ),
            msg = msg,
            error_code = error_code,
            access_address = access_address,
            rip = rip,
        );
    }

    // Handlers

    #[no_mangle]
    pub unsafe extern "x86-interrupt" fn breakpoint(_interrupt_frame: InterruptFrame) {
        log::info!("Exception - Breakpoint");
    }

    extern "x86-interrupt" {
        pub fn divide_by_zero(interrupt_frame: InterruptFrame);
        pub fn debug(interrupt_frame: InterruptFrame);
        pub fn non_maskable_interrupt(interrupt_frame: InterruptFrame);
        pub fn overflow(interrupt_frame: InterruptFrame);
        pub fn bound_range_exceeded(interrupt_frame: InterruptFrame);
        pub fn invalid_opcode(interrupt_frame: InterruptFrame);
        pub fn device_not_available(interrupt_frame: InterruptFrame);
        pub fn double_fault(interrupt_frame: InterruptFrame, error_code: u64) -> !;
        pub fn invalid_tss(interrupt_frame: InterruptFrame, error_code: u64);
        pub fn segment_not_present(interrupt_frame: InterruptFrame, error_code: u64);
        pub fn stack_segment_fault(interrupt_frame: InterruptFrame, error_code: u64);
        pub fn general_protection_fault(interrupt_frame: InterruptFrame, error_code: u64);
        pub fn page_fault(interrupt_frame: InterruptFrame, error_code: u64);
        pub fn x87_floating_point(interrupt_frame: InterruptFrame);
        pub fn alignment_exception(interrupt_frame: InterruptFrame, error_code: u64);
        pub fn machine_check(interrupt_frame: InterruptFrame) -> !;
        pub fn simd_floating_point(interrupt_frame: InterruptFrame);
        pub fn virtualization(interrupt_frame: InterruptFrame);
        pub fn security(interrupt_frame: InterruptFrame, error_code: u64);
    }
}
