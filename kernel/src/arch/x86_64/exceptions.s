.macro exception name, exception_type, message
  1:
  .ascii "\message"
  2:
  .global \name;
  .type \name, @function;
  \name:
    cli
    // Panic if exception happened in kernel code
    // cmpq $KernelGdt.kernel_code, 8(%rsp)
    // jne 0f
    movq (%rsp), %rdx
    andq $-16, %rsp
    movq $1b, %rdi
    movq $2b - 1b, %rsi
    pushq %rdx
    pushq %rbp
    movq %rsp, %rbp
    callq exception_message
  // 0:
  //   // Swap GS to contain pointer to kernel thread local storage
  //   swapgs
  //   // Write yield information
  //   movq $YieldReason.Exception, %gs:ThreadLocalStorage.yield_info.reason
  //   movq \exception_type, %gs:ThreadLocalStorage.yield_info.exception_type
  //   movq $0, %gs:ThreadLocalStorage.yield_info.exception_error_code
  //   movq $0, %gs:ThreadLocalStorage.yield_info.page_fault_address
  //   // Save RAX
  //   movq %rax, %gs:ThreadLocalStorage.current_process.registers.rax
  //   // Jump to main interrupt context switch system
  //   jmp interrupt_context_switch_body
  .size \name, . - \name
.endm

.macro page_fault_exception name, exception_type, message
  1:
  .ascii "\message"
  2:
  .global \name;
  .type \name, @function;
  \name:
    cli
    // Panic if exception happened in kernel code
    // cmpq $KernelGdt.kernel_code, 16(%rsp)
    // jne 0f
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
    callq page_fault_exception_message
  // 0:
  //   // Swap GS to contain pointer to kernel thread local storage
  //   swapgs
  //   // Save RAX
  //   movq %rax, %gs:ThreadLocalStorage.current_process.registers.rax
  //   // Write yield information
  //   movq $YieldReason.Exception, %gs:ThreadLocalStorage.yield_info.reason
  //   movq \exception_type, %gs:ThreadLocalStorage.yield_info.exception_type
  //   popq %rax
  //   movq %rax, %gs:ThreadLocalStorage.yield_info.exception_error_code
  //   movq %cr2, %rax
  //   movq %rax, %gs:ThreadLocalStorage.yield_info.page_fault_address
  //   // Jump to main interrupt context switch system
  //   jmp interrupt_context_switch_body
  .size \name, . - \name
.endm

.macro exception_err_code name, exception_type, message
  1:
  .ascii "\message"
  2:
  .global \name;
  .type \name, @function;
  \name:
    cli
    // Panic if exception happened in kernel code
    // cmpq $KernelGdt.kernel_code, 16(%rsp)
    // jne 0f
    movq 8(%rsp), %rcx
    movq (%rsp), %rdx
    andq $-16, %rsp
    movq $1b, %rdi
    movq $2b - 1b, %rsi
    pushq %rcx
    pushq %rbp
    movq %rsp, %rbp
    callq exception_message_with_err_code
  // 0:
  //   // Swap GS to contain pointer to kernel thread local storage
  //   swapgs
  //   // Save RAX
  //   movq %rax, %gs:ThreadLocalStorage.current_process.registers.rax
  //   // Write yield information
  //   movq $YieldReason.Exception, %gs:ThreadLocalStorage.yield_info.reason
  //   movq \exception_type, %gs:ThreadLocalStorage.yield_info.exception_type
  //   popq %rax
  //   movq %rax, %gs:ThreadLocalStorage.yield_info.exception_error_code
  //   movq $0, %gs:ThreadLocalStorage.yield_info.page_fault_address
  //   // Jump to main interrupt context switch system
  //   jmp interrupt_context_switch_body
  .size \name, . - \name
.endm

exception divide_by_zero, $ExceptionType.DivideByZero, "EXCEPTION: DIVIDE BY ZERO"
exception debug, $ExceptionType.Debug, "EXCEPTION: DEBUG"
exception non_maskable_interrupt, $ExceptionType.NonMaskableInterrupt, "EXCEPTION: NON MASKABLE INTERRUPT"
exception overflow, $ExceptionType.Overflow, "EXCEPTION: OVERFLOW"
exception bound_range_exceeded, $ExceptionType.BoundRangeExceeded, "EXCEPTION: BOUND RANGE EXCEEDED"
exception invalid_opcode, $ExceptionType.InvalidOpcode, "EXCEPTION: INVALID OPCODE"
exception device_not_available, $ExceptionType.DeviceNotAvailable, "EXCEPTION: DEVICE NOT AVAILABLE"
exception_err_code double_fault, $ExceptionType.DoubleFault, "EXCEPTION: DOUBLE FAULT"
exception_err_code invalid_tss, $ExceptionType.InvalidTss, "EXCEPTION: INVALID TSS"
exception_err_code segment_not_present, $ExceptionType.SegmentNotPresent, "EXCEPTION: SEGMENT NOT PRESENT"
exception_err_code stack_segment_fault, $ExceptionType.StackSegmentFault, "EXCEPTION: STACK SEGMENT FAULT"
exception_err_code general_protection_fault, $ExceptionType.GeneralProtectionFault, "EXCEPTION: GENERAL PROTECTION FAULT"
page_fault_exception page_fault, $ExceptionType.PageFault, "EXCEPTION: PAGE FAULT"
exception x87_floating_point, $ExceptionType.X87FloatingPoint, "EXCEPTION: x87 FLOATING POINT"
exception_err_code alignment_exception, $ExceptionType.AlignmentCheck, "EXCEPTION: ALIGNMENT EXCEPTION"
exception machine_check, $ExceptionType.MachineCheck, "EXCEPTION: MACHINE CHECK"
exception simd_floating_point, $ExceptionType.SimdFloatingPoint, "EXCEPTION: SIMD FLOATING POINT"
exception virtualization, $ExceptionType.Virtualization, "EXCEPTION: VIRTUALIZATION"
exception_err_code security, $ExceptionType.Security, "EXCEPTION: SECURITY"
