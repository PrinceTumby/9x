const std = @import("std");
const Allocator = std.mem.Allocator;
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Mode = std.builtin.Mode;
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *Builder, mode: Mode, target: CrossTarget) *LibExeObjStep {
    const multiboot2_elf = b.addExecutable("multiboot2_stub", "boot/multiboot2/src/main.zig");
    multiboot2_elf.setBuildMode(mode);
    multiboot2_elf.setTarget(target);
    multiboot2_elf.addAssemblyFile("boot/multiboot2/src/entry.s");
    multiboot2_elf.setLinkerScriptPath(.{ .path = "boot/multiboot2/build/link.ld" });
    multiboot2_elf.setOutputDir("boot/multiboot2/out");
    multiboot2_elf.disable_stack_probing = true;
    multiboot2_elf.red_zone = false;
    multiboot2_elf.strip = true;
    return multiboot2_elf;
}
