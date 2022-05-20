.text
.code64

.global _start
.type _start, @function
_start:
    leaq loop(%rip), %rax
    loop:
    jmp *%rax
