//! Kernel implementation of allocating pages of physical memory

const std = @import("std");
const paging = @import("paging.zig");
const logger = std.log.scoped(.x86_64_kernel_page_allocation);
const range = @import("root").zig_extensions.range;
const PageTableEntry = paging.PageTableEntry;
const PageTable = paging.PageTable;

var page_allocator: PageAllocator = undefined;
pub const page_allocator_ptr = &page_allocator;

pub fn initPageAllocator(
    page_table_ptr: *[512]u64,
    mem_map_ptr: [*]u8,
    mem_map_size: usize,
    mapped_size: usize,
) void {
    page_allocator = PageAllocator.new(
        page_table_ptr,
        mem_map_ptr[0..mem_map_size],
        mapped_size / PageAllocator.page_size,
    );
}

// TODO Make this thread safe
pub const PageAllocator = struct {
    memory_map: []u8,
    num_pages: usize,
    num_pages_free: usize,
    page_table: PageTableEntry,

    pub const page_size: usize = 4096;
    pub const large_page_size: usize = page_size * 512;
    pub const byte_ratio: usize = page_size * 8;

    pub fn new(page_table: *[512]u64, memory_map: []u8, num_pages: usize) PageAllocator {
        // Find number of free pages
        var free_page_count: usize = 0;
        for (memory_map) |byte| {
            free_page_count += @popCount(u8, ~byte);
        }
        return PageAllocator{
            .memory_map = memory_map,
            .num_pages = num_pages,
            .num_pages_free = free_page_count,
            .page_table = PageTableEntry.fromU64(@ptrToInt(page_table)),
        };
    }

    pub inline fn getNumPagesUsed(self: *const PageAllocator) usize {
        return self.num_pages - self.num_pages_free;
    }

    /// Reserves a free page, returns the physical address if a page is found
    pub fn findAndReservePage(self: *PageAllocator) !*allowzero align(4096) [4096]u8 {
        for (self.memory_map) |*byte, group_index| {
            if (byte.* != 0xFF) {
                const index = @truncate(u3, @clz(u8, ~byte.*));
                if (group_index * 8 + index >= self.num_pages) {
                    return error.OutOfMemory;
                }
                byte.* |= @as(u8, 0x80) >> index;
                self.num_pages_free -= 1;
                return @intToPtr(
                    *allowzero align(4096) [4096]u8,
                    (group_index * byte_ratio) + (index * page_size),
                );
            }
        } else return error.OutOfMemory;
    }

    // TODO Add support for freeing huge pages
    /// Marks a page as no longer reserved.
    /// SAFETY: The caller is expected to no longer use references to this page
    pub fn freePage(self: *PageAllocator, address: u64) void {
        const byte_index = address / byte_ratio;
        const bit_offset = @truncate(u3, address / page_size);
        if (byte_index * 8 + bit_offset >= self.num_pages) return;
        self.memory_map[byte_index] &= ~(@as(u8, 0x80) >> bit_offset);
        self.num_pages_free += 1;
    }

    /// Returns whether an address is identity mapped
    pub fn isAddressIdentityMapped(self: *const PageAllocator, address: u64) bool {
        const level_masks = [_]u64{
            0xFF80_0000_0000,
            0x007F_C000_0000,
            0x0000_3FE0_0000,
            0x0000_001F_F000,
        };
        const page_address = address & 0xFFFFFFFFFFFFF000;
        var current_address = self.page_table.getAddress();
        for (level_masks) |level_mask, i| {
            const current_table_ptr = @intToPtr(*align(4096) [512]u64, current_address);
            if (@ptrToInt(current_table_ptr) == page_address) {
                return true;
            }
            const current_table = @ptrCast(*align(4096) PageTable, current_table_ptr);
            const index = @truncate(
                u9,
                (level_mask & address) >> @truncate(u6, (3 - i) * 9 + 12),
            );
            const entry = current_table[index];
            if (!entry.isPresent()) return false;
            if (i == 3 or entry.isHugePage()) {
                const page_aligned_address = address & switch (i) {
                    // ZIG BUG: Have to specify these as u64 for some reason?
                    0 => @as(u64, 0xFFFF_FF80_C000_0000),
                    1 => @as(u64, 0xFFFF_FFFF_C000_0000),
                    2 => @as(u64, 0xFFFF_FFFF_FFE0_0000),
                    3 => @as(u64, 0xFFFF_FFFF_FFFF_F000),
                    else => unreachable,
                };
                return page_aligned_address == entry.getAddress();
            }
            current_address = entry.getAddress();
        }
        unreachable;
    }

    /// Returns the flags for an address, or `null` if the address isn't mapped
    pub fn getFlagsForAddress(
        self: *const PageAllocator,
        virtual_address: u64,
    ) ?PageTableEntry {
        const level_masks = [_]u64{
            0xFF80_0000_0000,
            0x007F_C000_0000,
            0x0000_3FE0_0000,
            0x0000_001F_F000,
        };
        var current_address = self.page_table.getAddress();
        var entry: PageTableEntry = undefined;
        for (level_masks) |level_mask, i| {
            const current_table_ptr = @intToPtr(*align(4096) [512]u64, current_address);
            const current_table = @ptrCast(*align(4096) PageTable, current_table_ptr);
            const index = @truncate(
                u9,
                (level_mask & virtual_address) >> @truncate(u6, (3 - i) * 9 + 12),
            );
            entry = current_table[index];
            // Return null if address not mapped
            if (!entry.isPresent()) return null;
            // Return immediately if entry is a huge page
            if (entry.isHugePage()) return entry;
            current_address = entry.getAddress();
        }
        return entry;
    }

    /// Maps physical memory to virtual memory at start offsets. Setting the
    /// physical start equal to the virtual start identity maps memory.
    /// `flags` are the flags applied to child pages.
    pub fn offsetMapMem(
        self: *PageAllocator,
        physical_start_address: u64,
        virtual_start_address: u64,
        flags: u64,
        size: u64,
        // use_huge_pages: bool,
    ) !void {
        const actual_physical_start_address = physical_start_address & 0x000FFFFFFFFFF000;
        const actual_flags = (flags & 0x80000000000001FE) | 0x1;
        const parent_flags = @as(u64, 0x0000000000000003);
        const level_masks = [_]u64{
            0xFF80_0000_0000,
            0x007F_C000_0000,
            0x0000_3FE0_0000,
            0x0000_001F_F000,
        };
        const num_pages = blk: {
            const lower_bound = std.mem.alignBackward(physical_start_address, 4096);
            const upper_bound = std.mem.alignBackward(physical_start_address +% size -% 1, 4096);
            break :blk ((upper_bound - lower_bound) >> 12) + 1;
        };
        for (range(num_pages)) |_, page_i| {
            const physical_address = actual_physical_start_address + (page_i << 12);
            const virtual_address = virtual_start_address + (page_i << 12);
            var current_address = self.page_table.getAddress();
            for (level_masks) |level_mask, i| {
                const current_table_ptr = @intToPtr(*align(4096) [512]u64, current_address);
                const current_table = @ptrCast(*align(4096) PageTable, current_table_ptr);
                const index = @truncate(
                    u9,
                    (level_mask & virtual_address) >> @truncate(u6, (3 - i) * 9 + 12),
                );
                var entry = current_table[index];
                // Allocate page if required
                if (!entry.isPresent()) {
                    if (i < 3) {
                        // Allocate parent entry
                        var new_address = @ptrCast(
                            [*]allowzero align(4096) u8,
                            try self.findAndReservePage(),
                        );
                        // Zero out page
                        for (new_address[0..4096]) |*byte| {
                            byte.* = 0;
                        }
                        // Set entry to new page table
                        const stripped_address = @ptrToInt(new_address) & 0x000FFFFFFFFFF000;
                        const new_entry: u64 = stripped_address | parent_flags;
                        current_table_ptr[index] = new_entry;
                        entry = PageTableEntry.fromU64(new_entry);
                        asm volatile ("invlpg (%[page])"
                            :
                            : [page] "r" (new_address)
                            : "memory"
                        );
                    } else {
                        // Offset map child entry
                        const stripped_address = physical_address & 0x000FFFFFFFFFF000;
                        const new_entry: u64 = stripped_address | actual_flags;
                        current_table_ptr[index] = new_entry;
                        asm volatile ("invlpg (%[page])"
                            :
                            : [page] "r" (virtual_address)
                            : "memory"
                        );
                    }
                }
                current_address = entry.getAddress();
            }
        }
    }

    /// Sets the flags of `(size / 4096) + 1` child pages starting at the given linear address
    pub fn changeFlags(
        self: *PageAllocator,
        start_address: u64,
        flags: u64,
        size: u64,
    ) void {
        const actual_start_address = start_address & 0x000FFFFFFFFFF000;
        const actual_flags = (flags & 0x80000000000001FE) | 0x1;
        const level_masks = [_]u64{
            0xFF80_0000_0000,
            0x007F_C000_0000,
            0x0000_3FE0_0000,
            0x0000_001F_F000,
        };
        const num_pages = blk: {
            const lower_bound = std.mem.alignBackward(start_address, 4096);
            const upper_bound = std.mem.alignBackward(start_address +% size -% 1, 4096);
            break :blk ((upper_bound - lower_bound) >> 12) + 1;
        };
        outer: for (range(num_pages)) |_, page_i| {
            const virtual_address = actual_start_address + (page_i << 12);
            var current_address = self.page_table.getAddress();
            for (level_masks) |level_mask, i| {
                const current_table_ptr = @intToPtr(*align(4096) [512]u64, current_address);
                const current_table = @ptrCast(*align(4096) PageTable, current_table_ptr);
                const index = @truncate(
                    u9,
                    (level_mask & virtual_address) >> @truncate(u6, (3 - i) * 9 + 12),
                );
                const entry = current_table[index];
                // Allocate page if required
                if (!entry.isPresent()) {
                    continue :outer;
                }
                if (i < 3) {
                    if (entry.isHugePage()) {
                        // TODO Implement huge page support
                        @panic("huge page support currently unimplemented");
                    }
                } else {
                    const new_entry = (entry.getAddress() & 0x000FFFFFFFFFF000) | actual_flags;
                    current_table_ptr[index] = new_entry;
                    asm volatile ("invlpg (%[page])"
                        :
                        : [page] "r" (virtual_address)
                        : "memory"
                    );
                }
                current_address = entry.getAddress();
            }
        }
    }

    /// Sets the flags of `(size / 4096) + 1` child pages starting at the given linear address
    pub fn changeFlagsRelaxing(
        self: *PageAllocator,
        start_address: u64,
        flags: u64,
        size: u64,
    ) void {
        const actual_start_address = start_address & 0x000FFFFFFFFFF000;
        const actual_flags = (flags & 0x80000000000001FE) | 0x1;
        const parent_relaxation_flags = (flags & 0x6) | 0x1;
        const level_masks = [_]u64{
            0xFF80_0000_0000,
            0x007F_C000_0000,
            0x0000_3FE0_0000,
            0x0000_001F_F000,
        };
        const num_pages = blk: {
            const lower_bound = std.mem.alignBackward(start_address, 4096);
            const upper_bound = std.mem.alignBackward(start_address +% size -% 1, 4096);
            break :blk ((upper_bound - lower_bound) >> 12) + 1;
        };
        outer: for (range(num_pages)) |_, page_i| {
            const virtual_address = actual_start_address + (page_i << 12);
            var current_address = self.page_table.getAddress();
            for (level_masks) |level_mask, i| {
                const current_table_ptr = @intToPtr(*align(4096) [512]u64, current_address);
                const current_table = @ptrCast(*align(4096) PageTable, current_table_ptr);
                const index = @truncate(
                    u9,
                    (level_mask & virtual_address) >> @truncate(u6, (3 - i) * 9 + 12),
                );
                const entry = current_table[index];
                // Allocate page if required
                if (!entry.isPresent()) {
                    continue :outer;
                }
                if (i < 3) {
                    if (entry.isHugePage()) {
                        // TODO Implement huge page support
                        @panic("huge page support currently unimplemented");
                    }
                    const new_entry = entry.__data | parent_relaxation_flags;
                    current_table_ptr[index] = new_entry;
                    asm volatile ("invlpg (%[page])"
                        :
                        : [page] "r" (virtual_address)
                        : "memory"
                    );
                } else {
                    const new_entry = (entry.getAddress() & 0x000FFFFFFFFFF000) | actual_flags;
                    current_table_ptr[index] = new_entry;
                    asm volatile ("invlpg (%[page])"
                        :
                        : [page] "r" (virtual_address)
                        : "memory"
                    );
                }
                current_address = entry.getAddress();
            }
        }
    }

    // TODO Add support for allocating huge pages
    /// Allocates a page at the given virtual address (aligned down, top 16 bits ignored).
    /// `child_flags` only apply to the final child page.
    /// No flags are applied to already existing pages.
    /// Returns whether a page was allocated, if `false` then the page was already mapped.
    pub fn mapPage(
        self: *PageAllocator,
        virtual_address: u64,
        flags: u64,
    ) !void {
        const new_page_address = @ptrToInt(try self.findAndReservePage());
        errdefer self.freePage(new_page_address);
        try self.offsetMapMem(new_page_address, virtual_address, flags, PageAllocator.page_size);
    }

    // TODO Add support for freeing huge pages
    /// Frees a page at the given virtual address (aligned down, top 16 bits ignored).
    /// Returns whether a page was freed, if `false` then the page was absent.
    pub fn unmapPage(self: *PageAllocator, virtual_address: u64) bool {
        const level_masks = [_]u64{
            0xFF80_0000_0000,
            0x007F_C000_0000,
            0x0000_3FE0_0000,
            0x0000_001F_F000,
        };
        var final_page: *PageTableEntry = undefined;
        var current_address = self.page_table.getAddress();
        // Traverse page table
        for (level_masks) |level_mask, i| {
            const current_table_ptr = @intToPtr(*align(4096) [512]u64, current_address);
            const current_table = @ptrCast(*align(4096) PageTable, current_table_ptr);
            const index = @truncate(
                u9,
                (level_mask & virtual_address) >> @truncate(u6, (3 - i) * 9 + 12),
            );
            const entry = current_table[index];
            if (entry.isHugePage()) @panic("large pages not supported");
            if (i == 3) {
                if (!entry.isPresent()) return false;
                final_page = &current_table[index];
            } else {
                current_address = entry.getAddress();
            }
        }
        // Free page
        self.freePage(final_page.getAddress());
        final_page.* = comptime PageTableEntry.fromU64(0);
        return true;
    }

    /// Maps 8K of physical memory starting at the given address to the kernel temporary
    /// mapping area. Returns the new virtual address, or an error if not enough memory
    /// is available.
    pub fn tempMapAddress(self: *PageAllocator, phys_address: u64) !u64 {
        const phys_start_address = phys_address & ~@as(u64, 0xFFF);
        try self.offsetMapMem(
            phys_start_address,
            @ptrToInt(&root.TEMP_MAPPING_AREA_BASE),
            0x3,
            0x2000,
        );
        return root.TEMP_MAPPING_AREA_BASE | (phys_address & 0xFFF);
    }

    /// Checks if all of the enabled flags exist on the mapped pages. Returns `false` if
    /// some pages do not have the enabled flags or are not mapped.
    pub fn checkFlags(
        self: *PageAllocator,
        virtual_start_address: u64,
        size: usize,
        check_flags: u64,
    ) bool {
        const actual_flags = (check_flags & 0x80000000000001FE) | 0x1;
        const level_masks = [_]u64{
            0xFF80_0000_0000,
            0x007F_C000_0000,
            0x0000_3FE0_0000,
            0x0000_001F_F000,
        };
        const num_pages = blk: {
            const lower_bound = std.mem.alignBackward(virtual_start_address, 4096);
            const upper_bound = std.mem.alignBackward(virtual_start_address +% size -% 1, 4096);
            break :blk ((upper_bound - lower_bound) >> 12) + 1;
        };
        for (range(num_pages)) |_, page_i| {
            const virtual_address = virtual_start_address + (page_i << 12);
            var current_address = self.page_table.getAddress();
            for (level_masks) |level_mask, i| {
                const current_table_ptr = @intToPtr(*align(4096) [512]u64, current_address);
                const current_table = @ptrCast(*align(4096) PageTable, current_table_ptr);
                const index = @truncate(
                    u9,
                    (level_mask & virtual_address) >> @truncate(u6, (3 - i) * 9 + 12),
                );
                const entry = current_table[index];
                // Check flags
                if (!entry.isPresent() or entry.__data & actual_flags != actual_flags) {
                    return false;
                } else {
                    current_address = entry.getAddress();
                }
            }
        }
        return true;
    }

    /// Switches to the page allocator's page table
    pub fn loadAddressSpace(self: *const PageAllocator) void {
        asm volatile ("movq %[page_table], %%cr3"
            :
            : [page_table] "{rax}" (self.page_table.__data)
        );
    }
};
