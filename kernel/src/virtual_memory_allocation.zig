//! Wraps the arch-specific VirtualPageMapper for process memory allocation

const std = @import("std");
const arch = @import("arch.zig");
const zig_extensions = @import("zig_extensions");
const page_size = arch.common.page_size;
const compileErrorFmt = zig_extensions.compileErrorFmt;
const PageAllocator = arch.page_allocation.PageAllocator;
const VirtualPageMapper = arch.virtual_page_mapping.VirtualPageMapper;

pub const Segment = struct {
    start: usize,
    len: usize,
    flags: Flags,

    pub const Flags = struct {
        read: bool = true,
        write: bool = false,
        execute: bool = false,

        pub fn fromUsize(x: usize) Flags {
            return Flags{
                .read = x & 0x1 != 0,
                .write = x & 0x2 != 0,
                .execute = x & 0x4 != 0,
            };
        }

        pub fn toUsize(self: Flags) usize {
            return @as(usize, 0) |
                @as(usize, if (self.read) 0x1 else 0) |
                @as(usize, if (self.write) 0x2 else 0) |
                @as(usize, if (self.execute) 0x4 else 0);
        }
    };
};

// TODO Add stuff from mprotect and madvise

pub const VmaAllocator = struct {
    page_mapper: VirtualPageMapper,
    page_head: *allowzero align(page_size) VmaPage,
    tree: VmaTree = .{},

    pub fn init(page_allocator: *PageAllocator) !VmaAllocator {
        const page_mapper = try VirtualPageMapper.init(page_allocator);
        const raw_page = try page_mapper.page_allocator.findAndReservePage();
        const page_head = @ptrCast(*allowzero align(page_size) VmaPage, raw_page);
        page_head.* = VmaPage{};
        return VmaAllocator{
            .page_mapper = page_mapper,
            .page_head = page_head,
        };
    }

    /// Deinitialises data structure memory, does not deallocate segment pages
    pub fn deinit(self: *VmaAllocator) void {
        var current_page_maybe: ?*align(page_size) VmaPage = self.page_head;
        while (current_page_maybe) |current_page_ptr| {
            const next_page_ptr = current_page_ptr.next_page_ptr;
            self.page_mapper.page_allocator.freePage(@ptrToInt(current_page_ptr));
            current_page_maybe = next_page_ptr;
        }
    }

    /// Iterates over all segments in the VmaAllocator.
    pub fn iterator(self: *VmaAllocator) Iterator {
        return Iterator{
            .start = 0,
            .end = std.math.maxInt(usize),
            .current_entry = self.tree.getFirst(),
        };
    }

    /// Iterates over all segments part of the range (inclusive start, exclusive end)
    /// of addresses given.
    pub fn iteratorRange(self: *VmaAllocator, start: usize, end: usize) Iterator {
        return Iterator{
            .start = start,
            .end = end,
            .current_entry = self.tree.getNodeContainingOrAfter(start),
        };
    }

    pub const Iterator = struct {
        start: usize,
        end: usize,
        current_entry: ?*VmaEntry,

        pub fn next(it: *Iterator) ?Segment {
            const entry = it.current_entry orelse return null;
            if (entry.start >= it.end) {
                it.current_entry = null;
                return null;
            }
            it.current_entry = entry.getNext();
            return Segment{
                .start = entry.getStart(),
                .len = entry.len,
                .flags = Segment.Flags.fromUsize(entry.flags),
            };
        }
    };

    // TODO Change VirtualPageMapper to UserMemoryAllocator
    // - Make mapping functions take an optional pointer to a number of extra pages available
    //   to use (fuel).
    // - Extra pages are just used for stuff like page tables. Normal pages contain actual useful
    //   data, and should be removed at the start when a segment allocation is requested.
    // - Fail on finding existing pages.
    // TODO Add `remote` flag, indicates if non-writable memory is owned by another process.
    // TODO Write segment mapping functions
    // - map (function to create a new segment):
    //  - Add some kind of minimum automatic mapping address
    //  - Specify overlapping behaviour (find new space OR replace OR fail)
    //  - Find new space and replace should be async
    //  - map, mapAtOrFail
    // TODO Write userspace core library that can be shared between all programs, but aren't
    // provided as syscalls (loading programs, etc.).
    // - Should be part of initial process, passed down to child processes.
    // - System call style interface, single function with function numbers passed through RAX.
    // - Other libraries can exist in same fashion, segment to store a table of 64-bit
    //   identifiers, pointers and lengths.
    // - Some kind of custom ELF section to filter only wanted libraries?
};

const VmaPage = extern struct {
    entries: [num_entries]VmaEntry align(page_size) = undefined,
    next_page_ptr: ?*allowzero align(page_size) VmaPage = null,
    num_entries_free: usize = num_entries,
    usage_bitmap: [bitmap_len]u8 = initial_usage_bitmap,

    pub const num_entries = comptime blk: {
        // Iteratively reduce array length until both the array and bitmap can fit
        const leftover_space: usize = page_size - (2 * @sizeOf(usize));
        var current_num_entries: usize = current_num_entries / @sizeOf(VmaEntry);
        while (true) : (current_num_entries -= 1) {
            const extra_bitmap_len = if (current_num_entries % 8 > 0) 1 else 0;
            const bitmap_size = (current_num_entries / 8) + extra_bitmap_len;
            const entries_array_size = current_num_entries * @sizeOf(VmaEntry);
            if (bitmap_size + entries_array_size <= leftover_space) {
                break :blk current_num_entries;
            }
        }
    };
    pub const bitmap_len = num_entries / 8 + @boolToInt(num_entries % 8 > 0);
    const initial_usage_bitmap = switch (num_entries % 8) {
        0 => [1]u8{0} ** bitmap_len,
        else => |leftover_entries| blk: {
            // If there are not enough entries to fill the last byte, fill the
            // least significant bits past the end of the entries bitmap to
            // indicate that they are not free.
            // This technically probably isn't required, as the `num_entries_free`
            // field already tracks the number of free entries, and should mean
            // that bits past the end of the usable bitmap are never used anyway,
            // but this is just to be on the safe side.
            const bitmap_start = [1]u8{0} ** (bitmap_len - 1);
            const bitmap_end = [1]u8{~((@as(u8, 0x80) >> (leftover_entries - 1)) - 1)};
            break :blk bitmap_start ++ bitmap_end;
        },
    };

    /// Attempts to find and reserve a free entry.
    pub fn findAndReserveEntry(self: *VmaPage) ?*VmaEntry {
        if (self.num_entries_free == 0) return null;
        for (self.usage_bitmap) |*byte, group_index| {
            if (byte.* != 0xFF) {
                const index = @truncate(u3, @clz(u8, ~byte.*));
                const entry_index = group_index * 8 + index;
                std.debug.assert(entry_index < num_entries);
                byte.* |= @as(u8, 0x80) >> index;
                self.num_entries_free -= 1;
                return &self.entries[entry_index];
            }
        } else unreachable;
    }

    /// Marks an entry as no longer reserved.
    /// The caller is expected to no longer use pointers to this entry after calling this.
    pub fn freeEntry(self: *VmaEntry, entry_index: usize) void {
        if (entry_index >= num_entries) return;
        const byte_index = entry_index / 8;
        const bit_offset = @truncate(u3, address);
        self.usage_bitmap[byte_index] &= ~(@as(u8, 0x80) >> bit_offset);
        self.num_entries_free += 1;
    }

    comptime {
        if (@sizeOf(VmaPage) > page_size) {
            compileErrorFmt(
                "VmaPage size too large for target, {} is not smaller than {}",
                .{ @sizeOf(VmaPage), page_size },
            );
        }
        if (@alignOf(VmaPage) != page_size) {
            compileErrorFmt(
                "Incorrect has alignment for target, {} is not {}",
                .{ @alignOf(VmaPage), page_size },
            );
        }
    }
};

const VmaTree = struct {
    root: ?*VmaEntry = null,

    pub fn getFirst(self: *const VmaTree) ?*VmaEntry {
        var current_node = self.root orelse return null;
        while (current_node.children[0]) |left_child| current_node = left_child;
        return current_node;
    }

    // pub fn getNodeContaining(self: *const VmaTree, addr: usize) ?*VmaEntry {
    //     var current_node_maybe = self.root;
    //     while (current_node_maybe) |current_node| {
    //         if (current_node.getStart() > addr) {
    //             current_node_maybe = current_node.children[0];
    //         } else if (current_node.getStart() + current_node.len - 1 < addr) {
    //             current_node_maybe = current_node.children[1];
    //         } else {
    //             return current_node_maybe;
    //         }
    //     }
    //     return null;
    // }

    // This takes a non-constant amount of time, but hopefully this is small enough that we don't
    // need it to be async.
    pub fn getNodeContainingOrAfter(self: *const VmaTree, addr: usize) ?*VmaEntry {
        var current_node = self.root orelse return null;
        var last_node = current_node;
        while (true) {
            if (current_node.getStart() > addr) {
                last_node = current_node;
                current_node = current_node.children[0] orelse break;
            } else if (current_node.getStart() + current_node.len - 1 < addr) {
                current_node = current_node.children[1] orelse current_node.getNext() orelse return null;
                last_node = current_node;
            } else {
                return current_node;
            }
        }
        return last_node;
    }

    fn rotateDir(self: *VmaTree, subtree_root: *VmaEntry, direction: u1) *VmaEntry {
        const grandparent_maybe = subtree_root.parent;
        const sibling = subtree_root.children[1 - direction].?;
        const cousin_maybe = sibling.children[direction];
        subtree_root.children[1 - direction] = cousin_maybe;
        if (cousin_maybe) |cousin| cousin.parent = subtree_root;
        sibling.cihldren[direction] = subtree_root;
        subtree_root.parent = sibling;
        sibling.parent = grandparent_maybe;
        if (grandparent_maybe) |grandparent| {
            grandparent.children[subtree_root.getDirectionFromParent()] = sibling;
        } else {
            self.root = sibling;
        }
        return sibling;
    }

    fn rotateLeft(self: *VmaTree, subtree_root: *VmaEntry) *VmaEntry {
        return self.rotateDir(subtree_root, 0);
    }

    fn rotateRight(self: *VmaTree, subtree_root: *VmaEntry) *VmaEntry {
        return self.rotateDir(subtree_root, 1);
    }

    pub fn insert(self: *VmaTree, node: *VmaEntry) void {
        if (self.root) |root| {
            var current_node = root;
            while (true) {
                if (current_node.start > node.start) {
                    const new_node = current_node.children[0] orelse {
                        self.insertUnder(node, current_node, 0);
                        return;
                    };
                    current_node = new_node;
                } else if (current_node.start < node.start) {
                    const new_node = current_node.children[1] orelse {
                        self.insertUnder(node, current_node, 1);
                        return;
                    };
                    current_node = new_node;
                } else unreachable;
            }
        } else {
            node.setColor(.black);
            self.root = node;
            return;
        }
    }

    /// Node must not have any children, and not have a parent.
    /// Requested slot to place `node` must be null.
    fn insertUnder(self: *VmaTree, node: *VmaEntry, new_parent_maybe: ?*VmaEntry, side: u1) void {
        node.setColor(.red);
        std.debug.assert(node.children[0] == null and node.children[1] == null);
        node.parent = new_parent_maybe;
        if (new_parent_maybe) |new_parent| {
            std.debug.assert(new_parent.children[side] == null);
            new_parent.children[side] = node;
            // Parent node of `new_parent`
            var grandparent: *VmaEntry = undefined;
            // Uncle of `node`
            var uncle: *VmaEntry = undefined;
            var current_node = node;
            var current_new_parent = new_parent;
            while (true) {
                if (current_new_parent.color == .black) return; // Case_I1 (new_parent black)
                // From now on new_parent is red
                if (current_new_parent.parent) |new_grandparent| {
                    grandparent = new_grandparent;
                } else {
                    // Case_I4
                    current_new_parent.setColor(.black);
                    return;
                }
                // Now new_parent is red and g is not null
                const new_side = current_new_parent.getDirectionFromParent();
                if (grandparent.children[1 - new_side]) |new_uncle| {
                    if (new_uncle.color == .black) {
                        // Case_I56
                        if (current_node == current_new_parent.children[1 - side]) {
                            // Case_I6
                            self.rotateDir(current_new_parent, side);
                            current_node = current_new_parent;
                            current_new_parent = grandparent.children[side].?;
                        }
                        // Case_I6
                        self.rotateDir(grandparent, 1 - side);
                        current_new_parent.setColor(.black);
                        grandparent.setColor(.red);
                        return;
                    }
                    // Case_I2
                    new_parent.setColor(.black);
                    uncle.setColor(.black);
                    current_node = grandparent;
                    // Iterate 1 black level higher (= 2 tree levels)
                    if (current_node.parent) |new_parent| {
                        current_new_parent = new_parent;
                    } else return;
                }
            }
            // Case_I3: node is the root and red
        } else {
            self.root = node;
        }
    }

    pub fn delete(self: *VmaTree, node: *VmaEntry) void {
        defer node.deinit();
        if (self.root == node and node.children[0] == null and node.children[1] == null) {
            self.root = null;
            return;
        }
        if (node.children[0] != null and node.children[1] != null) {
            // Swap tree position with right minimal node
            const right_min = node.children[1].?.minimum();
            VmaEntry.swapPlaces(node, right_min);
        }
        // Node now has at most one child
        if (node.color == .red) {
            // Node cannot have any children, remove
            node.parent.children[node.getDirectionFromParent()] = null;
            node.parent = null;
            return;
        } else {
            // Node is black
            if (node.children[0]) |left_child| {
                left_child.color = .black;
                left_child.parent = node.parent;
                node.parent.children[node.getDirectionFromParent()] = left_child;
            } else if (node.children[1]) |right_child| {
                right_child.color = .black;
                right_child.parent = node.parent;
                node.parent.children[node.getDirectionFromParent()] = right_child;
            } else {
                // Node has no children
                self.deleteBlackNonRootLeaf(node);
            }
        }
    }

    /// `node` must have a parent.
    fn deleteBlackNonRootLeaf(self: *VmaTree, node: *VmaEntry) void {
        var current_node = node;
        var node_parent_maybe = node.parent;
        var dir = node.getDirectionFromParent();
        node_parent_maybe.?.children[dir] = null;
        while (node_parent_maybe) |node_parent| {
            var sibling = node_parent.children[1 - dir].?;
            var distant_nephew = sibling.children[1 - dir];
            var close_nephew = sibling.children[dir];
            if (sibling.color == .red) {
                // Case_D3
                self.rotateDir(node_parent, dir);
                node_parent.color = .red;
                sibling.color = .black;
                sibling = close_nephew.?;
                distant_nephew = sibling.children[1 - dir];
                if (distant_nephew) |d_n|
                    if (d_n.color == .red) {
                        self.deleteCaseD6(node_parent, sibling, d_n, dir);
                        return;
                    };
                close_nephew = sibling.children[dir];
                if (close_nephew) |c_n|
                    if (c_n.color == .red) {
                        self.deleteCaseD5(node_parent, sibling, c_n, distant_nephew.?, dir);
                        return;
                    };
                self.deleteCaseD4(node_parent, sibling);
                return;
            }
            if (distant_nephew) |d_n|
                if (d.color == .red) {
                    self.deleteCaseD6(node_parent, sibling, d_n, dir);
                    return;
                };
            if (close_nephew) |c_n|
                if (c_n.color == .red) {
                    self.deleteCaseD5(node_parent, sibling, c_n, distant_nephew.?, dir);
                    return;
                };
            if (node_parent.color == .red) {
                self.deleteCaseD4(node_parent, sibling);
                return;
            }
            sibling.color = .red;
            current_node = node_parent;
            dir = current_node.getDirectionFromParent();
            // Iterate 1 black level higher (= 1 tree level)
            node_parent_maybe = current_node.parent;
        }
        // Case_D2: node is the root
    }

    fn deleteCaseD4(self: *VmaTree, node_parent: *VmaEntry, sibling: *VmaEntry) void {
        sibling.color = .red;
        node_parent.color = .black;
    }

    fn deleteCaseD5(
        self: *VmaTree,
        node_parent: *VmaEntry,
        sibling: *VmaEntry,
        close_nephew: *VmaEntry,
        distant_nephew: *VmaEntry,
        dir: u1,
    ) void {
        self.rotateDir(sibling, 1 - dir);
        sibling.color = .red;
        close_nephew.color = .black;
        self.deleteCaseD6(node_parent, close_nephew, sibling, dir);
    }

    fn deleteCaseD6(
        self: *VmaTree,
        node_parent: *VmaEntry,
        sibling: *VmaEntry,
        distant_nephew: *VmaEntry,
        dir: u1,
    ) void {
        self.rotateDir(node_parent, dir);
        sibling.color = node_parent.color;
        node_parent.color = .black;
        distant_nephew.color = .black;
    }

    // TODO Load program in as segments
    // TODO Change setBreak to modify program data segment
};

const VmaEntry = extern struct {
    start_and_color: usize,
    len: usize,
    flags: usize,
    parent: ?*VmaEntry = null,
    children: [2]?*VmaEntry = [_]?*VmaEntry{ null, null },

    pub const Color = enum(u1) {
        red,
        black,
    };

    pub fn deinit(self: *VmaEntry) void {
        // Get VmaPage containing `self`
        const page_mask: usize = page_size - 1;
        const page_address = @ptrToInt(self) & ~page_mask;
        const vma_page = @intToPtr(*allowzero align(page_size) VmaPage, page_address);
        // Calculate index of `self`
        const address_in_page = @ptrToInt(self) & page_mask;
        const array_offset = @byteOffsetOf(VmaPage, "entries");
        const entry_index = (address_in_page - array_offset) / @sizeOf(VmaEntry);
        vma_page.freeEntry(entry_index);
    }

    pub fn getStart(self: *const VmaEntry) usize {
        return self.start_and_color & ~@as(usize, 1);
    }

    pub fn getColor(self: *const VmaEntry) Color {
        return @intToEnum(Color, self.start_and_color & 1);
    }

    pub fn setStart(self: *VmaEntry, start: usize) void {
        const new_start = start & ~@as(usize, 1);
        const color = self.getColor();
        self.start_and_color = new_start | color;
    }

    pub fn setColor(self: *VmaEntry, color: Color) void {
        const new_color = @as(usize, @enumToInt(color));
        const start = self.getStart();
        self.start_and_color = start | new_color;
    }

    /// Undefined behaviour if entry does not have a parent
    pub inline fn getDirectionFromParent(self: *const VmaEntry) u1 {
        const parent = self.parent.?;
        return if (parent.children[0] == self) 0 else 1;
    }

    pub fn minimum(self: *VmaEntry) *VmaEntry {
        var node = self;
        while (node.children[0]) |child| node = child;
        return node;
    }

    pub fn maximum(self: *VmaEntry) *VmaEntry {
        var node = self;
        while (node.children[0]) |child| node = child;
        return node;
    }

    pub fn getNext(self: *VmaEntry) ?*VmaEntry {
        if (self.children[1]) |right_child| return right_child.minimum();
        var current_node = self;
        while (true) {
            const parent = current_node.parent orelse return null;
            if (current_node.getDirectionFromParent() == 0) {
                return parent;
            } else {
                current_node = parent;
            }
        }
    }

    /// Swaps tree places between `a` and `b`, including children and color.
    pub fn swapPlaces(a: *VmaEntry, b: *VmaEntry) void {
        // Update child slot in parents
        const a_parent_maybe = a.parent;
        const b_parent_maybe = b.parent;
        if (a_parent_maybe) |parent| {
            const dir = a.getDirectionFromParent();
            parent.children[dir] = b;
        }
        if (b_parent_maybe) |parent| {
            const dir = b.getDirectionFromParent();
            parent.children[dir] = a;
        }
        // Swap parent pointers
        std.mem.swap(?*VmaEntry, &a.parent, &b.parent);
        // Swap color
        const a_color = a.getColor();
        const b_color = b.getColor();
        a.setColor(b_color);
        b.setColor(a_color);
        // Update and swap children
        var a_children = a.children;
        var b_children = b.children;
        for (a_children) |child_maybe| if (child_maybe) |child| child.parent = b;
        for (b_children) |child_maybe| if (child_maybe) |child| child.parent = a;
        a.children = b_children;
        b.children = a_children;
    }
};

// Testing
// TODO Set up a custom test runner

// test "VmaEntry.deinit" {}

// test "VmaEntry.swapPlaces" {}
