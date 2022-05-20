const builtin = @import("builtin");
const Interface = @import("root").zig_extensions.Interface;

pub usingnamespace switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    .riscv64 => @import("arch/riscv64.zig"),
    else => |arch| @compileError("Unsupported arch: " ++ @tagName(arch)),
};
