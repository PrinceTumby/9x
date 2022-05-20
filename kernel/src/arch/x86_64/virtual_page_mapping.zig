const std = @import("std");
const PageAllocator = @import("page_allocation.zig").PageAllocator;
const paging = @import("paging.zig");
const PageTable = paging.PageTable;
const PageTableEntry = paging.PageTableEntry;

const logger = std.log.scoped(.x86_64_virtual_page_mapping);

pub const VirtualPageMapper = struct {
    page_allocator: *PageAllocator,
    page_table: PageTableEntry,

    pub fn init(page_allocator: *PageAllocator) !VirtualPageMapper {
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
        return VirtualPageMapper{
            .page_allocator = page_allocator,
            .page_table = PageTableEntry.fromU64(@ptrToInt(page_table)),
        };
    }

    pub fn deinit(self: *VirtualPageMapper) void {
        const node = @intToPtr(*[512]PageTableEntry, self.page_table.getAddress());
        self.freePageTree(node, 0);
    }

    /// Maps `(size / 4096) + 1` free pages to virtual memory at start address. Fills pages with
    /// data from provided buffer. Memory past buffer length is zeroed. Child entries and
    /// generated parent entries are set to be readable and writable. Flags for already existing
    /// parent pages are preserved.
    pub fn mapMemCopyFromBuffer(
        self: *VirtualPageMapper,
        virtual_start_address: u64,
        size: u64,
        buffer: []const u8,
    ) !void {
        const flags = 0x3; // Present and writable
        const level_masks = [_]u64{
            0xFF80_0000_0000,
            0x007F_C000_0000,
            0x0000_3FE0_0000,
            0x0000_001F_F000,
        };
        const num_pages = if (size & 0xFFF != 0) (size >> 12) + 1 else size >> 12;
        var start_offset = virtual_start_address & 0xFFF;
        var data_written: usize = 0;
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
                        const new_entry: u64 = stripped_address | flags;
                        current_table_ptr[index] = new_entry;
                        entry = PageTableEntry.fromU64(new_entry);
                        asm volatile ("invlpg (%[page])"
                            :
                            : [page] "r" (new_address)
                            : "memory"
                        );
                    } else {
                        // Allocate new page
                        const new_page = try self.page_allocator.findAndReservePage();
                        // Write buffer data to page
                        const data_to_write =
                            std.math.min(buffer.len - data_written, 4096 - start_offset);
                        const buffer_slice = buffer[data_written..];
                        for (new_page[start_offset..][0..data_to_write]) |*byte, byte_i| {
                            byte.* = buffer_slice[byte_i];
                        }
                        // Zero out rest of page
                        for (new_page[start_offset + data_to_write..]) |*byte| byte.* = 0;
                        // Record amount of data written, reset offset
                        data_written += data_to_write;
                        start_offset = 0;
                        // Map new page
                        const stripped_address = @ptrToInt(new_page) & 0x000FFFFFFFFFF000;
                        const new_entry: u64 = stripped_address | flags;
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

    /// Unmaps and frees `(size / 4096) + 1` pages starting at the given linear address.
    pub fn unmapMem(self: *VirtualPageMapper, start_address: u64, size: usize) void {
        const actual_start_address = start_address & 0x000FFFFFFFFFF000;
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
                const current_table = @intToPtr(*align(4096) PageTable, current_address);
                const index = @truncate(
                    u9,
                    (level_mask & virtual_address) >> @truncate(u6, (3 - i) * 9 + 12),
                );
                const entry = current_table[index];
                if (entry.isHugePage()) @panic("large pages not supported");
                if (i == 3) {
                    if (!entry.isPresent()) continue :outer;
                    // Free page, remove entry
                    self.page_allocator.freePage(entry.getAddress()) catch {};
                    entry.* = comptime PageTableEntry.fromU64(0);
                } else {
                    current_address = entry.getAddress();
                }
            }
        }
    }

    // TODO Optimize by keeping count of number of pages done, stay at deepest level
    /// Sets the flags of `(size / 4096) + 1` child pages starting at the given linear address.
    /// Relaxes permissions for parent pages where necessary.
    pub fn changeFlags(
        self: *VirtualPageMapper,
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

    // TODO Add support for large pages (depends on page allocator large page support)
    fn freePageTree(self: *VirtualPageMapper, node: *[512]PageTableEntry, level: usize) void {
        for (node) |*entry| {
            if (entry.isPresent()) {
                if (level < 3) {
                    freePageTree(entry, level + 1);
                    self.page_allocator.freePage(@ptrToInt(entry)) catch {};
                }
            }
        }
        self.page_allocator.freePage(@ptrToInt(node));
    }
};
