.text

// RDI should contain pointer to user process we are switching to
// Function is allowed to clobber RAX, RDI, R10, R11
.global taskSwitchKernelMainToUserSysret
.type taskSwitchKernelMainToUserSysret, @function
taskSwitchKernelMainToUserSysret:
    // Save vector state, get pointer to register storage
    movq %gs:ThreadLocalVariables.self_pointer, %rax
    leaq ThreadLocalVariables.kernel_main_process.registers.vector_store(%rax), %r10
    fxsave64 (%r10)
    leaq ThreadLocalVariables.kernel_main_process.registers.rbx(%rax), %rax
    // Save kernel process registers
    movq %rbx, (%rax)
    addq $8, %rax
    popq %rbx // Get return address
    movq %rcx, (%rax)
    addq $8, %rax
    movq %rdx, (%rax)
    addq $8, %rax
    movq %rbp, (%rax)
    addq $8, %rax
    movq %rsp, (%rax)
    addq $8, %rax
    movq %r8, (%rax)
    addq $8, %rax
    movq %r9, (%rax)
    addq $8, %rax
    movq %r12, (%rax)
    addq $8, %rax
    movq %r13, (%rax)
    addq $8, %rax
    movq %r14, (%rax)
    addq $8, %rax
    movq %r15, (%rax)
    addq $8, %rax
    movq %rbx, (%rax) // Save return address as RIP
    addq $8, %rax
    movl $0xC0000100, %ecx // FS
    movq %rax, %rbx
    rdmsr
    shlq $32, %rdx
    orq %rax, %rdx
    movq %rdx, (%rbx)
    // Switch to user process address space
    movq Process.page_mapper.page_table(%rdi), %rax
    movq %rax, %cr3
    // Swap kernel GS out, user GS gets replaced by register loading
    swapgs
    // Load user process registers, build fake interrupt frame on kernel process stack
    leaq Process.registers.vector_store(%rdi), %rax // Vector state
    fxrstor64 (%rax)
    leaq Process.registers.end_register(%rdi), %rbx
    movl $0xC0000101, %ecx // GS
    movl (%rbx), %eax
    movl 4(%rbx), %edx
    wrmsr
    subq $8, %rbx
    movl $0xC0000100, %ecx // FS
    movl (%rbx), %eax
    movl 4(%rbx), %edx
    wrmsr
    movq %rbx, %rax
    subq $8, %rax
    movq (%rax), %r11 // RFLAGS
    subq $8, %rax
    movq (%rax), %rcx // RIP
    subq $8, %rax
    movq (%rax), %r15
    subq $8, %rax
    movq (%rax), %r14
    subq $8, %rax
    movq (%rax), %r13
    subq $8, %rax
    movq (%rax), %r12
    subq $16, %rax
    movq (%rax), %r10
    subq $8, %rax
    movq (%rax), %r9
    subq $8, %rax
    movq (%rax), %r8
    subq $8, %rax
    movq (%rax), %rsp
    subq $8, %rax
    movq (%rax), %rbp
    subq $8, %rax
    movq (%rax), %rdi
    subq $8, %rax
    movq (%rax), %rsi
    subq $8, %rax
    movq (%rax), %rdx
    subq $16, %rax
    movq (%rax), %rbx
    subq $8, %rax
    movq (%rax), %rax
    sysretq
.size taskSwitchKernelMainToUserSysret, . - taskSwitchKernelMainToUserSysret

// RDI should contain pointer to user process we are switching to
// Function is allowed to clobber RAX, RDI, R10, R11
.global taskSwitchKernelMainToUserIret
.type taskSwitchKernelMainToUserIret, @function
taskSwitchKernelMainToUserIret:
    // Save vector state, get pointer to register storage
    movq %gs:ThreadLocalVariables.self_pointer, %rax
    leaq ThreadLocalVariables.kernel_main_process.registers.vector_store(%rax), %r10
    fxsave64 (%r10)
    leaq ThreadLocalVariables.kernel_main_process.registers.rbx(%rax), %rax
    // Save kernel process registers
    movq %rbx, (%rax)
    addq $8, %rax
    popq %rbx // Get return address
    movq %rcx, (%rax)
    addq $8, %rax
    movq %rdx, (%rax)
    addq $8, %rax
    movq %rbp, (%rax)
    addq $8, %rax
    movq %rsp, (%rax)
    addq $8, %rax
    movq %r8, (%rax)
    addq $8, %rax
    movq %r9, (%rax)
    addq $8, %rax
    movq %r12, (%rax)
    addq $8, %rax
    movq %r13, (%rax)
    addq $8, %rax
    movq %r14, (%rax)
    addq $8, %rax
    movq %r15, (%rax)
    addq $8, %rax
    movq %rbx, (%rax) // Save return address as RIP
    addq $8, %rax
    movl $0xC0000100, %ecx // FS
    movq %rax, %rbx
    rdmsr
    shlq $32, %rdx
    orq %rax, %rdx
    movq %rdx, (%rbx)
    // Switch to user process address space
    movq Process.page_mapper.page_table(%rdi), %rax
    movq %rax, %cr3
    // Swap kernel GS out, user GS gets replaced by register loading
    swapgs
    // Load user process registers, build fake interrupt frame on kernel process stack
    subq $40, %rsp
    movq $(GDT.user_code_64 + 3), 8(%rsp) // CS
    movq $(GDT.user_data_64 + 3), 32(%rsp) // SS
    leaq Process.registers.vector_store(%rdi), %rax // Vector state
    fxrstor64 (%rax)
    leaq Process.registers.end_register(%rdi), %rbx
    movl $0xC0000101, %ecx // GS
    movl (%rbx), %eax
    movl 4(%rbx), %edx
    wrmsr
    subq $8, %rbx
    movl $0xC0000100, %ecx // FS
    movl (%rbx), %eax
    movl 4(%rbx), %edx
    wrmsr
    movq %rbx, %rax
    subq $8, %rax
    movq (%rax), %rdi // RFLAGS
    movq %rdi, 16(%rsp)
    subq $8, %rax
    movq (%rax), %rdi // RIP
    movq %rdi, (%rsp)
    subq $8, %rax
    movq (%rax), %r15
    subq $8, %rax
    movq (%rax), %r14
    subq $8, %rax
    movq (%rax), %r13
    subq $8, %rax
    movq (%rax), %r12
    subq $8, %rax
    movq (%rax), %r11
    subq $8, %rax
    movq (%rax), %r10
    subq $8, %rax
    movq (%rax), %r9
    subq $8, %rax
    movq (%rax), %r8
    subq $8, %rax
    movq (%rax), %rdi // RSP
    movq %rdi, 24(%rsp)
    subq $8, %rax
    movq (%rax), %rbp
    subq $8, %rax
    movq (%rax), %rdi
    subq $8, %rax
    movq (%rax), %rsi
    subq $8, %rax
    movq (%rax), %rdx
    subq $8, %rax
    movq (%rax), %rcx
    subq $8, %rax
    movq (%rax), %rbx
    subq $8, %rax
    movq (%rax), %rax
    iretq
.size taskSwitchKernelMainToUserIret, . - taskSwitchKernelMainToUserIret

.global interruptContextSwitchBody
.type interruptContextSwitchBody, @function
interruptContextSwitchBody:
    // Save vector state, get pointer to register storage
    movq %gs:ThreadLocalVariables.self_pointer, %rax
    leaq ThreadLocalVariables.current_process.registers.vector_store(%rax), %rax
    fxsave64 (%rax)
    movq %gs:ThreadLocalVariables.self_pointer, %rax
    leaq ThreadLocalVariables.current_process.registers.rax(%rax), %rax
    addq $8, %rax
    // Save registers
    movq %rbx, (%rax)
    addq $8, %rax
    movq %rcx, (%rax)
    addq $8, %rax
    movq %rdx, (%rax)
    addq $8, %rax
    movq %rsi, (%rax)
    addq $8, %rax
    movq %rdi, (%rax)
    addq $8, %rax
    movq %rbp, (%rax)
    addq $8, %rax
    movq 24(%rsp), %rbx // RSP
    movq %rbx, (%rax)
    addq $8, %rax
    movq %r8, (%rax)
    addq $8, %rax
    movq %r9, (%rax)
    addq $8, %rax
    movq %r10, (%rax)
    addq $8, %rax
    movq %r11, (%rax)
    addq $8, %rax
    movq %r12, (%rax)
    addq $8, %rax
    movq %r13, (%rax)
    addq $8, %rax
    movq %r14, (%rax)
    addq $8, %rax
    movq %r15, (%rax)
    addq $8, %rax
    movq (%rsp), %rbx // RIP
    movq %rbx, (%rax)
    addq $8, %rax
    movq 16(%rsp), %rbx // RFLAGS
    movq %rbx, (%rax)
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
.size interruptContextSwitchBody, . - interruptContextSwitchBody

.global timerContextSwitchHandler
.type timerContextSwitchHandler, @function
timerContextSwitchHandler:
    // Make sure interrupts are disabled, so we don't have issues with the stack being overwritten
    cli
    // Return to code if interrupt happened in kernel mode
    cmpq $GDT.kernel_code, 8(%rsp)
    jne 0f
    iretq
0:
    // Swap GS to contain pointer to kernel thread local storage
    swapgs
    // Write yield reason
    movq $YieldInfo.Reason.timeout, %gs:ThreadLocalVariables.yield_info.reason
    // Save RAX
    movq %rax, %gs:ThreadLocalVariables.current_process.registers.rax
    // Jump to main interrupt context switch system
    jmp interruptContextSwitchBody
.size timerContextSwitchHandler, . - timerContextSwitchHandler
