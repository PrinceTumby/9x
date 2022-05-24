//! Kernel implementation of allocating pages of physical memory

const std = @import("std");
const logger = std.log.scoped(.x86_64_kernel_page_allocation);
const root = @import("root");
const paging = @import("paging.zig");
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

pub const PageAllocator = struct {
    memory_map: []u8,
    num_pages: usize,
    page_table: PageTableEntry,

    pub const page_size: usize = 4096;
    pub const large_page_size: usize = page_size * 512;
    pub const byte_ratio: usize = page_size * 8;

    pub fn new(page_table: *[512]u64, memory_map: []u8, num_pages: usize) PageAllocator {
        return PageAllocator{
            .memory_map = memory_map,
            .num_pages = num_pages,
            .page_table = PageTableEntry.fromU64(@ptrToInt(page_table)),
        };
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
        const num_pages = if (size & 0xFFF != 0) (size >> 12) + 1 else size >> 12;
        var page_i: usize = 0;
        while (page_i < num_pages) : (page_i += 1) {
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
        const num_pages = if (size & 0xFFF != 0) (size >> 12) + 1 else size >> 12;
        var page_i: usize = 0;
        outer: while (page_i < num_pages) : (page_i += 1) {
            const virtual_address = actual_start_address + (page_i << 12);
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
        const num_pages = if (size & 0xFFF != 0) (size >> 12) + 1 else size >> 12;
        var page_i: usize = 0;
        outer: while (page_i < num_pages) : (page_i += 1) {
            const virtual_address = actual_start_address + (page_i << 12);
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
            var entry = current_table[index];
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
        const num_pages = if (size & 0xFFF != 0) (size >> 12) + 1 else size >> 12;
        var page_i: usize = 0;
        while (page_i < num_pages) : (page_i += 1) {
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
                // Check flags
                if (!(entry.isPresent() and entry.__data & actual_flags == actual_flags)) {
                    current_address = entry.getAddress();
                } else {
                    return false;
                }
            }
        }
        return true;
    }

    // TODO Add in ways to check flags on a memory range, as well as a way to update
    // some flags and leave others unchanged over a memory range
};
