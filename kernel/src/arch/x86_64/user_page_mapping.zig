const std = @import("std");
const PageAllocator = @import("page_allocation.zig").PageAllocator;
const paging = @import("paging.zig");
const range = @import("root").zig_extensions.range;
const PageTable = paging.PageTable;
const PageTableEntry = paging.PageTableEntry;

const logger = std.log.scoped(.x86_64_virtual_page_mapping);

pub const UserPageMapper = struct {
    page_allocator: *PageAllocator,
    page_table: PageTableEntry,

    const level_masks = [_]u64{
        0xFF80_0000_0000,
        0x007F_C000_0000,
        0x0000_3FE0_0000,
        0x0000_001F_F000,
    };

    pub fn init(page_allocator: *PageAllocator) !UserPageMapper {
        // Create new PML4, clear first half
        const page = try page_allocator.findAndReservePage();
        const page_table = @ptrCast(*allowzero align(4096) [512]u64, page)[0 .. page.len / 8];
        for (page_table[0..256]) |*entry| entry.* = 0;
        // Fill second half of page table with kernel pages
        const page_allocator_pml4_ptr = @intToPtr(
            *align(4096) [512]u64,
            page_allocator.page_table.getAddress(),
        );
        for (page_allocator_pml4_ptr[256..]) |*entry, i| {
            page_table[i + 256] = entry.*;
        }
        // Return new page table with empty lower half
        return UserPageMapper{
            .page_allocator = page_allocator,
            .page_table = PageTableEntry.fromU64(@ptrToInt(page_table)),
        };
    }

    pub fn deinit(self: *UserPageMapper) void {
        const node = @intToPtr(*[512]PageTableEntry, self.page_table.getAddress());
        for (node[0..256]) |entry| {
            if (entry.isPresent()) self.freePageTree(entry, 0);
        }
        self.page_allocator.freePage(self.page_table.getAddress());
    }

    /// Maps a new page to virtual memory at `virtual_start_address` aligned down to the nearest
    /// page, including any required parent pages. Page will be zeroed out. Generated parent pages
    /// are set to read/write/execute. Child page flags will be set to `flags`. `pages_left`, if
    /// provided, will be decremented every time a page is allocated. If `pages_left` runs out of
    /// pages, all allocated parent pages will be freed and `error.OutOfPages` will be returned.
    /// Does not do any page invalidation, so the address space must not be in use.
    pub fn mapBlankPage(
        self: *UserPageMapper,
        virtual_start_address: u64,
        flags: u64,
        pages_left: ?*u64,
    ) !void {
        const parent_flags = PageTableEntry.generateU64(.{
            .present = true,
            .writable = true,
            .user_accessible = true,
        });
        // Ensure only normal flags are used, also ensures present and user accessible are set.
        const child_flags = (flags & 0x8000_0000_0000_0007) | 5;
        // Store any parent pages created, free if an error occurs.
        var parent_pages_created = [3]?[*]allowzero align(4096) u8{ null, null, null };
        errdefer for (parent_pages_created) |page_ptr_maybe| if (page_ptr_maybe) |page_ptr| {
            self.page_allocator.freePage(@intToPtr(page_ptr));
        };
        // Loop through page levels
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
                if (pages_left) |pages_left_ptr| {
                    if (pages_left_ptr == 0) return error.ZeroPagesLeft;
                    pages_left_ptr -= 1;
                }
                // Allocate and zero out page
                const new_page = @ptrCast(
                    [*]allowzero align(4096) u8,
                    try self.page_allocator.findAndReservePage(),
                );
                for (new_address[0..4096]) |*byte| byte.* = 0;
                // Add parent page to created list
                if (i < 3) parent_pages_created[i] = new_page;
                // Map entry
                const stripped_address = @ptrToInt(new_page) & 0x000FFFFFFFFFF000;
                const new_entry = stripped_address | if (i < 3) parent_flags else child_flags;
                current_table_ptr[index] = new_entry;
                entry = PageTableEntry.fromU64(new_entry);
            }
            current_address = entry.getAddress();
        }
    }

    /// Maps `(size / 4096) + 1` free pages to virtual memory at start address. Fills pages with
    /// data from provided buffer. Memory past buffer length is zeroed. Generated child entries are
    /// set to be only readable, generated parent entries are set to be read/write/execute. Flags
    /// for already existing parent pages are preserved.
    /// Does not do any page invalidation, so the address space must not be in use.
    pub fn mapMemCopyFromBuffer(
        self: *UserPageMapper,
        virtual_start_address: u64,
        size: u64,
        buffer: []const u8,
    ) !void {
        const parent_flags = PageTableEntry.generateU64(.{
            .present = true,
            .writable = true,
        });
        const flags = PageTableEntry.generateU64(.{
            .present = true,
            .no_execute = true,
        });
        const num_pages = blk: {
            const lower_bound = std.mem.alignBackward(virtual_start_address, 4096);
            const upper_bound = std.mem.alignBackward(virtual_start_address +% size -% 1, 4096);
            break :blk ((upper_bound - lower_bound) >> 12) + 1;
        };
        var start_offset = virtual_start_address & 0xFFF;
        var data_written: usize = 0;
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
                var entry = current_table[index];
                // Allocate page if required
                if (!entry.isPresent()) {
                    if (i < 3) {
                        // Allocate parent entry
                        var new_address = @ptrCast(
                            [*]allowzero align(4096) u8,
                            try self.page_allocator.findAndReservePage(),
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
                    } else {
                        // Allocate new page
                        const new_page = try self.page_allocator.findAndReservePage();
                        // Map new page
                        const stripped_address = @ptrToInt(new_page) & 0x000FFFFFFFFFF000;
                        const new_entry: u64 = stripped_address | flags;
                        current_table_ptr[index] = new_entry;
                        entry = PageTableEntry.fromU64(new_entry);
                    }
                }
                if (i == 3) {
                    // Write buffer data to page
                    const data_to_write =
                        std.math.min(buffer.len - data_written, 4096 - start_offset);
                    const buffer_slice = buffer[data_written..];
                    const write_page = @intToPtr(
                        *allowzero align(4096) [4096]u8,
                        entry.getAddress(),
                    );
                    for (write_page[start_offset..][0..data_to_write]) |*byte, byte_i| {
                        byte.* = buffer_slice[byte_i];
                    }
                    // Zero out rest of page
                    for (write_page[start_offset + data_to_write ..]) |*byte| byte.* = 0;
                    // Record amount of data written, reset offset
                    data_written += data_to_write;
                    start_offset = 0;
                }
                current_address = entry.getAddress();
            }
        }
    }

    /// Unmaps and frees a page at `virtual_address` aligned down to the nearest page, as well as
    /// empty parent pages. `free_child` indicates whether the child page itself should be freed,
    /// rather than just simply being unmapped. `pages_left`, if provided, will be incremented
    /// every time a page is freed.
    pub fn unmapPage(
        self: *UserPageMapper,
        virtual_address: u64,
        free_child: bool,
        pages_left: ?*u64,
    ) void {
        const actual_virtual_address = virtual_address & 0x000FFFFFFFFFF000;
        const current_address = self.page_table.getAddress();
        _ = self.unmapPageInner(
            virtual_address & 0x000FFFFFFFFFF000,
            self.page_table.getAddress(),
            0,
            free_child,
            pages_left,
        );
    }

    /// Returns whether the page table was freed.
    fn unmapPageInner(
        self: *UserPageMapper,
        virtual_address: u64,
        current_address: u64,
        level: usize,
        free_child: bool,
        pages_left: ?*u64,
    ) bool {
        const current_table = @intToPtr(*align(4096) PageTable, current_address);
        const index = @truncate(
            u9,
            (level_masks[level] & virtual_address) >> @truncate(u6, (3 - i) * 9 + 12),
        );
        const entry = current_address[index];
        if (entry.isPresent()) {
            if (level == 3) {
                // Remove entry, free child page if applicable
                current_address[index] = comptime PageTableEntry.fromU64(0);
                if (free_child) {
                    self.page_allocator.freePage(entry.getAddress());
                    if (pages_left) |pages_left_ptr| pages_left_ptr.* += 1;
                }
            } else {
                // Keep recursing
                if (unmapPageInner(virtual_address, entry.getAddress(), level + 1, pages_left)) {
                    // Inner page table was freed, remove entry
                    current_address[index] = comptime PageTableEntry.fromU64(0);
                }
            }
        }
        // Check if page table is now empty and can be freed
        const should_free_table = level > 0 and blk: for (current_table) |*table_entry| {
            if (table_entry.__data != 0) break :blk false;
        } else true;
        if (should_free_table) {
            self.page_allocator.freePage(current_address);
            if (pages_left) |pages_left_ptr| pages_left_ptr.* += 1;
        }
        return should_free_table;
    }

    /// Unmaps and frees `(size / 4096) + 1` pages starting at the given linear address.
    pub fn asyncUnmapMem(
        self: *UserPageMapper,
        start_address: u64,
        size: usize,
        free_child: bool,
        pages_left: ?*u64,
    ) void {
        const actual_start_address = start_address & 0x000FFFFFFFFFF000;
        const num_pages = blk: {
            const lower_bound = std.mem.alignBackward(start_address, 4096);
            const upper_bound = std.mem.alignBackward(start_address +% size -% 1, 4096);
            break :blk ((upper_bound - lower_bound) >> 12) + 1;
        };
        const page_table_address = self.page_table.getAddress();
        outer: for (range(num_pages)) |_, page_i| {
            const virtual_address = actual_start_address + (page_i << 12);
            _ = self.unmapPageInner(
                virtual_address,
                page_table_address,
                0,
                free_child,
                pages_left,
            );
            // TODO Write a new inline `suspendIfOvertime` clock function
            // TODO Rewrite `changeFlags` (below) as `asyncChangeFlags`
        }
    }

    /// Sets the flags of `(size / 4096) + 1` child pages starting at the given linear address.
    /// Relaxes permissions for parent pages where necessary.
    pub fn changeFlags(
        self: *UserPageMapper,
        start_address: u64,
        flags: u64,
        size: u64,
    ) void {
        const actual_start_address = start_address & 0x000FFFFFFFFFF000;
        const actual_flags = (flags & 0x80000000000001FE) | 0x1;
        const parent_relaxation_flags = (flags & 0x6) | 0x1;
        const parent_no_execute_mask: u64 =
            if (flags & (1 << 63) == 0)
            ~@as(u64, 1 << 63)
        else
            ~@as(u64, 0);
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
                var entry = current_table[index];
                if (!entry.isPresent()) {
                    continue :outer;
                }
                if (i < 3) {
                    // TODO Test this
                    // TODO Optimize, skip over next pages in huge page
                    if (entry.isHugePage()) {
                        const stripped_address = entry.getAddress() & 0x000FFFFFFFFFF000;
                        const huge_page_flag = PageTableEntry.generateU64(.{
                            .huge_page = true,
                        });
                        const new_entry = stripped_address | actual_flags | huge_page_flag;
                        current_table_ptr[index] = new_entry;
                        asm volatile ("invlpg (%[page])"
                            :
                            : [page] "r" (virtual_address)
                            : "memory"
                        );
                        continue :outer;
                    }
                    const new_entry =
                        (entry.__data | parent_relaxation_flags) & parent_no_execute_mask;
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

    // TODO Optimize by keeping count of number of pages done, stay at deepest level
    // TODO Make this relax parent NX flag
    /// Relaxes the flags of `(size / 4096) + 1` child pages starting at the given linear address.
    /// Also relaxes permissions for parent pages where necessary.
    pub fn changeFlagsRelaxing(
        self: *UserPageMapper,
        start_address: u64,
        flags: u64,
        size: u64,
    ) void {
        const actual_start_address = start_address & 0x000FFFFFFFFFF000;
        const relaxation_flags = (flags & 0x6) | 0x1;
        const no_execute_mask: u64 =
            if (flags & (1 << 63) == 0)
            ~@as(u64, 1 << 63)
        else
            ~@as(u64, 0);
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
                var entry = current_table[index];
                if (!entry.isPresent()) {
                    continue :outer;
                }
                // TODO Test this
                // TODO Optimize, skip over next pages in huge page
                if (entry.isHugePage()) {
                    const stripped_address = entry.getAddress() & 0x000FFFFFFFFFF000;
                    const huge_page_flag = PageTableEntry.generateU64(.{
                        .huge_page = true,
                    });
                    const new_entry = (entry.__data | relaxation_flags) & no_execute_mask;
                    current_table_ptr[index] = new_entry;
                    asm volatile ("invlpg (%[page])"
                        :
                        : [page] "r" (virtual_address)
                        : "memory"
                    );
                    continue :outer;
                }
                const new_entry = (entry.__data | relaxation_flags) & no_execute_mask;
                current_table_ptr[index] = new_entry;
                asm volatile ("invlpg (%[page])"
                    :
                    : [page] "r" (virtual_address)
                    : "memory"
                );
                current_address = entry.getAddress();
            }
        }
    }

    fn freePageTree(self: *UserPageMapper, node: PageTableEntry, level: usize) void {
        if (!node.isPresent()) return;
        // TODO Add huge page support
        if (node.isHugePage()) @panic("huge page support unimplemented");
        if (level < 3) {
            for (@intToPtr(*[512]PageTableEntry, node.getAddress())) |entry| {
                if (entry.isPresent()) self.freePageTree(entry, level + 1);
            }
        }
        self.page_allocator.freePage(node.getAddress());
    }
};
