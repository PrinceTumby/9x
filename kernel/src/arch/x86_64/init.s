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
    andq $~0xF, %rsp
    movq %rsp, %rbp

    // -- GDT setup --
    leaq GDT64(%rip), %rax
    movq %rax, GDT64.Pointer.Ptr(%rip)
    leaq GDT64.Pointer(%rip), %rax
    lgdt (%rax)
    pushq $8
    leaq cs_set(%rip), %rax
    pushq %rax
    lretq
    cs_set:
    movw $16, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw %ax, %fs
    movw %ax, %gs

    // -- Load new page table --
    // Page table pointer location in args must be kept in sync with struct definition
    movq 16(%rdi), %rax
    movq %rax, %cr3

    // -- Control register initialisation --
    // Inititalise CR0
    movq $0x80000001, %rax
    movq %rax, %cr0
    // Initialise CR4
    movq $0x402A0, %rax
    movq %rax, %cr4
    // Enable NX and SYSCALL in EFER
    movl $0xC0000080, %ecx
    rdmsr
    orl $0x801, %eax
    wrmsr
    // Initialise PAT
    movl $0x277, %ecx
    rdmsr
    andl $0xF0F0F0F0, %eax
    andl $0xF0F0F0F0, %edx
    orl $0x00070406, %eax
    orl $0x00070501, %edx
    wrmsr

    // -- Jump to relocated init code --
    movq $0f, %rax
    jmp *%rax

0:
    // -- Switch to allocated kernel stack --
    movq $0xFFFFFFFF20007FF0, %rsp
    pushq $0
    movq %rsp, %rbp
    andq $-16, %rsp

    // -- Jump to kernel --
    movq $kernel_main, %rax
    callq *%rax

.size init64, . - init64
