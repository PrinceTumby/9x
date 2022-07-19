.macro exception name, exception_type, message
  1:
  .ascii "\message"
  2:
  .global \name;
  .type \name, @function;
  \name:
    cli
    // Panic if exception happened in kernel code
    cmpq $GDT.kernel_code, 8(%rsp)
    jne 0f
    movq (%rsp), %rdx
    andq $-16, %rsp
    movq $1b, %rdi
    movq $2b - 1b, %rsi
    pushq %rdx
    pushq %rbp
    movq %rsp, %rbp
    callq exceptionMessage
  0:
    // Swap GS to contain pointer to kernel thread local storage
    swapgs
    // Write yield information
    movq $YieldInfo.Reason.exception, %gs:ThreadLocalVariables.yield_info.reason
    movq \exception_type, %gs:ThreadLocalVariables.yield_info.exception_type
    movq $0, %gs:ThreadLocalVariables.yield_info.exception_error_code
    movq $0, %gs:ThreadLocalVariables.yield_info.page_fault_address
    // Save RAX
    movq %rax, %gs:ThreadLocalVariables.current_process.registers.rax
    // Jump to main interrupt context switch system
    jmp interruptContextSwitchBody
  .size \name, . - \name
.endm

.macro pageFaultException name, exception_type, message
  1:
  .ascii "\message"
  2:
  .global \name;
  .type \name, @function;
  \name:
    cli
    // Panic if exception happened in kernel code
    cmpq $GDT.kernel_code, 16(%rsp)
    jne 0f
    movq 32(%rsp), %rbp
    movq 8(%rsp), %r8
    movq (%rsp), %rdx
    andq $-16, %rsp
    movq $1b, %rdi
    movq $2b - 1b, %rsi
    movq %cr2, %rcx
    pushq %r8
    pushq %rbp
    movq %rsp, %rbp
    callq pageFaultExceptionMessage
  0:
    // Swap GS to contain pointer to kernel thread local storage
    swapgs
    // Save RAX
    movq %rax, %gs:ThreadLocalVariables.current_process.registers.rax
    // Write yield information
    movq $YieldInfo.Reason.exception, %gs:ThreadLocalVariables.yield_info.reason
    movq \exception_type, %gs:ThreadLocalVariables.yield_info.exception_type
    popq %rax
    movq %rax, %gs:ThreadLocalVariables.yield_info.exception_error_code
    movq %cr2, %rax
    movq %rax, %gs:ThreadLocalVariables.yield_info.page_fault_address
    // Jump to main interrupt context switch system
    jmp interruptContextSwitchBody
  .size \name, . - \name
.endm

.macro exceptionErrCode name, exception_type, message
  1:
  .ascii "\message"
  2:
  .global \name;
  .type \name, @function;
  \name:
    cli
    // Panic if exception happened in kernel code
    cmpq $GDT.kernel_code, 16(%rsp)
    jne 0f
    movq 8(%rsp), %rcx
    movq (%rsp), %rdx
    andq $-16, %rsp
    movq $1b, %rdi
    movq $2b - 1b, %rsi
    pushq %rcx
    pushq %rbp
    movq %rsp, %rbp
    callq exceptionMessageWithErrCode
  0:
    // Swap GS to contain pointer to kernel thread local storage
    swapgs
    // Save RAX
    movq %rax, %gs:ThreadLocalVariables.current_process.registers.rax
    // Write yield information
    movq $YieldInfo.Reason.exception, %gs:ThreadLocalVariables.yield_info.reason
    movq \exception_type, %gs:ThreadLocalVariables.yield_info.exception_type
    popq %rax
    movq %rax, %gs:ThreadLocalVariables.yield_info.exception_error_code
    movq $0, %gs:ThreadLocalVariables.yield_info.page_fault_address
    // Jump to main interrupt context switch system
    jmp interruptContextSwitchBody
  .size \name, . - \name
.endm

exception divideByZero, $ExceptionType.divide_by_zero, "EXCEPTION: DIVIDE BY ZERO"
exception debug, $ExceptionType.debug, "EXCEPTION: DEBUG"
exception nonMaskableInterrupt, $ExceptionType.non_maskable_interrupt, "EXCEPTION: NON MASKABLE INTERRUPT"
exception overflow, $ExceptionType.overflow, "EXCEPTION: OVERFLOW"
exception boundRangeExceeded, $ExceptionType.bound_range_exceeded, "EXCEPTION: BOUND RANGE EXCEEDED"
exception invalidOpcode, $ExceptionType.invalid_opcode, "EXCEPTION: INVALID OPCODE"
exception deviceNotAvailable, $ExceptionType.device_not_available, "EXCEPTION: DEVICE NOT AVAILABLE"
exceptionErrCode doubleFault, $ExceptionType.double_fault, "EXCEPTION: DOUBLE FAULT"
exceptionErrCode invalidTss, $ExceptionType.invalid_tss, "EXCEPTION: INVALID TSS"
exceptionErrCode segmentNotPresent, $ExceptionType.segment_not_present, "EXCEPTION: SEGMENT NOT PRESENT"
exceptionErrCode stackSegmentFault, $ExceptionType.stack_segment_fault, "EXCEPTION: STACK SEGMENT FAULT"
exceptionErrCode generalProtectionFault, $ExceptionType.general_protection_fault, "EXCEPTION: GENERAL PROTECTION FAULT"
pageFaultException pageFault, $ExceptionType.page_fault, "EXCEPTION: PAGE FAULT"
exception x87FloatingPoint, $ExceptionType.x87_floating_point, "EXCEPTION: x87 FLOATING POINT"
exceptionErrCode alignmentException, $ExceptionType.alignment_check, "EXCEPTION: ALIGNMENT EXCEPTION"
exception machineCheck, $ExceptionType.machine_check, "EXCEPTION: MACHINE CHECK"
exception simdFloatingPoint, $ExceptionType.simd_floating_point, "EXCEPTION: SIMD FLOATING POINT"
exception virtualization, $ExceptionType.virtualization, "EXCEPTION: VIRTUALIZATION"
exceptionErrCode security, $ExceptionType.security, "EXCEPTION: SECURITY"
