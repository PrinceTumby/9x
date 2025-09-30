use core::arch::global_asm;

global_asm!(include_str!("init.s"), options(raw));
