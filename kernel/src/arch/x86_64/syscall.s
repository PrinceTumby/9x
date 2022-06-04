// x86_64 SYSCALL entrypoint code

.rodata

syscall_table:
// .quad getPidSyscall
// Debug system call
// RDI contains message ptr, RSI contains message len
// Returns 0 in RAX
.quad getPidSyscall
.quad debugSyscall
.quad yieldSyscall
syscall_table_len = (. - syscall_table) / 8

.text

.global syscallEntrypoint
.type syscallEntrypoint, @function
syscallEntrypoint:
    xchgw %bx, %bx
    // Branch if syscall number is too large
    cmpq $syscall_table_len, %rax
    jge 0f
    // Jump to appropriate syscall handler
    movq syscall_table(,%rax,8), %rax
    jmpq *%rax
0:
    // Return value of -1 indicates invalid system call
    movq $-1, %rax
    sysretq
.size syscallEntrypoint, . - syscallEntrypoint

.type syscallSemiKernel, @function
syscallSemiKernelBody:
    // Get pointer to register storage
    movq %gs:ThreadLocalVariables.self_pointer, %rax
    leaq ThreadLocalVariables.current_process.registers.rax(%rax), %rax
    addq $8, %rax
    // Save registers
    movq %rbx, (%rax)
    addq $8, %rax
    movq $0, (%rax) // RCX gets zeroed out by syscall
    addq $8, %rax
    movq %rdx, (%rax)
    addq $8, %rax
    movq %rsi, (%rax)
    addq $8, %rax
    movq %rdi, (%rax)
    addq $8, %rax
    movq %rbp, (%rax)
    addq $8, %rax
    movq %rsp, (%rax)
    addq $8, %rax
    movq %r8, (%rax)
    addq $8, %rax
    movq %r9, (%rax)
    addq $8, %rax
    movq %r10, (%rax)
    addq $8, %rax
    movq $0, (%rax) // R11 gets zeroed out by syscall
    addq $8, %rax
    movq %r12, (%rax)
    addq $8, %rax
    movq %r13, (%rax)
    addq $8, %rax
    movq %r14, (%rax)
    addq $8, %rax
    movq %r15, (%rax)
    addq $8, %rax
    movq %rcx, (%rax) // RIP
    addq $8, %rax
    movq %r11, (%rax) // RFLAGS
    addq $8, %rax
    movl $0xC0000100, %ecx // FS
    movq %rax, %rbx
    rdmsr
    shlq $32, %rdx
    orq %rax, %rdx
    movq %rdx, (%rbx)
    addq $8, %rbx
    movl $0xC0000102, %ecx // GS
    rdmsr
    shlq $32, %rdx
    orq %rax, %rdx
    movq %rdx, (%rbx)
    // Load main kernel process registers, jump to address
    movq %gs:ThreadLocalVariables.self_pointer, %rax
    leaq ThreadLocalVariables.kernel_main_process.registers.vector_store(%rax), %rbx
    fxrstor64 (%rbx) // Vector state
    leaq ThreadLocalVariables.kernel_main_process.registers.fs(%rax), %rbx
    movl $0xC0000100, %ecx // FS
    movl (%rbx), %eax
    movl 4(%rbx), %edx
    wrmsr
    movq %rbx, %rax
    subq $16, %rax
    movq (%rax), %r15
    subq $8, %rax
    movq (%rax), %r14
    subq $8, %rax
    movq (%rax), %r13
    subq $8, %rax
    movq (%rax), %r12
    subq $8, %rax
    movq (%rax), %r9
    subq $8, %rax
    movq (%rax), %r8
    subq $8, %rax
    movq (%rax), %rsp
    subq $8, %rax
    movq (%rax), %rbp
    subq $8, %rax
    movq (%rax), %rdx
    subq $8, %rax
    movq (%rax), %rcx
    subq $8, %rax
    movq (%rax), %rbx
    movq 88(%rax), %rax // RIP
    jmpq *%rax
.size syscallSemiKernelBody, . - syscallSemiKernelBody

// Zig system calls

.type debugSyscall, @function
debugSyscall:
    // Swap GS to contain pointer to kernel thread local storage
    swapgs
    // Write yield reason
    movq $YieldInfo.Reason.SystemCallRequest, %gs:ThreadLocalVariables.yield_info.reason
    // Save RAX
    movq $SystemCall.Debug, %gs:ThreadLocalVariables.current_process.registers.rax
    jmp syscallSemiKernelBody
.size debugSyscall, . - debugSyscall

.type yieldSyscall, @function
yieldSyscall:
    // Swap GS to contain pointer to kernel thread local storage
    swapgs
    // Write yield reason
    movq $YieldInfo.Reason.YieldSystemCall, %gs:ThreadLocalVariables.yield_info.reason
    // No Zig system call number, so write out zero
    movq $0, %gs:ThreadLocalVariables.current_process.registers.rax
    jmp syscallSemiKernelBody
.size debugSyscall, . - debugSyscall

// Custom assembly system calls

.type getPidSyscall, @function
getPidSyscall:
    swapgs
    movq %gs:ThreadLocalVariables.current_process.id, %rax
    swapgs
    sysretq
.size getPidSyscall, . - getPidSyscall
