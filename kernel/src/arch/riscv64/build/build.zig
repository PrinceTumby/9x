const std = @import("std");
const LibExeObjStep = std.build.LibExeObjStep;
const Builder = std.build.Builder;
const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;
const builtin = @import("builtin");
const build_options = @import("../../../config/config.zig");

pub fn build(b: *Builder) void {
    const build_mode = b.standardReleaseOptions();

    // Main kernel executable
    const kernel = b.addExecutable("kernel", "src/main.zig");
    kernel.addAssemblyFile("src/arch/riscv64/entry.S");
    kernel.setBuildMode(build_mode);
    kernel.setTarget(CrossTarget{
        .cpu_arch = Target.Cpu.Arch.riscv64,
        .os_tag = Target.Os.Tag.freestanding,
        .abi = Target.Abi.none,
    });
    kernel.setLinkerScriptPath(.{ .path = "src/arch/riscv64/build/link.ld" });
    kernel.setOutputDir("out");
    kernel.force_pic = true;
    kernel.strip = false;
    kernel.code_model = .large;
    kernel.single_threaded = true;
    kernel.disable_stack_probing = true;

    b.default_step.dependOn(&kernel.step);
}
