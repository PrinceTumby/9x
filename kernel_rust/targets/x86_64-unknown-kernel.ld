OUTPUT_FORMAT(elf64-x86-64)
ENTRY(limine_entry)

KERNEL_BASE = 0xffffffff80000000;
KERNEL_END = 0xffffffffffffffff;
TEMP_MAPPING_AREA_BASE = 0xffffffff10000000;
TEMP_MAPPING_AREA_END = 0xffffffff10001fff;
LOCAL_APIC_BASE = 0xffffffff10002000;
LOCAL_APIC_END = 0xffffffff10002fff;
/* Currently unused, Limine already gives us a higher half stack */
/* Currently we only use 70k of this space (64k stack, 4k guard page) */
/* STACK_BASE = 0xffffffff20000000; */
/* STACK_ADDRESS = 0xffffffff20010ff0; */
/* STACK_END = 0xffffffff2001ffff; */
TLS = 0xffffffff20000000;
TLS_END = 0xffffffff2fffffff;
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
    init PT_LOAD FLAGS(0x7); /* Read, Write, Execute */
    text PT_LOAD FLAGS(0x5); /* Read and Execute */
    data PT_LOAD;
    rodata PT_LOAD FLAGS(0x4); /* Read only */
    bss PT_LOAD;
}

SECTIONS
{
    . = KERNEL_BASE;
    .init : {
        KEEP(*(.init*))
    } :init
    .text ALIGN(4K) : {
        *(.text*)
    } :text
    /* PROVIDE(__etext = .); */
    .data ALIGN(4K) : {
        *(.data*)
    } :data
    .rodata ALIGN(4K) : {
        *(.rodata*)
    } :rodata
    .bss ALIGN(4K) : {
        *(.bss*)
        *(COMMON)
    } :bss
    . = ALIGN(8);
    /* PROVIDE(__eh_frame = .); */
    /* .eh_frame : { */
    /*     KEEP (*(.eh_frame)) */
    /*     *(.eh_frame.*) */
    /* } */
    /* Error if kernel is larger than limit */
    . = KERNEL_END;

    /DISCARD/ : {
        *(.comment*)
        *(.eh_frame*)
        *(.gcc_except_table*)
        *(.note*)
    }
}
