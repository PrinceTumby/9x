#[repr(C, packed(4))]
pub struct KernelTss {
    _reserved_1: u32,
    privilege_stack_table: PrivilegeStacks,
    _reserved_2: u64,
    interrupt_stack_table: InterruptStacks,
    _reserved_3: u64,
    _reserved_4: u64,
    iopb_base: u16,
    iopb: IoPermissionBitmap,
}

#[repr(C, packed(4))]
pub struct PrivilegeStacks {
    system_call: *const u8,
    _unused: [u64; 2],
}

unsafe impl Sync for PrivilegeStacks {}

#[repr(C, packed(4))]
pub struct InterruptStacks {
    pub generic: *const u8,
    pub double_fault: *const u8,
    pub page_fault: *const u8,
    pub general_protection_fault: *const u8,
    _unused: [u64; 3],
}

unsafe impl Sync for InterruptStacks {}

#[repr(C, align(16))]
pub struct Stack([u8; Self::SIZE]);

impl Stack {
    pub const SIZE: usize = 4096;

    pub const fn empty() -> Self {
        Self([0; Self::SIZE])
    }

    pub const fn get_end_address(ptr: *const Self) -> *const u8 {
        (ptr as *const u8).wrapping_add(Self::SIZE & !0xF)
    }
}

mod stacks {
    use super::Stack;
    // Interrupt stacks
    pub static mut GENERIC: Stack = Stack::empty();
    pub static mut DOUBLE_FAULT: Stack = Stack::empty();
    pub static mut PAGE_FAULT: Stack = Stack::empty();
    pub static mut GENERAL_PROTECTION_FAULT: Stack = Stack::empty();
    // Privileged stacks
    pub static mut SYSTEM_CALL_STACK: Stack = Stack::empty();
}

pub static KERNEL_TSS: KernelTss = KernelTss {
    privilege_stack_table: PrivilegeStacks {
        system_call: Stack::get_end_address(&raw const stacks::SYSTEM_CALL_STACK),
        _unused: [0; 2],
    },
    interrupt_stack_table: InterruptStacks {
        generic: Stack::get_end_address(&raw const stacks::GENERIC),
        double_fault: Stack::get_end_address(&raw const stacks::DOUBLE_FAULT),
        page_fault: Stack::get_end_address(&raw const stacks::PAGE_FAULT),
        general_protection_fault: Stack::get_end_address(
            &raw const stacks::GENERAL_PROTECTION_FAULT,
        ),
        _unused: [0; 3],
    },
    iopb_base: core::mem::offset_of!(KernelTss, iopb) as u16,
    iopb: IoPermissionBitmap([0xFF; 8192]),
    _reserved_1: 0,
    _reserved_2: 0,
    _reserved_3: 0,
    _reserved_4: 0,
};

#[repr(transparent)]
pub struct IoPermissionBitmap([u8; 8192]);
