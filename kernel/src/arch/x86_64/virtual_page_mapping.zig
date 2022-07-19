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
        for (node[0..256]) |entry| {
            if (entry.isPresent()) self.freePageTree(entry, 0);
        }
        self.page_allocator.freePage(self.page_table.getAddress());
    }

    /// Maps `(size / 4096) + 1` free pages to virtual memory at start address. Fills pages with
    /// data from provided buffer. Memory past buffer length is zeroed. Generated hild entries are
    /// set to be only readable, generated parent entries are set to be readable writable, and
    /// executable. Flags for already existing parent pages are preserved.
    pub fn mapMemCopyFromBuffer(
        self: *VirtualPageMapper,
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
                        const new_entry: u64 = stripped_address | parent_flags;
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
                        // Map new page
                        const stripped_address = @ptrToInt(new_page) & 0x000FFFFFFFFFF000;
                        const new_entry: u64 = stripped_address | flags;
                        current_table_ptr[index] = new_entry;
                        entry = PageTableEntry.fromU64(new_entry);
                        asm volatile ("invlpg (%[page])"
                            :
                            : [page] "r" (virtual_address)
                            : "memory"
                        );
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
                    for (write_page[start_offset + data_to_write..]) |*byte| byte.* = 0;
                    // Record amount of data written, reset offset
                    data_written += data_to_write;
                    start_offset = 0;
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
        const num_pages = blk: {
            const lower_bound = std.mem.alignBackward(start_address, 4096);
            const upper_bound = std.mem.alignBackward(start_address +% size -% 1, 4096);
            break :blk ((upper_bound - lower_bound) >> 12) + 1;
        };
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
                    self.page_allocator.freePage(entry.getAddress());
                    current_table[index] = comptime PageTableEntry.fromU64(0);
                } else {
                    current_address = entry.getAddress();
                }
            }
        }
    }

    /// Returns the flags for an address, or `null` if the address isn't mapped
    pub fn getFlagsForAddress(
        self: *const VirtualPageMapper,
        virtual_address: u64,
    ) ?PageTableEntry {
        const level_masks = [_]u64{
            0xFF80_0000_0000,
            0x007F_C000_0000,
            0x0000_3FE0_0000,
            0x0000_001F_F000,
        };
        const page_address = virtual_address & 0xFFFFFFFFFFFFF000;
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
            // logger.debug(
            //     \\Found entry:
            //     \\  - Address: 0x{x}
            //     \\  - Present: {}
            //     \\  - Writable: {}
            //     \\  - User Accessable: {}
            //     \\  - Huge Page: {}
            //     \\  - Global: {}
            //     \\  - No Execute: {}
            //     , .{
            //         entry.getAddress(),
            //         entry.isPresent(),
            //         entry.isWritable(),
            //         entry.isUserAccessable(),
            //         entry.isHugePage(),
            //         entry.isGlobal(),
            //         entry.isNoExecute(),
            //     }
            // );
            // Return null if address not mapped
            if (!entry.isPresent()) return null;
            // Return immediately if entry is a huge page
            if (entry.isHugePage()) return entry;
            current_address = entry.getAddress();
        }
        return entry;
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
        const parent_no_execute_mask: u64 =
            if (flags & (1 << 63) == 0)
                ~@as(u64, 1 << 63)
            else
                ~@as(u64, 0);
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
        self: *VirtualPageMapper,
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

    fn freePageTree(self: *VirtualPageMapper, node: PageTableEntry, level: usize) void {
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
