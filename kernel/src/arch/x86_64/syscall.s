// x86_64 SYSCALL entrypoint code

.rodata
syscall_table:
.quad syscallPrintDebugMessage
syscall_table_len = (. - syscall_table) / 8

.text

.global syscallEntrypoint
.type syscallEntrypoint, @function
syscallEntrypoint:
    // Branch if syscall number is too large
    cmpq $syscall_table_len, %rax
    jge 0f
    // Jump to appropriate syscall handler
    movq syscall_table(%rax), %rax
    jmpq *%rax
0:
    // Return value of -1 indicates no system call handler
    movq $-1, %rax
    sysretq
.size syscallEntrypoint, . - syscallEntrypoint

.type syscallPrintDebugMessage, @function
syscallPrintDebugMessage:
    pushq %rcx
    pushq %rdx
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    callq debugFromC
    movq $0, %rax
    movq $0, %rdi
    movq $0, %rsi
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rdx
    popq %rcx
    sysretq
.size syscallPrintDebugMessage, . - syscallPrintDebugMessage
