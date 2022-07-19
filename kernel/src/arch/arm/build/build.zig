const std = @import("std");
const LibExeObjStep = std.build.LibExeObjStep;
const FixedLibExeObjStep = @import("fixed_libexeobjstep.zig").FixedLibExeObjStep;
const Builder = std.build.Builder;
const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;
const builtin = @import("builtin");

const MachineType = enum {
    qemu,
    raspberry_pi,
};

pub fn build(b: *Builder) void {
    const build_mode = b.standardReleaseOptions();
    const machine_type = b.option(
        MachineType,
        "machine-type",
        "Sets the target machine (QEMU default)",
    ) orelse .qemu;

    // Main kernel executable
    // const kernel = b.addExecutable("kernel_unstripped", "src/main.zig");
    const kernel = FixedLibExeObjStep.createExecutable(
        b,
        "kernel_unstripped",
        std.build.FileSource{ .path = "src/main.zig" },
        false,
    );
    kernel.addBuildOption(MachineType, "machine_type", machine_type);
    kernel.addBuildOption(bool, "multicore", b.option(
        bool,
        "multicore",
        "Enables or disables multicore, changes SMP data structures",
    ) orelse true);
    kernel.setBuildMode(build_mode);
    kernel.setOutputDir("out");
    kernel.force_pic = true;
    kernel.strip = false;
    kernel.code_model = .large;
    kernel.single_threaded = true;
    kernel.disable_stack_probing = true;
    switch (machine_type) {
        .qemu => @panic("QEMU machine type currently unimplemented"),
        .raspberry_pi => {
            kernel.setTarget(CrossTarget{
                .cpu_arch = .arm,
                .os_tag = .freestanding,
                .abi = .eabihf,
            });
            kernel._setLlvmCpu("arm1176jzf_s");
            kernel.addAssemblyFile("src/platform/raspberry_pi/rpi_entry_32.s");
            kernel.setLinkerScriptPath("src/platform/raspberry_pi/build/link_32.ld");
        },
    }

    const kernel_stripped = b.addSystemCommand(&[_][]const u8{
        "llvm-objcopy",
        "--strip-debug",
        "out/kernel_unstripped",
        "out/kernel",
    });
    kernel_stripped.step.dependOn(&kernel.step);

    b.default_step.dependOn(&kernel_stripped.step);
}
