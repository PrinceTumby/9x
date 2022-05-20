//! Paging structures for x86_64

const std = @import("std");
const Error = std.mem.Allocator.Error;
const root = @import("root");
const logger = std.log.scoped(.x86_64_internals_paging);

pub const PageTable = [512]PageTableEntry;

// TODO Make this a bit field struct
pub const PageTableEntry = packed struct {
    __data: u64,

    const Self = @This();

    pub fn fromU64(entry: u64) Self {
        return PageTableEntry{ .__data = entry };
        // return @ptrCast(*const Self, &entry).*;
    }

    pub fn isPresent(self: Self) bool {
        return self.__data & 0x0000000000000001 == 1;
    }

    pub fn isWritable(self: Self) bool {
        return self.__data & 0x0000000000000002 == 1;
    }

    pub fn isUserAccessable(self: Self) bool {
        return self.__data & 0x0000000000000004 == 1;
    }

    pub fn writeThroughCachingEnabled(self: Self) bool {
        return self.__data & 0x0000000000000008 == 1;
    }

    pub fn cacheDisabled(self: Self) bool {
        return self.__data & 0x0000000000000010 == 1;
    }

    pub fn isAccessed(self: Self) bool {
        return self.__data & 0x0000000000000020 == 1;
    }

    pub fn isDirty(self: Self) bool {
        return self.__data & 0x0000000000000040 == 1;
    }

    pub fn isHugePage(self: Self) bool {
        return self.__data & 0x0000000000000080 == 1;
    }

    pub fn isGlobal(self: Self) bool {
        return self.__data & 0x0000000000000100 == 1;
    }

    pub fn isNoExecute(self: Self) bool {
        return self.__data & 0x8000000000000000 == 1;
    }

    pub const framebuffer_flags: u64 = 0x8000000000000083;

    pub const InputFlags = struct {
        present: bool = false,
        writable: bool = false,
        user_accessable: bool = false,
        write_through_caching_enabled: bool = false,
        cache_disabled: bool = false,
        accessed: bool = false,
        dirty: bool = false,
        huge_page: bool = false,
        global: bool = false,
        physical_address: usize = 0,
        no_execute: bool = false,
    };

    pub fn generateU64(flags: InputFlags) u64 {
        return @as(u64, 0) |
            @as(u64, if (flags.present) 0x1 else 0) |
            @as(u64, if (flags.writable) 0x2 else 0) |
            @as(u64, if (flags.user_accessable) 0x4 else 0) |
            @as(u64, if (flags.write_through_caching_enabled) 0x8 else 0) |
            @as(u64, if (flags.cache_disabled) 0x10 else 0) |
            @as(u64, if (flags.accessed) 0x20 else 0) |
            @as(u64, if (flags.dirty) 0x40 else 0) |
            @as(u64, if (flags.huge_page) 0x80 else 0) |
            @as(u64, if (flags.global) 0x100 else 0) |
            @as(u64, if (flags.no_execute) 0x8000_0000_0000_0000 else 0) |
            @as(u64, flags.physical_address & 0x000FFFFFFFFFF000);
    }

    pub fn getAddress(self: Self) u64 {
        const addr = self.__data & 0x000FFFFFFFFFF000;
        if (addr & 0x0008000000000000 != 0) {
            return addr | 0xFFF0000000000000;
        } else {
            return addr;
        }
    }
};

/// Translates a virtual address to a physical address
pub fn translateAddress(address: u64) ?u64 {
    // Query memory map
    const mem_map = PageTableEntry.fromU64(asm ("movq %%cr3, %[ret]"
        : [ret] "=r" (-> usize)
    ));
    const level_masks = [_]u64{
        0xFF80_0000_0000,
        0x007F_C000_0000,
        0x0000_3FE0_0000,
        0x0000_001F_F000,
    };
    var current_address = mem_map.getAddress();
    for (level_masks) |level_mask, i| {
        const current_table = @intToPtr(*align(4096) PageTable, current_address);
        const index = @truncate(
            u9,
            (level_mask & address) >> @truncate(u6, (3 - i) * 9 + 12),
        );
        const entry = &current_table[index];
        if (!entry.isPresent()) {
            return null;
        }
        if (entry.isHugePage()) {
            @panic("huge pages not supported");
        }
        current_address = entry.getAddress();
    }
    return current_address | (address & 0xFFF);
}

/// Aligns the address down to the nearest page boundary
pub inline fn alignToPage(address: usize) usize {
    return address & ~@as(usize, 0xFFF);
}
