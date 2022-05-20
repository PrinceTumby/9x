//! Contains interrupt handlers as well as IDT initialisation

const std = @import("std");
const logger = std.log.scoped(.x86_64_interrupt);
const root = @import("root");
const smp = root.smp;
const heap = root.heap;
const heap_allocator = heap.heap_allocator_ptr;
const platform = root.arch.platform;
const tls = @import("tls.zig");
const pit = @import("clocks/pit.zig");
const rtc = @import("clocks/cmos.zig");
const apic_timer = @import("clocks/apic_timer.zig");
const tss = @import("tss.zig");
const idt = @import("idt.zig");
const InterruptFrame = idt.InterruptFrame;
const InterruptDescriptorTable = idt.InterruptDescriptorTable;

/// Handlers for CPU exceptions
const exception_handlers = struct {
    const exception_logger = std.log.scoped(.x86_64_exception);

    export fn exceptionMessage(msg_ptr: [*]u8, msg_len: usize) noreturn {
        @panic(msg_ptr[0..msg_len]);
    }

    export fn exceptionMessageWithErrCode(
        msg_ptr: [*]u8,
        msg_len: usize,
        error_code: u32,
    ) noreturn {
        exception_logger.debug("Error code: 0x{X}", .{error_code});
        @panic(msg_ptr[0..msg_len]);
    }

    comptime {
        asm (
            \\.macro exception name, message
            \\  1:
            \\  .ascii "\message"
            \\  2:
            \\  .global \name;
            \\  .type \name, @function;
            \\  \name:
            \\    hlt
            \\    movq (%rsp), %rax
            \\    hlt
            \\    andq $-16, %rsp
            \\    hlt
            \\    movq $1b, %rdi
            \\    movq $2b - 1b, %rsi
            \\    pushq %rax
            \\    pushq %rbp
            \\    movq %rsp, %rbp
            \\    callq exceptionMessage
            \\.endm
            \\
            \\.macro exceptionErrCode name, message
            \\  1:
            \\  .ascii "\message"
            \\  2:
            \\  .global \name;
            \\  .type \name, @function;
            \\  \name:
            \\    hlt
            \\    movq 8(%rsp), %rax
            \\    hlt
            \\    movq (%rsp), %rdx
            \\    hlt
            \\    andq $-16, %rsp
            \\    movq $1b, %rdi
            \\    movq $2b - 1b, %rsi
            \\    pushq %rax
            \\    pushq %rbp
            \\    movq %rsp, %rbp
            \\    callq exceptionMessageWithErrCode
            \\.endm
            \\
            \\exception divideByZero, "EXCEPTION: DIVIDE BY ZERO"
            \\exception debug, "EXCEPTION: DEBUG"
            \\exception nonMaskableInterrupt, "EXCEPTION: NON MASKABLE INTERRUPT"
            \\exception overflow, "EXCEPTION: OVERFLOW"
            \\exception boundRangeExceeded, "EXCEPTION: BOUND RANGE EXCEEDED"
            \\exception invalidOpcode, "EXCEPTION: INVALID OPCODE"
            \\exception deviceNotAvailable, "EXCEPTION: DEVICE NOT AVAILABLE"
            \\exceptionErrCode doubleFault, "EXCEPTION: DOUBLE FAULT"
            \\exceptionErrCode invalidTss, "EXCEPTION: INVALID TSS"
            \\exceptionErrCode segmentNotPresent, "EXCEPTION: SEGMENT NOT PRESENT"
            \\exceptionErrCode stackSegmentFault, "EXCEPTION: STACK SEGMENT FAULT"
            \\exceptionErrCode generalProtectionFault, "EXCEPTION: GENERAL PROTECTION FAULT"
            \\exceptionErrCode pageFault, "EXCEPTION: PAGE FAULT"
            \\exception x87FloatingPoint, "EXCEPTION: x87 FLOATING POINT"
            \\exceptionErrCode alignmentException, "EXCEPTION: ALIGNMENT EXCEPTION"
            \\exception machineCheck, "EXCEPTION: MACHINE CHECK"
            \\exception simdFloatingPoint, "EXCEPTION: SIMD FLOATING POINT"
            \\exception virtualization, "EXCEPTION: VIRTUALIZATION"
            \\exceptionErrCode security, "EXCEPTION: SECURITY"
        );
    }

    export fn breakpoint(
        interrupt_frame: *const InterruptFrame,
    ) callconv(.Interrupt) void {
        logger.info("exception - breakpoint", .{});
    }

    extern fn divideByZero(*const InterruptFrame) callconv(.Interrupt) void;
    extern fn debug(*const InterruptFrame) callconv(.Interrupt) void;
    extern fn nonMaskableInterrupt(*const InterruptFrame) callconv(.Interrupt) void;
    extern fn overflow(*const InterruptFrame) callconv(.Interrupt) void;
    extern fn boundRangeExceeded(*const InterruptFrame) callconv(.Interrupt) void;
    extern fn invalidOpcode(*const InterruptFrame) callconv(.Interrupt) void;
    extern fn deviceNotAvailable(*const InterruptFrame) callconv(.Interrupt) void;
    extern fn doubleFault(*const InterruptFrame, u32) callconv(.Interrupt) noreturn;
    extern fn invalidTss(*const InterruptFrame, u32) callconv(.Interrupt) void;
    extern fn segmentNotPresent(*const InterruptFrame, u32) callconv(.Interrupt) void;
    extern fn stackSegmentFault(*const InterruptFrame, u32) callconv(.Interrupt) void;
    extern fn generalProtectionFault(*const InterruptFrame, u32) callconv(.Interrupt) void;
    extern fn pageFault(*const InterruptFrame, u32) callconv(.Interrupt) void;
    extern fn x87FloatingPoint(*const InterruptFrame) callconv(.Interrupt) void;
    extern fn alignmentException(*const InterruptFrame, u32) callconv(.Interrupt) void;
    extern fn machineCheck(*const InterruptFrame) callconv(.Interrupt) noreturn;
    extern fn simdFloatingPoint(*const InterruptFrame) callconv(.Interrupt) void;
    extern fn virtualization(*const InterruptFrame) callconv(.Interrupt) void;
    extern fn security(*const InterruptFrame, u32) callconv(.Interrupt) void;

    pub fn dummyApicEoiHandler(
        _interrupt_frame: *const InterruptFrame,
    ) callconv(.Interrupt) void {
        const bsp_apic = tls.getThreadLocalVariable("local_apic").apic;
        bsp_apic.signalEoi();
    }
};

// IDT handling

// TODO Make this core local
pub var kernel_idt: InterruptDescriptorTable align(16) = InterruptDescriptorTable.new();
var lock = smp.SpinLock.init();

pub inline fn setGenericStackHandler(entry: anytype, handler: anytype) void {
    entry.setHandlerFnWithStackIndex(
        handler,
        @enumToInt(tss.IstIndex.GenericStack),
    );
}

// Initialise IDT
pub fn initIDT() void {
    const handlers = exception_handlers;
    setGenericStackHandler(&kernel_idt.divide_by_zero, handlers.divideByZero);
    setGenericStackHandler(&kernel_idt.debug, handlers.debug);
    setGenericStackHandler(&kernel_idt.non_maskable_interrupt, handlers.nonMaskableInterrupt);
    setGenericStackHandler(&kernel_idt.breakpoint, handlers.breakpoint);
    setGenericStackHandler(&kernel_idt.overflow, handlers.overflow);
    setGenericStackHandler(&kernel_idt.bound_range_exceeded, handlers.boundRangeExceeded);
    setGenericStackHandler(&kernel_idt.invalid_opcode, handlers.invalidOpcode);
    setGenericStackHandler(&kernel_idt.device_not_available, handlers.deviceNotAvailable);
    kernel_idt.double_fault.setHandlerFnWithStackIndex(
        handlers.doubleFault,
        @enumToInt(tss.IstIndex.DoubleFault),
    );
    setGenericStackHandler(&kernel_idt.invalid_tss, handlers.invalidTss);
    setGenericStackHandler(&kernel_idt.segment_not_present, handlers.segmentNotPresent);
    setGenericStackHandler(&kernel_idt.stack_segment_fault, handlers.stackSegmentFault);
    kernel_idt.general_protection_fault.setHandlerFnWithStackIndex(
        handlers.generalProtectionFault,
        @enumToInt(tss.IstIndex.GeneralProtectionFault),
    );
    kernel_idt.page_fault.setHandlerFnWithStackIndex(
        handlers.pageFault,
        @enumToInt(tss.IstIndex.PageFault),
    );
    setGenericStackHandler(&kernel_idt.x87_floating_point, handlers.x87FloatingPoint);
    setGenericStackHandler(&kernel_idt.alignment_check, handlers.alignmentException);
    setGenericStackHandler(&kernel_idt.machine_check, handlers.machineCheck);
    setGenericStackHandler(&kernel_idt.simd_floating_point, handlers.simdFloatingPoint);
    setGenericStackHandler(&kernel_idt.virtualization, handlers.virtualization);
    setGenericStackHandler(&kernel_idt.security, handlers.security);
    setGenericStackHandler(&kernel_idt.apic_interrupts[0], handlers.dummyApicEoiHandler);
    kernel_idt.load();
}

// Interrupt handling
// TODO Add PIC support

var active_io_interrupt_system: enum {
    None,
    Apic,
} = .None;

/// Signals to the interrupt controller that the interrupt handler has ended
pub fn signalEoi() void {
    switch (active_io_interrupt_system) {
        .Apic => tls.getThreadLocalVariable("local_apic").apic.signalEoi(),
        .None => logger.err("signalEoi called with no active interrupt system", .{}),
    }
}

pub const IoHandler = struct {
    idt_entry: *idt.Entry(idt.HandlerFunc),
    interrupt_system_type: InterruptSystemType,
    entry_index: u7,

    pub const InterruptSystemType = enum {
        Apic,
    };
};

pub var legacy_irqs: [16]?IoHandler = [1]?IoHandler{null} ** 16;

pub fn mapLegacyIrq(irq: u4, handler: idt.HandlerFunc) !void {
    const held = lock.acquire();
    defer held.release();
    switch (active_io_interrupt_system) {
        .None => return error.InterruptSystemNotInitialised,
        .Apic => {
            const index = try apic.findAndReserveEntry();
            setGenericStackHandler(&kernel_idt.apic_interrupts[index], handler);
            apic.registerLegacyIrq(irq, 128 + @as(u8, index));
            legacy_irqs[irq] = .{
                .idt_entry = &kernel_idt.apic_interrupts[index],
                .interrupt_system_type = .Apic,
                .entry_index = index,
            };
        },
    }
}

pub fn unmapLegacyIrq(irq: u4) void {
    const held = lock.acquire();
    defer held.release();
    if (legacy_irqs[irq]) |io_handler| {
        apic.unregisterLegacyIrq(irq);
        io_handler.idt_entry.* = idt.Entry(idt.HandlerFunc).missing();
        apic.unreserveEntry(io_handler.entry_index);
        legacy_irqs[irq] = null;
    }
}

pub const apic = struct {
    var local_apics: std.ArrayList(LocalApicEntry) = undefined;
    var io_apics: std.ArrayList(IoApic) = undefined;
    var interrupt_source_overrides: std.ArrayList(InterruptSourceOverride) = undefined;
    var interrupt_vector_map: [2]u64 = [_]u64{ 1 << 63, 0 };

    const LocalApic = @import("apic.zig").LocalApic;

    const LocalApicEntry = struct {
        id: u8,
        acpi_id: ?u8,
        is_bsp: bool,
        flags: u32,
    };

    const IoApic = @import("apic.zig").IoApic;

    const InterruptSourceOverride = struct {
        bus_source: u8,
        irq_source: u8,
        global_system_interrupt: u32,
        flags: u16,
    };

    pub fn initFromMadt(madt: *platform.acpi.Madt) void {
        local_apics = std.ArrayList(LocalApicEntry).init(heap_allocator);
        io_apics = std.ArrayList(IoApic).init(heap_allocator);
        interrupt_source_overrides =
            std.ArrayList(InterruptSourceOverride).init(heap_allocator);
        logger.debug("MADT found at {x}", .{@ptrToInt(madt)});
        logger.debug("MADT length {}", .{madt.length});
        logger.debug("Enabling Local APIC at {x}", .{madt.bsp_local_apic_address});
        const bsp_apic = tls.getThreadLocalVariable("local_apic");
        bsp_apic.apic = LocalApic.init(madt.bsp_local_apic_address);
        bsp_apic.apic.enableBspLocalApic();
        logger.debug("Local APIC enabled", .{});
        const madt_end = madt.getEndAddress();
        var current_address: usize = @ptrToInt(madt) + 44;
        var current_entry = @intToPtr(*platform.acpi.Madt.EntryHeader, current_address);
        logger.debug("MADT start address: {x}", .{current_address});
        logger.debug("MADT end address: {x}", .{madt_end});
        const cpu_id = bsp_apic.apic.readRegister(LocalApic.registers.LapicIdRegister);
        while (current_address < madt_end) : ({
            current_address += current_entry.entry_length;
            current_entry = @intToPtr(*platform.acpi.Madt.EntryHeader, current_address);
        }) {
            logger.debug("entry_type: {}", .{current_entry.entry_type});
            switch (current_entry.entry_type) {
                .LocalApic => {
                    const entry = @ptrCast(
                        *platform.acpi.Madt.entry.LocalApicEntry,
                        current_entry,
                    );
                    local_apics.append(LocalApicEntry{
                        .id = entry.apic_id,
                        .acpi_id = entry.acpi_processor_id,
                        .is_bsp = entry.apic_id == cpu_id,
                        .flags = entry.flags,
                    }) catch @panic("out of memory");
                },
                .IoApic => {
                    const entry = @ptrCast(*platform.acpi.Madt.entry.IoApicEntry, current_entry);
                    io_apics.append(IoApic.init(
                        entry.io_apic_address,
                        entry.io_apic_id,
                        entry.global_system_interrupt_base,
                    )) catch @panic("out of memory");
                },
                .InterruptSourceOverride => {
                    const entry = @ptrCast(
                        *platform.acpi.Madt.entry.InterruptSourceOverrideEntry,
                        current_entry,
                    );
                    interrupt_source_overrides.append(InterruptSourceOverride{
                        .bus_source = entry.bus_source,
                        .irq_source = entry.irq_source,
                        .global_system_interrupt = entry.global_system_interrupt,
                        .flags = entry.flags,
                    }) catch @panic("out of memory");
                },
                else => {},
            }
        }
        active_io_interrupt_system = .Apic;
    }

    // TODO Make this return an error instead of panicking
    /// Registers a legacy IRQ to be sent to `interrupt_vector` on the BSP APIC
    pub fn registerLegacyIrq(irq: u4, interrupt_vector: u8) void {
        const bsp_apic = tls.getThreadLocalVariable("local_apic").apic;
        var polarity: IoApic.RedirectionEntry.Polarity = .High;
        var trigger_mode: IoApic.RedirectionEntry.TriggerMode = .EdgeSensitive;
        const redirected_irq: u32 = blk: for (interrupt_source_overrides.items) |override| {
            if (override.irq_source == irq) {
                polarity = if (override.flags & 2 == 1) .Low else .High;
                trigger_mode = if (override.flags & 8 == 1) .LevelSensitive else .EdgeSensitive;
                if (override.global_system_interrupt > 255) @panic("legacy irq redirect above 255");
                break :blk override.global_system_interrupt;
            }
        } else irq;
        const bsp_id = bsp_apic.readRegister(LocalApic.registers.LapicIdRegister);
        if (bsp_id > 255) @panic("bootstrap processor ID above 255");
        // Set entry in I/O APIC
        for (io_apics.items) |io_apic| {
            const start_irq = io_apic.global_system_interrupt_base;
            const end_irq = start_irq + io_apic.num_redirection_entries;
            if (start_irq <= redirected_irq and redirected_irq < end_irq) {
                const index = redirected_irq - start_irq;
                if (index > 0x3F) @panic("redirection entry out of range");
                io_apic.writeRedirectionEntry(@truncate(u8, index), .{
                    .interrupt_vector = interrupt_vector,
                    .delivery_mode = .Normal,
                    // TODO Support logical APIC addressing
                    .destination_mode = .Physical,
                    .polarity = polarity,
                    .trigger_mode = trigger_mode,
                    .interrupt_mask = false,
                    .destination_field = @truncate(u8, bsp_id),
                });
                break;
            }
        }
    }

    pub fn unregisterLegacyIrq(irq: u4) void {
        const bsp_apic = tls.getThreadLocalVariable("local_apic").apic;
        var polarity: IoApic.RedirectionEntry.Polarity = .High;
        var trigger_mode: IoApic.RedirectionEntry.TriggerMode = .EdgeSensitive;
        const redirected_irq = blk: for (interrupt_source_overrides.items) |override| {
            if (override.irq_source == irq) {
                polarity = if (override.flags & 2 == 1) .Low else .High;
                trigger_mode = if (override.flags & 8 == 1) .LevelSensitive else .EdgeSensitive;
                break :blk override.global_system_interrupt;
            }
        } else irq;
        const bsp_id = bsp_apic.readRegister(LocalApic.registers.LapicIdRegister);
        // Set entry in I/O APIC
        for (io_apics.items) |io_apic| {
            const start_irq = io_apic.global_system_interrupt_base;
            const end_irq = start_irq + io_apic.num_redirection_entries;
            if (start_irq <= redirected_irq and redirected_irq < end_irq) {
                const index = redirected_irq - start_irq;
                if (index > 0x3F) @panic("redirection entry out of range");
                const entry = io_apic.readRedirectionEntry(@truncate(u8, index));
                // FIXME: What on earth does this do?
                io_apic.writeRedirectionEntry(@truncate(u8, index), entry);
            }
        }
    }

    pub fn findAndReserveEntry() !u7 {
        for (interrupt_vector_map) |*group, group_index| {
            if (group.* != ~@as(u64, 0)) {
                const index = @truncate(u6, @clz(u64, ~group.*));
                group.* |= @as(u64, 1 << 63) >> index;
                return @truncate(u7, group_index * 64) + index;
            }
        }
        return error.OutOfVectors;
    }

    pub fn unreserveEntry(entry_index: u7) void {
        const group_index = entry_index >> 6;
        const index_in_group = @truncate(u6, entry_index & 0x3F);
        const mask = ~(@as(u64, 1 << 63) >> index_in_group);
        interrupt_vector_map[group_index] &= mask;
    }
};
