.section ".init"

// Loads the PC-relative address of `symbol` into `register`
// Symbol must be within +- 4 GiB of PC
.macro ADR_REL register, symbol
    adrp \register, \symbol
    add \register, \register, #:lo12:\symbol
.endm

// Kernel entry point for the Raspberry Pi 3 and 4
// Registers at start:
// x0 -> 32 bit pointer to DTB in memory
// x1 -> 0
// x2 -> 0
// x3 -> 0
// x4 -> 32 bit kernel entry point, _start location
.global _start
.type _start, @function
_start:
    // Only proceed on boot core, park otherwise
    mrs x1, MPIDR_EL1
    and x1, x1, 0b11
    mov x2, #0
    cmp x1, x2
    b.ne .park_loop
    // Clear BSS
    ADR_REL x1, __bss_start
    ADR_REL x2, __bss_end
1:  cmp x1, x2
    b.eq 2f
    stp xzr, xzr, [x1], #16
    b 1b
2:
    // Set stack pointer
    ADR_REL x1, _start
    mov sp, x1
    // Jump to Zig entry point
    b rpiEntrypoint
    // Infinitely wait for events
.park_loop:
    wfe
    b .park_loop
.size _start, . - _start
