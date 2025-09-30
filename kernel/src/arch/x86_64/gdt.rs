use super::DescriptorTablePointer;
use super::tss;
use core::arch::asm;
use define_asm_symbol::export_asm_all;

bitfield::bitfield! {
    #[derive(Clone, Copy, PartialEq, Eq)]
    #[repr(transparent)]
    pub struct SegmentSelector(u16);
    impl Debug;
    pub rpl, _: 3, 0;
    pub index, _: 4, 11;
}

bitflags::bitflags! {
    struct SegmentFlags: u64 {
        const ACCESSED = 1 << 40;
        const WRITABLE = 1 << 41;
        const CONFORMING = 1 << 42;
        const EXECUTABLE = 1 << 43;
        const USER = 1 << 44;
        const DPL_RING_3 = 3 << 45;
        const PRESENT = 1 << 47;
        const LONG_MODE = 1 << 53;
        const BITS_32 = 1 << 54;
        const PAGE_GRANULARITY = 1 << 55;
        const MAX_LIMIT = 0xF << 48 | 0xFFFF;
        const COMMON = Self::USER.bits()
            | Self::PRESENT.bits()
            | Self::WRITABLE.bits()
            | Self::PAGE_GRANULARITY.bits()
            | Self::MAX_LIMIT.bits();
        const KERNEL_DATA = Self::COMMON.bits() | Self::BITS_32.bits();
        const KERNEL_CODE_32 = Self::COMMON.bits() | Self::EXECUTABLE.bits() | Self::BITS_32.bits();
        const KERNEL_CODE_64 = Self::COMMON.bits() | Self::EXECUTABLE.bits() | Self::LONG_MODE.bits();
        const USER_DATA = Self::KERNEL_DATA.bits() | Self::DPL_RING_3.bits();
        const USER_CODE_32 = Self::KERNEL_CODE_32.bits() | Self::DPL_RING_3.bits();
        const USER_CODE_64 = Self::KERNEL_CODE_64.bits() | Self::DPL_RING_3.bits();
    }
}

#[repr(C, align(16))]
#[export_asm_all]
pub struct KernelGdt {
    pub null: u64,
    pub kernel_code: u64,
    pub kernel_data: u64,
    pub tss_lower: u64,
    pub tss_upper: u64,
    pub user_code_32: u64,
    pub user_data_32: u64,
    pub user_code_64: u64,
    pub user_data_64: u64,
}

pub static mut KERNEL_GDT: KernelGdt = KernelGdt {
    null: 0x0001_0000_0000_FFFF,
    kernel_code: SegmentFlags::KERNEL_CODE_64.bits(),
    kernel_data: SegmentFlags::KERNEL_DATA.bits(),
    tss_lower: 0,
    tss_upper: 0,
    user_code_32: SegmentFlags::USER_CODE_32.bits(),
    user_data_32: SegmentFlags::USER_DATA.bits(),
    user_code_64: SegmentFlags::USER_CODE_64.bits(),
    user_data_64: SegmentFlags::USER_DATA.bits(),
};

pub unsafe fn inject_tss_and_load() {
    unsafe {
        // Inject TSS into GDT
        {
            let tss_address = &tss::KERNEL_TSS as *const tss::KernelTss as u64;
            let mut low = SegmentFlags::PRESENT.bits();
            // Base
            low |= (tss_address & 0xFFFFFF) << 16;
            low |= (tss_address & 0xFF000000) << 32;
            // Limit
            low |= (core::mem::size_of::<tss::KernelTss>() as u64 - 1) & 0xFFFF;
            // Type
            low |= 0b1001 << 40;
            let high = (tss_address & 0xFFFFFFFF00000000) >> 32;
            KERNEL_GDT.tss_lower = low;
            KERNEL_GDT.tss_upper = high;
        }
        // Load GDT
        let ptr = DescriptorTablePointer::new(
            &raw const KERNEL_GDT as u64,
            core::mem::size_of::<KernelGdt>() as u16 - 1,
        );
        asm!("lgdt [{}]", in(reg) ptr.as_ptr());
        // Reload segment descriptors and load TSS
        asm!(
            "push 8",
            "lea rax, [rip + 2f]",
            "push rax",
            "retfq",
            "2:",
            "mov ax, 16",
            "mov ds, ax",
            "mov es, ax",
            "mov ss, ax",
            "mov ax, 24",
            "ltr ax",
            out("rax") _,
        );
    }
}
