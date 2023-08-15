//! Architecture specific handling of thread-local storage.

use super::apic::local::LocalApic;
use super::idt::InterruptDescriptorTable;
use super::msr;
use super::page_allocation;
use super::paging::PageTableEntry;
use crate::define_asm_symbol;
use core::mem::MaybeUninit;
use core::ptr::{addr_of, addr_of_mut, NonNull};
use define_asm_symbol::export_asm_all;

pub struct ThreadLocalStorage {
    pub self_pointer: NonNull<ThreadLocalStorage>,
    pub local_apic: LocalApicInfo,
    pub idt: InterruptDescriptorTable,
    pub yield_info: YieldInfo,
}

pub struct LocalApicInfo {
    pub apic: Option<LocalApic>,
    pub interrupt_idt_index: Option<usize>,
    pub timer_us_numerator: usize,
    pub timer_us_denominator: usize,
    pub interrupt_received: bool,
}

impl Default for LocalApicInfo {
    fn default() -> Self {
        Self {
            apic: None,
            interrupt_idt_index: None,
            timer_us_numerator: 1,
            timer_us_denominator: 1,
            interrupt_received: false,
        }
    }
}

#[repr(C)]
#[export_asm_all]
pub struct YieldInfo {
    pub reason: YieldReason,
    // Only used if an exception ocurred
    pub exception_type: MaybeUninit<ExceptionType>,
    pub exception_error_code: u64,
    pub page_fault_address: u64,
}

impl Default for YieldInfo {
    fn default() -> Self {
        Self {
            reason: YieldReason::Timeout,
            exception_type: MaybeUninit::uninit(),
            exception_error_code: 0,
            page_fault_address: 0,
        }
    }
}

define_asm_symbol!(
    "ThreadLocalStorage.yield_info.reason",
    memoffset::offset_of!(ThreadLocalStorage, yield_info)
        + memoffset::offset_of!(YieldInfo, reason),
);
define_asm_symbol!(
    "ThreadLocalStorage.yield_info.exception_type",
    memoffset::offset_of!(ThreadLocalStorage, yield_info)
        + memoffset::offset_of!(YieldInfo, exception_type),
);
define_asm_symbol!(
    "ThreadLocalStorage.yield_info.exception_error_code",
    memoffset::offset_of!(ThreadLocalStorage, yield_info)
        + memoffset::offset_of!(YieldInfo, exception_error_code),
);
define_asm_symbol!(
    "ThreadLocalStorage.yield_info.page_fault_address",
    memoffset::offset_of!(ThreadLocalStorage, yield_info)
        + memoffset::offset_of!(YieldInfo, page_fault_address),
);

#[repr(u64)]
#[export_asm_all]
pub enum YieldReason {
    Timeout,
    YieldSystemCall,
    SystemCallRequest,
    ExitRequest,
    Exception,
}

#[repr(u64)]
#[non_exhaustive]
#[export_asm_all]
pub enum ExceptionType {
    DivideByZero = 0,
    Debug = 1,
    NonMaskableInterrupt = 2,
    Breakpoint = 3,
    Overflow = 4,
    BoundRangeExceeded = 5,
    InvalidOpcode = 6,
    DeviceNotAvailable = 7,
    DoubleFault = 8,
    InvalidTss = 10,
    SegmentNotPresent = 11,
    StackSegmentFault = 12,
    GeneralProtectionFault = 13,
    PageFault = 14,
    X87FloatingPoint = 16,
    AlignmentCheck = 17,
    MachineCheck = 18,
    SimdFloatingPoint = 19,
    Virtualization = 20,
    ControlProtection = 21,
    HypervisorInjection = 28,
    VmmCommunication = 29,
    Security = 30,
}

unsafe impl Sync for ThreadLocalStorage {}

extern "C" {
    #[allow(improper_ctypes)]
    static mut TLS: ThreadLocalStorage;
}

/// Initialises the thread local storage. Must only be called once.
pub unsafe fn init() {
    let tls_size = core::mem::size_of::<ThreadLocalStorage>();
    let start_address = &TLS as *const ThreadLocalStorage as usize & !0xFFF;
    for address in (start_address..start_address + tls_size).step_by(4096) {
        page_allocation::map_page(address, PageTableEntry::READ_WRITE)
            .expect("failed to allocate thread local storage");
        log::debug!("Allocated TLS page at {address:#x}");
    }
    TLS = ThreadLocalStorage {
        self_pointer: NonNull::from(&mut TLS),
        local_apic: Default::default(),
        idt: InterruptDescriptorTable::new(),
        yield_info: Default::default(),
    };
    msr::write(msr::GS_BASE, &TLS as *const ThreadLocalStorage as u64);
}

/// Returns a pointer to the thread local storage.
#[inline]
pub fn get() -> *const ThreadLocalStorage {
    unsafe { addr_of!(TLS) }
}

/// Returns a mutable pointer to the thread local storage.
#[inline]
pub fn get_mut() -> *mut ThreadLocalStorage {
    unsafe { addr_of_mut!(TLS) }
}
