// x86_64 platform initialisation code. Entry point for kernel.

.section ".init"
// Set the origin to 0, so that all labels are relative to section start
.org 0

// -- 9x Header --
// Contains entry point offsets for 32 and 64 bit systems
.align 8
// Header magic
.long 0x9E5ED7F1
// 64 bit entry offset from section base
.quad init64
// 32 bit entry offset from section base
// TODO implement loading from 32 bit mode
.long 0

// -- GDT Descriptors --
// Gets replaced later by kernel main
.align 16
GDT64:
    GDT64.Null = . - GDT64
    .word 0xFFFF
    .word 0
    .byte 0
    .byte 0
    .byte 1
    .byte 0
    GDT64.Code = . - GDT64
    .word 0
    .word 0
    .byte 0
    .byte 0b10011010
    .byte 0b10101111
    .byte 0
    GDT64.Data = . - GDT64
    .word 0
    .word 0
    .byte 0
    .byte 0b10010010
    .byte 0b00000000
    .byte 0
    GDT64.TSS = . - GDT64
    .quad 0
    .quad 0
    GDT64.Pointer:
    .word . - GDT64
    GDT64.Pointer.Ptr: .quad 0

// -- Kernel x86_64 Start Code --
.code64
.global init64
.type init64, @function
init64:
    cli
    cld
    and rsp, ~0xF
    mov rbp, rsp

    // -- GDT setup --
    lea rax, [rip + offset GDT64]
    mov [rip + offset GDT64.Pointer.Ptr], rax
    lea rax, [rip + offset GDT64.Pointer]
    lgdt [rax]
    push 8
    lea rax, [rip + offset cs_set]
    push rax
    retfq
cs_set:
    mov ax, 16 
    mov ds, ax 
    mov es, ax 
    mov ss, ax 
    mov fs, ax 
    mov gs, ax 

    // -- Load new page table --
    mov rax, [rdi + offset "kernel_args::Args.page_table_address"]
    mov cr3, rax

    // -- Control register initialisation --
    // Inititalise CR0
    mov rax, 0x80000001
    mov cr0, rax
    // Modify CR4 - enable PAE, PGE, OSFXSR
    mov rax, cr4
    and rax, 0xFFFFFFFFFE08D2A0
    or rax, 0x2A0
    mov cr4, rax
    // Modify EFER - enable NX and SYSCALL, disable Fast FXSAVE/FXRSTOR
    mov ecx, 0xC0000080
    rdmsr
    or eax, 0x801
    and eax, 0xFFFFBFFF
    wrmsr
    // Initialise PAT
    mov ecx, 0x277
    rdmsr
    and eax, 0xF0F0F0F0
    and edx, 0xF0F0F0F0
    or eax, 0x00070406
    or edx, 0x00070501
    wrmsr

    // -- Jump to relocated init code --
    mov rax, offset relocated
    jmp rax

relocated:
    // -- Jump to kernel --
    mov rax, offset kernel_main
    call rax

.size init64, . - init64

// Revert back to default section, as this get inlined in Rust code
.text
