use define_asm_symbol::export_asm_all;

extern "C" {
    pub fn syscall_entrypoint();
}

#[derive(Clone, Copy)]
#[repr(transparent)]
pub struct SyscallError(pub usize);

impl SyscallError {
    pub const UNKNOWN_SYSCALL: SyscallError = SyscallError(0);
    pub const INVALID_ARGUMENT: SyscallError = SyscallError(1);
    pub const OUT_OF_MEMORY: SyscallError = SyscallError(2);
}

#[derive(Clone, Copy)]
#[repr(usize)]
#[export_asm_all]
pub enum SystemCall {
    SetBreak,
    MoveBreak,
    // TODO Implement map_mem and unmap_mem, probably want a VMA scheme so we
    // allocate random pages starting from the bottom of the stack growing
    // down towards the heap.
    // Library level heap allocators will likely request pages at specific
    // addresses so we don't need to worry about those.
    MapMem,
    UnmapMem,
    Debug,
}
