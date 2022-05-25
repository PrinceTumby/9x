.text
.code64

message_1_ptr: .ascii "Hello from userspace!"
message_1_len = . - message_1_ptr
message_2_ptr: .ascii "Wow! Two round trips!"
message_2_len = . - message_2_ptr

.global _start
.type _start, @function
_start:
    // Load and print messages
    leaq message_1_ptr, %rdi
    movq $message_1_len, %rsi
    movq $0, %rax
    syscall
    leaq message_2_ptr, %rdi
    movq $message_2_len, %rsi
    movq $0, %rax
    syscall
    leaq loop(%rip), %rax
    loop:
    jmp *%rax

.size _start, . - _start
