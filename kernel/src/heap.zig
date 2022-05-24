//! Kernel heap allocation and management.
//! The allocator is currently a very simple linked list allocator, although this
//! may change in future.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Error = Allocator.Error;
const builtin = @import("builtin");
const root = @import("root");
const compileErrorFmt = root.zig_extensions.compileErrorFmt;
const smp = root.smp;
const arch = root.arch;
const page_allocator = arch.page_allocation.page_allocator_ptr;
const alignToPage = arch.paging.alignToPage;

const logger = std.log.scoped(.heap);

pub const Block = packed struct {
    /// Length of the block area, should be u30 for 32-bit and u62 for 64-bit
    len: LenType,
    /// Whether the block is used, if `false` the block is free
    used: bool,
    /// Whether there is another block following this block
    next: bool,

    pub const LenType = @Type(.{.Int = .{
        .is_signed = false,
        .bits = @bitSizeOf(usize) - 2,
    }});

    pub const alignment: u29 = @alignOf(usize);

    pub fn init(len: usize, used: bool, next: bool) Block {
        return Block{
            .len = @truncate(LenType, len),
            .used = used,
            .next = next,
        };
    }

    pub fn getStartPtr(self: *Block) [*]u8 {
        return @ptrCast([*]u8, self) + @sizeOf(Block);
    }

    pub fn getNext(self: *Block) ?*Block {
        if (!self.next) return null;
        const address = @ptrToInt(self) + @sizeOf(Block) + self.len;
        return @intToPtr(*Block, address);
    }

    pub fn setLen(self: *Block, len: usize) void {
        self.len = @truncate(@TypeOf(self.len), len);
    }

    comptime {
        if (@bitSizeOf(Block) != @bitSizeOf(usize)) {
            compileErrorFmt("Heap block incorrect bit size for target: ", .{@bitSizeOf(Block)});
        }
        if (@sizeOf(Block) != @sizeOf(usize)) {
            compileErrorFmt("Heap block incorrect byte size for target: ", .{@sizeOf(Block)});
        }
    }
};

const page_flags = arch.paging.PageTableEntry.generateU64(.{
    .present = true,  // Present
    .writable = true,  // Writable
    .user_accessable = false, // User accessable
    // FIXME: Turning on NX currently breaks test machine
    .no_execute = false, // No execute
});

pub var list_head: ?*Block = null;

/// Initialises an area of virtual memory for use as heap space.
///
/// The caller should ensure the page allocator is initialised and that the area has not already
/// been added as heap space.
/// The allocator will automatically map pages, so the area should be unmapped.
pub fn initHeap(heap: []u8) !void {
    if (heap.len < @sizeOf(Block)) return error.HeapTooSmall;
    const new_block_addr = std.mem.alignForward(@ptrToInt(heap.ptr), Block.alignment);
    const new_block = @intToPtr(*Block, new_block_addr);
    _ = try page_allocator.mapPage(new_block_addr, page_flags);
    new_block.* = Block.init(
        (@ptrToInt(heap.ptr) + heap.len) - new_block_addr - @sizeOf(Block),
        false,
        false,
    );
    list_head = new_block;
}

fn alloc(
    self: *Allocator,
    len: usize,
    ptr_align: u29,
    _len_align: u29,
    ret_addr: usize,
) ![]u8 {
    std.debug.assert(ptr_align != 0);
    const kernel_heap_allocator = @fieldParentPtr(KernelHeapAllocator, "allocator", self);
    const held = kernel_heap_allocator.lock.acquire();
    defer held.release();
    // Scan through list to find free space large enough
    var cur_block_maybe: ?*Block = list_head;
    while (cur_block_maybe) |cur_block| : (cur_block_maybe = cur_block.getNext()) {
        if (cur_block.used) continue;
        const unaligned_start_addr = @ptrToInt(cur_block.getStartPtr());
        const start_addr = std.mem.alignForward(unaligned_start_addr, ptr_align);
        const max_addr = unaligned_start_addr +% cur_block.len -% 1;
        const end_addr = start_addr +% len -% 1;
        if (end_addr > max_addr) continue;
        // We've found the block, reserve
        cur_block.used = true;
        // If enough space, split block into used block and free block, otherwise keep block as is
        const new_block = @intToPtr(
            *Block,
            std.mem.alignForward(end_addr + 1, Block.alignment),
        );
        const new_space_start = @ptrCast([*]u8, new_block) + @sizeOf(Block);
        if (@ptrToInt(new_space_start) < max_addr) {
            cur_block.setLen(@ptrToInt(new_block) - unaligned_start_addr);
            _ = try page_allocator.mapPage(@ptrToInt(new_block), page_flags);
            new_block.* = Block.init(
                max_addr - @ptrToInt(new_space_start) + 1,
                false,
                cur_block.next,
            );
            cur_block.next = true;
        }
        // Allocate pages
        {
            const end_page = std.mem.alignBackward(end_addr, 4096);
            var current_page = std.mem.alignBackward(unaligned_start_addr, 4096);
            while (current_page <= end_page) : (current_page += 4096) {
                _ = try page_allocator.mapPage(current_page, page_flags);
            }
        }
        return @intToPtr([*]u8, start_addr)[0 .. end_addr - start_addr + 1];
    } else {
        logger.debug("Out of blocks!", .{});
        return error.OutOfMemory;
    }
}

fn resize(
    self: *Allocator,
    buf: []u8,
    buf_align: u29,
    new_len: usize,
    _len_align: u29,
    ret_addr: usize,
) Error!usize {
    const kernel_heap_allocator = @fieldParentPtr(KernelHeapAllocator, "allocator", self);
    const held = kernel_heap_allocator.lock.acquire();
    defer held.release();
    // In-place size increasing not supported
    if (new_len > buf.len)
        return error.OutOfMemory;
    if (new_len == 0 and buf.len != 0) {
        // Free memory
        const search_addr = @ptrToInt(buf.ptr);
        var prev_block_maybe: ?*Block = null;
        var cur_block_maybe: ?*Block = list_head;
        while (cur_block_maybe) |cur_block| : ({
            prev_block_maybe = cur_block_maybe;
            cur_block_maybe = cur_block.getNext();
        }) {
            if (builtin.mode != .Debug) {
                // In debug mode we want to catch double frees
                if (!cur_block.used) continue;
            }
            const min_addr = @ptrToInt(cur_block.getStartPtr());
            const max_addr = min_addr +% cur_block.len -% 1;
            // Check if block contains allocation
            if (min_addr <= search_addr and search_addr <= max_addr) {
                if (builtin.mode == .Debug) {
                    if (!cur_block.used) {
                        @panic("allocator detected double free");
                    }
                }
                cur_block.used = false;
                // Free middle pages
                {
                    const start_page = std.mem.alignForward(min_addr, 4096);
                    const end_page = std.mem.alignBackward(max_addr, 4096);
                    var current_page = start_page;
                    while (current_page < end_page) : (current_page += 4096) {
                        _ = page_allocator.unmapPage(current_page);
                    }
                }
                // Merge forward if next block is free
                if (cur_block.getNext()) |next_block| blk: {
                    if (next_block.used) break :blk;
                    const cur_block_page = alignToPage(@ptrToInt(cur_block));
                    const next_block_page = alignToPage(@ptrToInt(next_block));
                    cur_block.len += @sizeOf(Block) + next_block.len;
                    cur_block.next = next_block.next;
                    // Check if merged block header page can be freed
                    if (cur_block_page != next_block_page) {
                        if (next_block.getNext()) |next_next_block| {
                            if (alignToPage(@ptrToInt(next_next_block)) != next_block_page) {
                                _ = page_allocator.unmapPage(next_block_page);
                            }
                        }
                    }
                }
                // Merge backward if previous block is free
                if (prev_block_maybe) |prev_block| blk: {
                    if (prev_block.used) break :blk;
                    const cur_block_page = alignToPage(@ptrToInt(cur_block));
                    const prev_block_page = alignToPage(@ptrToInt(prev_block));
                    prev_block.len += @sizeOf(Block) + cur_block.len;
                    prev_block.next = cur_block.next;
                    cur_block.* = undefined;
                    // Check if merged block header page can be freed
                    if (cur_block_page != prev_block_page) {
                        if (cur_block.getNext()) |next_block| {
                            if (alignToPage(@ptrToInt(next_block)) != cur_block_page) {
                                _ = page_allocator.unmapPage(cur_block_page);
                            }
                        }
                    }
                }
                return 0;
            }
        }
        @panic("attempt to free pointer not part of heap");
    } else {
        return new_len;
    }
}

const KernelHeapAllocator = struct {
    allocator: Allocator,
    lock: smp.SpinLock,
};

pub const heap_allocator_ptr = &heap_allocator.allocator;

var heap_allocator = KernelHeapAllocator{
    .allocator = Allocator{
        .allocFn = alloc,
        .resizeFn = resize,
    },
    .lock = smp.SpinLock.init(),
};
