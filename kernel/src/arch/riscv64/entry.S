.section ".init", "ax"

.option norvc

.type start, @function
.global start
start:
    .cfi_startproc
    .cfi_undefined ra
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, stack_top
    add s0, sp, zero
    jal zero, test_entry
    .cfi_endproc
    .end
// bss_clear:
    // sd zero, (t5)
    // addi t5, t5, 8
    // bgeu t5, t6, bss_clear
    // la t0, test_entry
    // csrw sepc, t0
    // tail test_entry
    // .cfi_endproc
    // .end
