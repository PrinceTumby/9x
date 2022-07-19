const std = @import("std");
const process = @import("process.zig");
const Allocator = std.mem.Allocator;
const SegmentedList = std.SegmentedList;
const StringHashMap = std.StringHashMap;
const Process = process.Process;

const max_path_segment_len: usize = 256;
const max_path_len: usize = 4096;

pub const Namespace = struct {
    allocator: *Allocator,
    mounts: StringHashMap(SegmentedList([]const u8))
};

pub const MountPoint = struct {
    mount_path: []const u8,
    filesystem: Filesystem,
};

pub const Filesystem = struct {
    process: *Process,
    // Some kind of pipe for the process
};
