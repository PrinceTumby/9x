//! Paging structures for x86_64

const std = @import("std");
const Error = std.mem.Allocator.Error;
const root = @import("root");
const logger = std.log.scoped(.x86_64_internals_paging);

pub const PageTable = [512]PageTableEntry;

// TODO Make this a bit field struct
pub const PageTableEntry = packed struct {
    __data: u64,

    pub fn fromU64(entry: u64) PageTableEntry {
        return PageTableEntry{ .__data = entry };
    }

    pub fn isPresent(self: PageTableEntry) bool {
        return self.__data & 0x0000000000000001 != 0;
    }

    pub fn isWritable(self: PageTableEntry) bool {
        return self.__data & 0x0000000000000002 != 0;
    }

    pub fn isUserAccessable(self: PageTableEntry) bool {
        return self.__data & 0x0000000000000004 != 0;
    }

    pub fn writeThroughCachingEnabled(self: PageTableEntry) bool {
        return self.__data & 0x0000000000000008 != 0;
    }

    pub fn cacheDisabled(self: PageTableEntry) bool {
        return self.__data & 0x0000000000000010 != 0;
    }

    pub fn isAccessed(self: PageTableEntry) bool {
        return self.__data & 0x0000000000000020 != 0;
    }

    pub fn isDirty(self: PageTableEntry) bool {
        return self.__data & 0x0000000000000040 != 0;
    }

    pub fn isHugePage(self: PageTableEntry) bool {
        return self.__data & 0x0000000000000080 != 0;
    }

    pub fn isGlobal(self: PageTableEntry) bool {
        return self.__data & 0x0000000000000100 != 0;
    }

    pub fn isNoExecute(self: PageTableEntry) bool {
        return self.__data & 0x8000000000000000 != 0;
    }

    pub fn getKernelData1(self: PageTableEntry) u3 {
        return @truncate(u3, (self.__data & 0xE00) >> 9);
    }

    pub fn setKernelData1(self: *PageTableEntry, data: u3) void {
        self.__data = (self.__data & ~@as(u64, 0xE00)) | (@as(u64, data) << 9);
    }

    pub fn getKernelData2(self: PageTableEntry) u7 {
        return @truncate(u7, (self.__data & 0x7F0000000000000) >> 52);
    }

    pub fn setKernelData2(self: *PageTableEntry, data: u7) void {
        self.__data = (self.__data & ~@as(u64, 0x7F0000000000000)) | (@as(u64, data) << 52);
    }

    pub const framebuffer_flags: u64 = 0x8000000000000083;

    pub const InputFlags = struct {
        present: bool = false,
        writable: bool = false,
        user_accessible: bool = false,
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
            @as(u64, if (flags.user_accessible) 0x4 else 0) |
            @as(u64, if (flags.write_through_caching_enabled) 0x8 else 0) |
            @as(u64, if (flags.cache_disabled) 0x10 else 0) |
            @as(u64, if (flags.accessed) 0x20 else 0) |
            @as(u64, if (flags.dirty) 0x40 else 0) |
            @as(u64, if (flags.huge_page) 0x80 else 0) |
            @as(u64, if (flags.global) 0x100 else 0) |
            @as(u64, if (flags.no_execute) 0x8000_0000_0000_0000 else 0) |
            @as(u64, flags.physical_address & 0x000FFFFFFFFFF000);
    }

    pub fn getAddress(self: PageTableEntry) u64 {
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
