//! Compile time options for building the 9x kernel

pub const arch = @import("arch.zig");

/// Controls whether multicore support is enabled.
/// This turns some SMP primitives into empty data structures.
pub const multicore_support = true;
