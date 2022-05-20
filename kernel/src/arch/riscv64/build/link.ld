ENTRY(start);

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

/* MEMORY { */
/*     RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M */
/* } */

SECTIONS {
    . = 0x80200000;
    .text : ALIGN(4K) {
        KEEP(*(.init*));
        *(.text*);
    }
    .bss : ALIGN(4K) {
        PROVIDE(bss_start = .);
        *(.bss*);
        *(COMMON);
        . += 4096;
        PROVIDE(stack_top = .);
        . += 4096;
        PROVIDE(__global_pointer$ = .);
        PROVIDE(bss_end = .);
    }
    .rodata : ALIGN(4K) {
        *(.rodata);
    }
    .data : ALIGN(4K) {
        *(.data);
    }
    /* PROVIDE(__stack_top = ORIGIN(RAM) + LENGTH(RAM)); */
    /DISCARD/ : { *(.eh_frame) *(.comment) *(.interp) *(.note.gnu.build-id) }
}

/* SECTIONS */
/* { */
/*     . = STACK_BASE; */
/*     .stack (NOLOAD) : { */
/*         . = STACK_BASE + 0xFF0; */
/*     } :stack */
/*     . = KERNEL_BASE; */
/*     .init : { */
/*         KEEP(*(.init*)) */
/*     } :init */
/*     . = KERNEL_BASE + 0x00002000; */
/*     .text : { */
/*         KEEP(*(.multiboot*)) */
/*         *(.text*) */
/*     } :text */
/*     . = KERNEL_BASE + 0x10000000; */
/*     .data : { */
/*         *(.data*) */
/*     } :data */
/*     . = KERNEL_BASE + 0x40000000; */
/*     .rodata : { */
/*         *(.rodata*) */
/*     } :rodata */
/*     . = KERNEL_BASE + 0x60000000; */
/*     .bss : { */
/*         *(.bss*) */
/*         *(COMMON) */
/*     } :bss */
/*     /1* Error if kernel is larger than limit *1/ */
/*     . = KERNEL_END; */
/*     /DISCARD/ : { *(.eh_frame) *(.comment) } */
/* } */
