OUTPUT_FORMAT(elf64-x86-64)
ENTRY(start64)

PHDRS
{
    text PT_LOAD;
    data PT_LOAD;
    rodata PT_LOAD;
    bss PT_LOAD;
}
SECTIONS
{
    . = 0x100000;
    .text : {
        *(.multiboot*)
        *(.text*)
    } :text
    .data : {
        *(.data*)
    } :data
    .rodata : {
        *(.rodata*)
        . = ALIGN(4096);
    } :rodata
    bss_start = .;
    .bss : {
        *(.bss*)
        *(COMMON)
    } :bss
    bss_end = .;

    /DISCARD/ : { *(.eh_frame) *(.comment) }
}
