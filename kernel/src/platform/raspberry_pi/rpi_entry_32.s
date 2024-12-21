.org 0x8000
.section ".init"

// Performs a PC-relative address load using `symbol` into `register`
// Clobbers r6
.macro ADR_REL register, symbol
    adr r6, \symbol
    ldr \register, [r6]
    add \register, \register, r6
.endm

// Kernel entry point for 32 bit compatible Raspberry Pis
// Registers at start:
// r15 -> should begin execution at 0x8000
// r0 -> 0
// r1 -> 0xC42 - machine ID
// r2 -> 0x100 - start of ATAGS
.global _start
.type _start, function
_start:
    ldr sp, =_start
    bl rpi_entrypoint
    // Return to bootloader
    bx lr
    // // Only proceed on boot core, park otherwise
    // mrc p15, 0, r5, c0, c0, 5
    // and r5, r5, #3
    // cmp r5, #3
    // bne .park_loop
    // Clear BSS
    ldr r4, =__bss_start
    ldr r9, =__bss_end
    // ADR_REL r4, __bss_start_rel
    // ADR_REL r9, __bss_end_rel
    mov r5, #0
    mov r6, #0
    mov r7, #0
    mov r8, #0
    b 2f
1:
    // Store multiple at r4
    stmia r4!, {r5-r8}
2:
    // If we are still below bss_end, loop
    cmp r4, r9
    blo 1b
    // Setup the stack
    ldr r5, =_start
    mov sp, r5
    // adr sp, _start
    // Call Zig entrypoint
    ldr r3, =rpi_entrypoint
    // ADR_REL r3, __rpi_entrypoint_pc_rel
    blx r3
.park_loop:
    // Infinitely wait for events
    wfe
    b .park_loop
.size _start, . - _start

// __bss_start_rel: .word __bss_start - .
// __bss_end_rel: .word __bss_end - .
// __rpi_entrypoint_pc_rel: .word rpi_entrypoint - .
