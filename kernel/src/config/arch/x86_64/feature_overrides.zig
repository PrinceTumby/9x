//! Kernel feature overrides for the x86_64 architecture

pub const clocks = struct {
    /// Controls whether the kernel checks for a constant rate timestamp counter.
    /// If `null`, the kernel will check at runtime and use if available. If `true`,
    /// the kernel will always assume a constant rate timetamp counter exists without
    /// checking. If `false`, the kernel will disable usage of the timestamp counter.
    pub const constant_tsc: ?bool = null;
};
