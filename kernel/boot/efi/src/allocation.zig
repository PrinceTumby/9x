//! Simple Zig standard allocator wrapper for UEFI memory allocation

const std = @import("std");
const Allocator = std.mem.Allocator;
const uefi = std.os.uefi;

const logger = std.log.scoped(.allocation);
pub const Error = Allocator.Error;

pub const EfiAllocator = struct {
    dummy: u8 = 0,

    fn alloc(
        _: *EfiAllocator,
        len: usize,
        ptr_align: u29,
        len_align: u29,
        _: usize,
    ) Error![]u8 {
        const allocatePool = uefi.system_table.boot_services.?.allocatePool;
        switch (ptr_align) {
            0, 1, 2, 4, 8 => {},
            // Alignments incompatible with 8 bytes are unlikely in current bootloader
            else => @panic("alignment other than 8 bytes not supported"),
        }
        const fixed_len_align = if (len_align == 0) 1 else len_align;
        const alloc_len = std.mem.alignForward(len, fixed_len_align);
        var alloc_ptr: [*]align(8) u8 = undefined;
        switch (allocatePool(.LoaderData, alloc_len, &alloc_ptr)) {
            .Success => return alloc_ptr[0..alloc_len],
            .OutOfResources => return Error.OutOfMemory,
            else => |err| {
                logger.err("allocatePool returned unknown error {}", .{err});
                @panic("allocatePool returned unknown error");
            },
        }
    }

    usingnamespace Allocator.NoResize(EfiAllocator);

    fn free(
        _: *EfiAllocator,
        buf: []u8,
        _: u29,
        _: usize,
    ) void {
        const freePool = uefi.system_table.boot_services.?.freePool;
        switch (freePool(@alignCast(8, buf.ptr))) {
            .Success => return,
            else => |err| {
                logger.err("freePool returned unknown error {}", .{err});
                @panic("freePool returned unknown error");
            }
        }
    }

    pub fn allocator(self: *EfiAllocator) Allocator {
        return Allocator.init(self, alloc, EfiAllocator.noResize, free);
    }
};

pub var efi_allocator = EfiAllocator{};
