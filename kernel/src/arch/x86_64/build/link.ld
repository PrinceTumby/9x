OUTPUT_FORMAT(elf64-x86-64)
ENTRY(init64)

KERNEL_BASE = 0xffffffff80000000;
KERNEL_END = 0xffffffffffffffff;
TEMP_MAPPING_AREA_BASE = 0xffffffff10000000;
TEMP_MAPPING_AREA_END = 0xffffffff10001fff;
STACK_BASE = 0xffffffff20000000;
STACK_END = 0xffffffff2fffffff;
HEAP_BASE = 0xffffffff30000000;
HEAP_END = 0xffffffff4fffffff;
FRAMEBUFFER_START = 0xffffffff50000000;
FRAMEBUFFER_END = 0xffffffff5fdfffff;
FONT_START = 0xffffffff5fe00000;
FONT_END = 0xffffffff5fefffff;
TEXT_DISPLAY_START = 0xffffffff5ff00000;
TEXT_DISPLAY_END = 0xffffffff5fffffff;

PHDRS
{
    /* stack PT_LOAD; */
    init PT_LOAD;
    text PT_LOAD;
    data PT_LOAD;
    rodata PT_LOAD;
    bss PT_LOAD;
}
SECTIONS
{
    /* . = STACK_BASE; */
    /* .stack (NOLOAD) : { */
    /*     . = STACK_BASE + 0xFF0; */
    /* } :stack */
    . = KERNEL_BASE;
    .init : {
        KEEP(*(.init*))
    } :init
    .text : {
        KEEP(*(.multiboot*))
        *(.text*)
    } :text
    .data : {
        *(.data*)
    } :data
    .limine_reqs : {
        KEEP(*(.limine_reqs))
        QUAD(0)
    } :rodata
    .rodata : {
        *(.rodata*)
    } :rodata
    .bss : {
        *(.bss*)
        *(COMMON)
    } :bss
    /* Error if kernel is larger than limit */
    . = KERNEL_END;

    /DISCARD/ : { *(.eh_frame) *(.comment) }
}
