const std = @import("std");
const Builder = std.build.Builder;
const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;
const builtin = @import("builtin");

const BuildFunc = fn(b: *Builder) void;

const supported_archs = [_][]const u8{
    "arm",
    "aarch64",
    "riscv64",
    "x86_64",
};

const cpu_arch_map = std.ComptimeStringMap(Target.Cpu.Arch, .{
    .{ "arm", .arm },
    .{ "aarch64", .aarch64 },
    .{ "riscv64", .riscv64 },
    .{ "x86_64", .x86_64 },
});

fn missingBuildFunc(_b: *Builder) void {
    @panic("Unsupported CPU architecture");
}

/// Imports each architecture specific build script from "src/arch/{ARCH}/build/build.zig"
const build_functions: [256]BuildFunc = comptime blk: {
    var funcs: [256]BuildFunc = [1]BuildFunc{missingBuildFunc} ** 256;
    for (supported_archs) |arch_string| {
        const arch = cpu_arch_map.get(arch_string)
            orelse @compileError("Architecture " ++ arch_string ++ "does not exist in build map");
        funcs[@enumToInt(arch)] = @import("src/arch/" ++ arch_string ++ "/build/build.zig").build;
    }
    break :blk funcs;
};

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
    build_functions[@enumToInt(cpu_arch)](b);
}
