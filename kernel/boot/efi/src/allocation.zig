//! Simple Zig standard allocator wrapper for UEFI memory allocation

const std = @import("std");
const Allocator = std.mem.Allocator;
const uefi = std.os.uefi;

const logger = std.log.scoped(.allocation);
pub const Error = Allocator.Error;

fn alloc(
    self: *Allocator,
    len: usize,
    ptr_align: u29,
    len_align: u29,
    ret_addr: usize,
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
            logger.emerg("allocatePool returned unknown error {}", .{err});
            @panic("allocatePool returned unknown error");
        },
    }
}

fn resize(
    self: *Allocator,
    buf: []u8,
    buf_align: u29,
    new_len: usize,
    len_align: u29,
    ret_addr: usize,
) Error!usize {
    if (new_len > buf.len) {
        return error.OutOfMemory;
    } else if (new_len == 0) {
        const freePool = uefi.system_table.boot_services.?.freePool;
        switch (freePool(@alignCast(8, buf.ptr))) {
            .Success => return 0,
            else => |err| {
                logger.emerg("freePool returned unknown error {}", .{err});
                @panic("freePool returned unknown error");
            }
        }
    } else {
        return new_len;
    }
}

pub fn getAllocator() Allocator {
    return Allocator{
        .allocFn = alloc,
        .resizeFn = resize,
    };
}
