const std = @import("std");

const logger = std.log.scoped(.raspberry_pi_atags);

pub const TagHeader = extern struct {
    /// Size of the tag including this header
    size: u32,
    tag_type: TagType,
    tag_info: TagInfo,

    pub const TagType = enum(u32) {
        end = 0x00000000,
        core = 0x54410001,
        mem = 0x54410002,
        video_text = 0x5441003,
        ram_disk = 0x5441004,
        initrd2 = 0x54420005,
        serial = 0x54410006,
        revision = 0x54410007,
        video_lfb = 0x54410008,
        cmdline = 0x54410009,
        _,
    };

    pub const TagInfo = extern union {
        core: u32,
    };
};

pub fn parse(start_tag: *TagHeader) void {
    logger.debug("Tags:", .{});
    var current_tag_address = @ptrToInt(start_tag);
    var current_tag = start_tag;
    logger.debug("0x{X}", .{@enumToInt(current_tag.tag_type)});
    while (current_tag.tag_type != .end) : ({
        current_tag_address += current_tag.size * 4;
        current_tag = @intToPtr(*TagHeader, current_tag_address);
    }) {
        logger.debug("{} tag", .{current_tag.tag_type});
    }
}
