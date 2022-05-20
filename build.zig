const std = @import("std");
const Builder = std.build.Builder;
const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;
const builtin = @import("builtin");

pub fn build(b: *Builder) void {
    const cpu_arch = b.option([]const u8, "cpu-arch", "The CPU architecture to build for")
        orelse @tagName(builtin.cpu.arch);

    const cpu_arch_flag = b.fmt("-Dcpu-arch={s}", .{cpu_arch});

    const build_kernel_step = b.addSystemCommand(&[_][]const u8{
        "zig",
        "build",
        "--build-file",
        "kernel/build.zig",
        cpu_arch_flag,
        // "-Drelease-safe=true",
    });

    const copy_kernel_debug_symbols_step = b.addSystemCommand(&[_][]const u8{
        "objcopy",
        "--only-keep-debug",
        "kernel/out/kernel_unstripped",
        "dev/kernel.sym",
    });
}
