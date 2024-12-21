//! Architecture specific code for the x86_64 architecture.

pub mod apic;
pub mod bochs_debug;
pub mod clock;
pub mod cpuid;
pub mod gdt;
pub mod idt;
pub mod init;
pub mod interrupts;
pub mod kernel_args;
pub mod limine;
pub mod page_allocation;
pub mod paging;
pub mod syscall;
pub mod tls;
pub mod tss;
pub mod user_page_mapping;
pub mod virtual_page_mapping;

// Platform re-exports

pub mod platform {
    pub use crate::platform::acpi;
}

// Common functionality

#[macro_export]
macro_rules! define_asm_symbol {
    ($name:expr, $value:expr $(,)?) => {
        core::arch::global_asm!(
            concat!(".global \"", $name, "\"\n\"", $name, "\" = {value}"),
            value = const $value,
        );
    };
}

#[repr(C, align(8))]
struct DescriptorTablePointer([u8; 10]);

#[allow(unused)]
impl DescriptorTablePointer {
    pub fn new(base: u64, limit: u16) -> Self {
        let base_bytes = base.to_le_bytes();
        let limit_bytes = limit.to_le_bytes();
        let mut table: [u8; 10] = [0; 10];
        let (limit_out, base_out) = table.split_at_mut(2);
        limit_out.copy_from_slice(&limit_bytes);
        base_out.copy_from_slice(&base_bytes);
        Self(table)
    }

    pub fn to_base_and_limit(&self) -> (u64, u16) {
        let mut base_bytes = [0; 8];
        let mut limit_bytes = [0; 2];
        let (limit_slice, base_slice) = self.0.split_at(2);
        base_bytes.copy_from_slice(base_slice);
        limit_bytes.copy_from_slice(limit_slice);
        (
            u64::from_le_bytes(base_bytes),
            u16::from_le_bytes(limit_bytes),
        )
    }

    pub fn as_ptr(&self) -> *const u8 {
        self.0.as_ptr()
    }

    pub fn as_mut_ptr(&mut self) -> *mut u8 {
        self.0.as_mut_ptr()
    }
}

pub mod debug_output {
    use super::bochs_debug;

    static mut BOCHS_WRITER_ENABLED: bool = false;

    /// Attempts to initialise and enable each writer in turn. Writers failing to initalise do not
    /// impact initialisation of other writers.
    pub unsafe fn init_writers() {
        if bochs_debug::BochsWriter::test_port_exists() {
            BOCHS_WRITER_ENABLED = true;
        }
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
    pub struct ArchWriter;

    macro_rules! impl_writers_func_body {
        ($write_fn: ident, $arg: ident) => {
            if unsafe { BOCHS_WRITER_ENABLED } {
                bochs_debug::BochsWriter.$write_fn($arg)?;
            }
            return Ok(());
        };
    }

    impl core::fmt::Write for ArchWriter {
        fn write_str(&mut self, s: &str) -> core::fmt::Result {
            impl_writers_func_body!(write_str, s);
        }

        fn write_char(&mut self, c: char) -> core::fmt::Result {
            impl_writers_func_body!(write_char, c);
        }

        fn write_fmt(&mut self, args: core::fmt::Arguments) -> core::fmt::Result {
            impl_writers_func_body!(write_fmt, args);
        }
    }
}

pub mod msr {
    /// Reads a value from the given MSR.
    #[inline]
    pub unsafe fn read(index: u32) -> u64 {
        let value;
        core::arch::asm!(
            "rdmsr",
            "shl rdx, 32",
            "or rdx, rax",
            in("ecx") index,
            out("rdx") value,
            out("eax") _,
            options(nomem, preserves_flags),
        );
        value
    }

    /// Writes a value to the given MSR.
    #[inline]
    pub unsafe fn write(index: u32, value: u64) {
        core::arch::asm!(
            "rdmsr",
            "shl rdx, 32",
            "or rdx, rax",
            in("ecx") index,
            in("eax") value as u32,
            in("edx") (value >> 32) as u32,
            options(nomem, preserves_flags),
        );
    }

    // Standard MSRs
    pub const FS_BASE: u32 = 0xC000_0100;
    pub const GS_BASE: u32 = 0xC000_0101;
    pub const KERNEL_GS_BASE: u32 = 0xC000_0102;
    pub const EFER: u32 = 0xC000_0080;
    pub const IA32_STAR: u32 = 0xC000_0081;
    pub const IA32_LSTAR: u32 = 0xC000_0082;
    pub const IA32_CSTAR: u32 = 0xC000_0083;
    pub const IA32_FMASK: u32 = 0xC000_0084;
}

pub mod port {
    /// Reads a byte from the given x86 port number.
    #[inline(always)]
    pub unsafe fn read_byte(port: u16) -> u8 {
        let mut byte: u8;
        core::arch::asm!(
            "in al, dx",
            in("dx") port,
            lateout("al") byte,
            options(nomem, preserves_flags),
        );
        byte
    }

    /// Writes a byte to the given x86 port number.
    #[inline(always)]
    pub unsafe fn write_byte(port: u16, byte: u8) {
        core::arch::asm!(
            "out dx, al",
            in("dx") port,
            in("al") byte,
            options(nomem, preserves_flags),
        );
    }

    // Standard ports
    pub const BOCHS_DEBUG: u16 = 0xE9;
    pub const CMOS_NMI_AND_REGISTER: u16 = 0x70;
    pub const CMOS_DATA: u16 = 0x71;
}

pub mod process {
    #[derive(Clone, Copy)]
    #[repr(C)]
    pub struct RegisterStore {
        rax: u64,
        rbx: u64,
        rcx: u64,
        rdx: u64,
        rsi: u64,
        rdi: u64,
        rbp: u64,
        rsp: u64,
        r8: u64,
        r9: u64,
        r10: u64,
        r11: u64,
        r12: u64,
        r13: u64,
        r14: u64,
        r15: u64,
        rip: u64,
        rflags: u64,
        fs: u64,
        gs: u64,
        fxsave_area: [u128; 32],
    }

    #[derive(Clone, Copy)]
    #[repr(C)]
    pub struct KernelRegisterStore {
        rbx: u64,
        rcx: u64,
        rdx: u64,
        rbp: u64,
        rsp: u64,
        r8: u64,
        r9: u64,
        r12: u64,
        r13: u64,
        r14: u64,
        r15: u64,
        rip: u64,
        fs: u64,
        fxsave_area: [u128; 32],
    }

    // TODO Sort these out, don't think HIGHEST_PROGRAM_SEGMENT_ADDRESS is actually used anywhere

    pub const HIGHEST_USER_ADDRESS: usize = 0x00007fffffffffff;

    // 4GiB stack size
    pub const STACK_SIZE_LIMIT: usize = 1 << 32;

    pub const HIGHEST_PROGRAM_SEGMENT_ADDRESS: usize = HIGHEST_USER_ADDRESS - STACK_SIZE_LIMIT;

    pub fn is_user_address_valid(address: usize) -> bool {
        address < HIGHEST_USER_ADDRESS
    }

    pub fn is_program_segment_address_valid(address: usize) -> bool {
        address < HIGHEST_PROGRAM_SEGMENT_ADDRESS
    }
}

// Initialisation steps

pub fn init_stage_1(_args: &kernel_args::Args) {
    unsafe {
        gdt::inject_tss_and_load();
        tls::init();
        (*tls::get()).idt.load();
        cpuid::generate_info();
    }
}

pub unsafe fn init_stage_2(args: &kernel_args::Args) {
    use platform::acpi;
    // Initialise ACPI subsystem (ACPICA currently)
    acpi::init_subsystem(args.arch_ptrs.acpi_ptr).unwrap();
    log::debug!("Initialised ACPI subsystem");
    acpi::table::init_manager().expect("initialising ACPI tables failed");
    log::debug!("Initialised ACPI tables");
    // Initialise interrupts
    let madt = acpi::table::get::<acpi::table::Madt>().unwrap();
    log::debug!(
        "MADT at {madt:p}: Madt {{ bsp_local_apic_address: {:#x}, flags: {:#X} }}",
        madt.bsp_local_apic_address,
        madt.flags,
    );
    for entry in madt.entry_iter() {
        log::debug!("MADT entry - {entry:#X?}");
    }
    interrupts::apic::init_from_madt(madt);
    log::debug!("Initialised APIC from MADT");
    // Setup APIC Timer
    {
        use clock::{CALIBRATION_TIMERS, TIMERS};
        clock::MANAGER
            .lock()
            .update_clock_functions(&CALIBRATION_TIMERS.lock(), &TIMERS.lock());
        clock::apic::calibrate();
        clock::apic::setup();
        clock::MANAGER
            .lock()
            .update_clock_functions(&CALIBRATION_TIMERS.lock(), &TIMERS.lock());
        log::debug!("Initialised Local APIC Timer");
    }
    // {
    //     // DEBUG
    //     (clock::MANAGER.lock().timer.set_interrupt_type)(&clock::InterruptType::Sleep);
    //     for i in 0..=10 {
    //         log::debug!("{i}");
    //         (clock::MANAGER.lock().timer.sleep_ms)(1000);
    //     }
    // }
}
