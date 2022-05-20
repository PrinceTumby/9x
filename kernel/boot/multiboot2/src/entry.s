.section ".multiboot"
// -- Multiboot 2 Constants --
.set MAGIC,         0xE85250D6
.set ARCHITECTURE,  0x0
.set HEADER_LENGTH, header_end - header_start
.set CHECKSUM,      -(MAGIC + ARCHITECTURE + HEADER_LENGTH)

// -- Multiboot 2 Header and Tags
// Header
header_start:
.align 8
.long MAGIC
.long ARCHITECTURE
.long HEADER_LENGTH
.long CHECKSUM

// // Address tag
// .align 8
// .word 2
// .word 0
// .long 24
// .long header_start  // Load magic value at requested location
// .long header_start  // Load from stub start
// .long bss_start     // Load data up to start of BSS
// .long bss_end       // Allocate BSS space

// i386 entry address tag
.align 8
.word 3
.word 0
.long 12
.long multiboot_entry

// Framebuffer tag
.align 8
.word 5
.word 0
.long 20
.long 0 // No width preference
.long 0 // No height preference
.long 0 // No BPP preference

// Module page alignment tag
.align 8
.word 6
.word 0
.word 8

// End tag
.align 8
.word 0
.word 0
.long 8
header_end:

.data
// GDT descriptors
.align 16
GDT64:
.set GDT64.Null, . - GDT64
.word 0xFFFF
.word 0
.byte 0
.byte 0
.byte 1
.byte 0
.set GDT64.Code, . - GDT64
.word 0
.word 0
.byte 0
.byte 0b10011010
.byte 0b10101111
.byte 0
.set GDT64.Data, . - GDT64
.word 0
.word 0
.byte 0
.byte 0b10010010
.byte 0b00000000
.byte 0
GDT64.Pointer:
.word . - GDT64 - 1
.quad GDT64

.text
.code32
// Initialises page tables in BSS
initialise_page_tables:
    // movl $0x3, ($level_4_table)
    // movl $0x3, ($level_3_table)
    // movl $0x83, ($level_2_table)
    movl $0x3, level_4_table
    movl $0x3, level_3_table
    movl $0x83, level_2_table
    // movl $0x1083, 8($level_2_table)
    // movl $0x2083, 16($level_2_table)
    // movl $0x3083, 24($level_2_table)
    movl $0x1083, level_2_table + 8
    movl $0x2083, level_2_table + 16
    movl $0x3083, level_2_table + 24
    retl

// Multiboot 32 bit entry point
multiboot_entry:
    cli
    cld
    xchgw %bx, %bx // Bochs breakpoint
    // Initialisation
    // Stack setup
    movl $stack_top, %ebp
    movl $stack_top, %esp
    // Set EFLAGS setting
    movl $0x5000, %eax
    pushl %eax
    popfd
    // Move multiboot info pointer to spare register
    movl %ebx, %edi

    // Check for CPUID
    movl %eax, %ecx
    xorl $(1 << 21), %eax
    pushl %eax
    popfd
    pushfd
    popl %eax
    pushl %ecx
    popfd
    xorl %ecx, %eax
    jz .NoCPUID
    movl $0x80000000, %eax
    cpuid
    cmp $0x80000001, %eax
    jb .NoLongMode
    // CPUID extended functions exist
    movl $0x80000001, %eax
    cpuid
    testl $(1 << 29), %edx
    jz .NoLongMode

    // Long mode exists, set up paging
    // Initialise page tables
    call initialise_page_tables
    // Identity map first 8BiB
    movl $level_2_table, %eax
    andl $0xFFFFF000, %eax
    orl %eax, (level_3_table)
    movl $level_3_table, %eax
    andl $0xFFFFF000, %eax
    orl %eax, (level_4_table)
    // Load page table
    movl $level_4_table, %eax
    movl %eax, %cr3
    // Set PAE bit
    movl %cr4, %eax
    orl $(1 << 5), %eax
    movl %eax, %cr4
    // Set long mode
    movl $0xC0000080, %ecx
    rdmsr
    orl $(1 << 8), %eax
    wrmsr
    movl %cr0, %eax
    orl $(1 << 31), %eax
    movl %eax, %cr0
    lgdt (GDT64.Pointer)
    jmp $GDT64.Code, $start64
    // Failure cases
    // We currently just halt, could maybe report error in future
    .NoCPUID:
    .NoLongMode:
    .Loop:
    hlt
    jmp .Loop

.code64
.global start64
.type start64, @function
start64:
    // Load segment registers
    movw $GDT64.Data, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    // Enable SSE
    movq %cr0, %rax
    andw $0xFFFB, %ax
    orw $0x2, %ax
    movq %rax, %cr0
    movq %cr4, %rax
    orw $(3 << 9), %ax
    movq %rax, %cr4
    // Jump to multiboot main code, multiboot info pointer is already
    // in %rdi, which is first argument in SysV calling convention
    pushq $0
    jmp multiboot_main

.size start64, . - start64

.bss
// Bootloader stack
stack_bottom:
.skip 4096
stack_top:
// Page tables
level_4_table: .skip 4096
level_3_table: .skip 4096
level_2_table: .skip 4096
