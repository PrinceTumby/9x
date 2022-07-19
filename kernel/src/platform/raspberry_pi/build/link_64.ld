ENTRY(_start);

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

SECTIONS
{
    . = 0x80000;
    .text : {
        KEEP(*(.init*))
        *(.text*)
    } :text
    . = ALIGN(4096);
    .data : {
        *(.data*)
    } :data
    . = ALIGN(4096);
    .rodata : {
        *(.rodata*)
    } :rodata
    . = ALIGN(4096);
    .bss : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4096);
        __bss_end = .;
    } :bss
    /DISCARD/ : { *(.eh_frame) *(.comment) }
}
