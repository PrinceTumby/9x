const std = @import("std");
const Builder = std.build.Builder;
const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;
const builtin = @import("builtin");

const BuildFunc = fn(b: *Builder) void;

const cpu_arch_map = std.ComptimeStringMap(Target.Cpu.Arch, .{
    .{ "x86_64", .x86_64 },
    .{ "riscv64", .riscv64 },
});

pub fn build(b: *Builder) void {
    const cpu_arch: Target.Cpu.Arch = if (b.option(
        []const u8,
        "cpu-arch",
        "The CPU architecture to build for",
    )) |cpu_arch_string|
        cpu_arch_map.get(cpu_arch_string) orelse @panic("Unrecognized CPU architecture")
    else
        builtin.cpu.arch;

    // Run architecture specific build function
    switch (cpu_arch) {
        .x86_64 => @import("src/arch/x86_64/build/build.zig").build(b),
        .riscv64 => @import("src/arch/riscv64/build/build.zig").build(b),
        else => @panic("Unsupported target architecture"),
    }
}
