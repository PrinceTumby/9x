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
pub struct Stack([u8; 4096]);

impl Stack {
    pub const fn empty() -> Self {
        Self([0; 4096])
    }

    pub const fn get_end_address(&self) -> *const u8 {
        (&self.0 as *const u8).wrapping_add(self.0.len() & !0xF)
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
        system_call: unsafe { stacks::SYSTEM_CALL_STACK.get_end_address() },
        _unused: [0; 2],
    },
    interrupt_stack_table: InterruptStacks {
        generic: unsafe { stacks::GENERIC.get_end_address() },
        double_fault: unsafe { stacks::DOUBLE_FAULT.get_end_address() },
        page_fault: unsafe { stacks::PAGE_FAULT.get_end_address() },
        general_protection_fault: unsafe { stacks::GENERAL_PROTECTION_FAULT.get_end_address() },
        _unused: [0; 3],
    },
    iopb_base: memoffset::offset_of!(KernelTss, iopb) as u16,
    iopb: IoPermissionBitmap([0xFF; 8192]),
    _reserved_1: 0,
    _reserved_2: 0,
    _reserved_3: 0,
    _reserved_4: 0,
};

#[repr(transparent)]
pub struct IoPermissionBitmap([u8; 8192]);
