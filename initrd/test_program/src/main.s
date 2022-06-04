.data

message_ptr:
.ascii "Hello from process "
message_pid_char: .byte 0
.ascii "!"
message_len = . - message_ptr

.text
.code64

.global _start
.type _start, @function
_start:
    // Get PID, change message ID character
    movq $0, %rax
    syscall
    addq $48, %rax
    movb %al, message_pid_char
    leaq message_ptr, %rdi
    movq $message_len, %rsi
    movq $1, %rax
    syscall
    movq $1, %rax
    syscall
    // Infinitely yield in loop
    loop:
    movq $2, %rax
    syscall
    jmp loop

.size _start, . - _start
