const builtin = @import("builtin");
const Interface = @import("root").zig_extensions.Interface;

pub usingnamespace switch (builtin.cpu.arch) {
    .arm => @import("arch/arm.zig"),
    .aarch64 => @import("arch/aarch64.zig"),
    .riscv64 => @import("arch/riscv64.zig"),
    .x86_64 => @import("arch/x86_64.zig"),
    else => |arch| @compileError("Unsupported arch: " ++ @tagName(arch)),
};
