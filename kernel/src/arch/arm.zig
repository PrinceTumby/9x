//! Collection of modules related to kernel handling of the AArch64 architecture

const build_options = @import("build_options");

// Architecture internal support

// Architecture specific kernel feature implementation

// Re-export platform specific loggers
pub usingnamespace switch (@hasDecl(platform, "loggers")) {
    true => struct {
        pub const loggers = platform.loggers;
    },
    false => struct {},
};

pub const common = @import("arm/common.zig");

// Other platform exports

pub const platform = switch (build_options.machine_type) {
    .qemu => @compileError("QEMU machine type currently unsupported"),
    .raspberry_pi => @import("../platform/raspberry_pi.zig"),
};
comptime {
    _ = platform;
}

// Initialisation steps

const std = @import("std");
const logger = std.log.scoped(.arm);

pub fn stage1Init(_args: *KernelArgs) void {
    @panic("Stage 1 init unimplemented");
}

pub fn stage2Init(_args: *KernelArgs) void {
    @panic("Stage 2 init unimplemented");
}
