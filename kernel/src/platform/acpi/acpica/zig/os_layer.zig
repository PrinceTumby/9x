const std = @import("std");
const root = @import("root");
const logging = root.logging;
const LogWriter = logging.LogWriter;
const page_allocator = root.arch.page_allocation.page_allocator_ptr;
const heap_allocator = root.heap.kernel_heap_allocator.allocator();
const acpica = @import("../../acpica.zig");
const AcpiStatus = acpica.AcpiStatus;
const AcpiBoolean = acpica.AcpiBoolean;

const logger = std.log.scoped(.acpica);

pub var rsdp_pointer: usize = 0;

// Environment and tables

export fn AcpiOsInitialize() AcpiStatus {
    return AcpiStatus.Ok;
}

export fn AcpiOsTerminate() AcpiStatus {
    return AcpiStatus.Ok;
}

export fn AcpiOsGetRootPointer() u64 {
    return rsdp_pointer;
}

export fn AcpiOsPredefinedOverride(_: usize, new_value: *?*anyopaque) AcpiStatus {
    new_value.* = null;
    return AcpiStatus.Ok;
}

export fn AcpiOsTableOverride(_: usize, new_table: *?*anyopaque) AcpiStatus {
    new_table.* = null;
    return AcpiStatus.Ok;
}

export fn AcpiOsPhysicalTableOverride(
    _: *anyopaque,
    new_table: *?*anyopaque,
    _: u32,
) AcpiStatus {
    new_table.* = null;
    return AcpiStatus.Ok;
}

// Memory management

export fn AcpiOsMapMemory(physical_address: u64, _: usize) usize {
    // SAFETY: Entirety of physical memory is identity mapped, so this should be fine
    return physical_address;
}

export fn AcpiOsUnmapMemory(_: u64, _: usize) AcpiStatus {
    // No mapping is done in AcpiOsMapMemory, so we do nothing here
    return AcpiStatus.Ok;
}

export fn AcpiOsGetPhysicalAddress(logical_address: usize, physical_address: *u64) AcpiStatus {
    // All of physical memory is identity mapped
    physical_address.* = logical_address;
    return AcpiStatus.Ok;
}

export fn AcpiOsAllocate(length: usize) ?[*]u8 {
    return (heap_allocator.alloc(u8, length) catch return null).ptr;
}

export fn AcpiOsFree(ptr: [*]u8) void {
    // SAFETY: Current heap allocator does not rely on knowing size of allocation
    heap_allocator.free(ptr[0..1]);
}

export fn AcpiOsReadable(virtual_address_start: usize, len: usize) AcpiBoolean {
    return AcpiBoolean.fromBool(page_allocator.checkFlags(virtual_address_start, len, 0x1));
}

export fn AcpiOsWritable(virtual_address_start: usize, len: usize) AcpiBoolean {
    return AcpiBoolean.fromBool(page_allocator.checkFlags(virtual_address_start, len, 0x3));
}

// Mutual exclusion and synchronization

export fn AcpiOsCreateMutex(out_handle_maybe: ?*?*bool) AcpiStatus {
    const out_handle = out_handle_maybe orelse return AcpiStatus.BadParameter;
    const dummy_mutex = heap_allocator.create(bool) catch return AcpiStatus.NoMemory;
    dummy_mutex.* = false;
    out_handle.* = dummy_mutex;
    return AcpiStatus.Ok;
}

export fn AcpiOsDeleteMutex(handle_maybe: ?*bool) void {
    const handle = handle_maybe orelse return;
    heap_allocator.destroy(handle);
}

export fn AcpiOsAcquireMutex(handle_maybe: ?*bool, timeout: u16) AcpiStatus {
    const handle = handle_maybe orelse return AcpiStatus.BadParameter;
    if (handle.*) {
        if (timeout == 0xFFFF) {
            @panic("mutex poisoned");
        } else {
            return AcpiStatus.Time;
        }
    } else {
        handle.* = true;
        return AcpiStatus.Ok;
    }
}

export fn AcpiOsReleaseMutex(handle_maybe: ?*bool) void {
    const handle = handle_maybe orelse return;
    if (handle.*) {
        handle.* = false;
    } else {
        @panic("mutex poisoned");
    }
}

export fn AcpiOsCreateSemaphore(
    max_units: u32,
    initial_units: u32,
    out_handle_maybe: ?*?*anyopaque,
) AcpiStatus {
    if (initial_units > max_units) return AcpiStatus.BadParameter;
    const out_handle = out_handle_maybe orelse return AcpiStatus.BadParameter;
    out_handle.* = null;
    logger.debug("Semaphore {*} created, {} max, {} initial", .{
        out_handle,
        max_units,
        initial_units,
    });
    return AcpiStatus.Ok;
}

export fn AcpiOsDeleteSemaphore(handle: ?*anyopaque) AcpiStatus {
    logger.debug("Semaphore {*} destroyed", .{handle});
    return AcpiStatus.Ok;
}

export fn AcpiOsWaitSemaphore(handle: ?*anyopaque, units: u32, timeout: u16) AcpiStatus {
    logger.debug("Semaphore {*} waited, {} units, {}ms timeout", .{
        handle,
        units,
        timeout,
    });
    return AcpiStatus.Ok;
}

export fn AcpiOsSignalSemaphore(handle: *anyopaque, units: u32) AcpiStatus {
    logger.debug("Semaphore {*} signalled, {} units", .{handle, units});
    return AcpiStatus.Ok;
}

export fn AcpiOsCreateLock(out_handle_maybe: ?*?*anyopaque) AcpiStatus {
    const out_handle = out_handle_maybe orelse return AcpiStatus.BadParameter;
    out_handle.* = null;
    logger.debug("Lock {*} created", .{out_handle});
    return AcpiStatus.Ok;
}

export fn AcpiOsDeleteLock(handle: ?*anyopaque) void {
    logger.debug("Lock {*} destroyed", .{handle});
}

export fn AcpiOsAcquireLock(_: ?*anyopaque) usize {
    // logger.debug("Lock {*} acquired", .{handle});
    return 0;
}

export fn AcpiOsReleaseLock(_: ?*anyopaque, _: usize) void {
    // logger.debug("Lock {*} released", .{handle});
}

// Printing functions, actual Printf and Vprintf defined in extra C file

export fn AcpiCustomOsPanic(message: [*:0]const u8) void {
    @panic(std.mem.span(message));
}

export fn AcpiCustomOsPrintPrefix() void {
    root.logging.logNoNewline(.debug, .acpica, "\n", .{});
}

export fn AcpiCustomOsPrintString(ptr: [*]const u8, len: usize) void {
    root.logging.logRaw("{s}", .{ptr[0..len]});
}

export fn AcpiCustomOsPrintStringWithOptions(
    ptr: [*]const u8,
    len: usize,
    precision: usize,
    width: usize,
    alignment: u8,
    fill: u8,
) void {
    std.fmt.formatBuf(
        ptr[0..len],
        std.fmt.FormatOptions{
            .precision = @as(?u64, if (precision != 1) precision else null),
            .width = @as(?u64, if (width != 0) width else null),
            .alignment = switch (alignment) {
                0 => .Left,
                1 => .Center,
                2 => .Right,
                else => @panic("invalid int alignment option"),
            },
            .fill = fill,
        },
        root.logging.log_writer,
    ) catch {};
}

export fn AcpiCustomOsPrintChar(character: u8) void {
    root.logging.logRaw("{c}", .{character});
}

export fn AcpiCustomOsPrintSignedInt(
    num: isize,
    precision: usize,
    width: usize,
    alignment: u8,
    fill: u8,
) void {
    std.fmt.formatInt(
        num,
        10,
        .lower,
        std.fmt.FormatOptions{
            .precision = @as(?u64, if (precision != 1) precision else null),
            .width = @as(?u64, if (width != 0) width else null),
            .alignment = switch (alignment) {
                0 => .Left,
                1 => .Center,
                2 => .Right,
                else => @panic("invalid int alignment option"),
            },
            .fill = fill,
        },
        root.logging.log_writer,
    ) catch {};
}

export fn AcpiCustomOsPrintInt(
    num: usize,
    base: u8,
    uppercase: u8,
    precision: usize,
    width: usize,
    alignment: u8,
    fill: u8,
) void {
    std.fmt.formatInt(
        num,
        base,
        if (uppercase == 0) std.fmt.Case.lower else std.fmt.Case.upper,
        std.fmt.FormatOptions{
            .precision = @as(?u64, if (precision != 0) precision else null),
            .width = @as(?u64, if (width != 0) width else null),
            .alignment = switch (alignment) {
                0 => .Left,
                1 => .Center,
                2 => .Right,
                else => @panic("invalid int alignment option"),
            },
            .fill = fill,
        },
        root.logging.log_writer,
    ) catch {};
}

export fn AcpiCustomOsPrintNewline() void {
    root.logging.logRaw("\n", .{});
}

// TODO Replace dummy functions with proper implementations

export fn AcpiOsGetThreadId() u64 {
    return 1;
}

export fn AcpiOsExecute(_: usize, _: *anyopaque, _: *anyopaque) AcpiStatus {
    @panic("AcpiOsExecute unimplemented");
}

export fn AcpiOsSleep(_: u64) void {
    @panic("AcpiOsSleep unimplemented");
}

export fn AcpiOsStall(_: u32) void {
    @panic("AcpiOsStall unimplemented");
}

export fn AcpiOsWaitEventsComplete() void {
    @panic("AcpiOsWaitEventsComplete unimplemented");
}

export fn AcpiOsAcquireGlobalLock(_: *u32) AcpiStatus {
    @panic("AcpiOsAcquireGlobalLock unimplemented");
}

export fn AcpiOsReleaseGlobalLock(_: *u32) AcpiStatus {
    @panic("AcpiOsReleaseGlobalLock unimplemented");
}

export fn AcpiOsInstallInterruptHandler(_: u32, _: *anyopaque, _: *anyopaque) AcpiStatus {
    @panic("AcpiOsInstallInterruptHandler unimplemented");
}

export fn AcpiOsRemoveInterruptHandler(_: u32, _: *anyopaque) AcpiStatus {
    @panic("AcpiOsRemoveInterruptHandler unimplemented");
}

export fn AcpiOsReadMemory(_: usize, _: *u64, _: u32) AcpiStatus {
    @panic("AcpiOsReadMemory unimplemented");
}

export fn AcpiOsWriteMemory(_: usize, _: u64, _: u32) AcpiStatus {
    @panic("AcpiOsWriteMemory unimplemented");
}

export fn AcpiOsReadPort(_: usize, _: *u32, _: u32) AcpiStatus {
    @panic("AcpiOsReadPort unimplemented");
}

export fn AcpiOsWritePort(_: usize, _: u32, _: u32) AcpiStatus {
    @panic("AcpiOsWritePort unimplemented");
}

export fn AcpiOsReadPciConfiguration() AcpiStatus {
    @panic("AcpiOsReadPciConfiguration unimplemented");
}

export fn AcpiOsWritePciConfiguration() AcpiStatus {
    @panic("AcpiOsWritePciConfiguration unimplemented");
}

export fn AcpiOsRedirectOutput(_: *anyopaque) AcpiStatus {
    @panic("AcpiOsRedirectOutput unimplemented");
}

export fn AcpiOsGetTimer() u64 {
    @panic("AcpiOsGetTimer unimplemented");
}

export fn AcpiOsSignal(_: u32, _: *anyopaque) AcpiStatus {
    @panic("AcpiOsSignal unimplemented");
}

export fn AcpiOsEnterSleep(_: u8, _: u32, _: u32) AcpiStatus {
    @panic("AcpiOsEnterSleep unimplemented");
}
