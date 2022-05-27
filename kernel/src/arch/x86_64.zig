//! Collection of modules related to kernel handling of the x86_64 architecture

// Architecture internal support

pub const common = @import("x86_64/common.zig");
pub const gdt = @import("x86_64/gdt.zig");
pub const idt = @import("x86_64/idt.zig");
pub const paging = @import("x86_64/paging.zig");
pub const tss = @import("x86_64/tss.zig");
pub const serial = @import("x86_64/serial.zig");
pub const ps2_controller = @import("x86_64/ps2_8042_controller.zig");
pub const ps2_manager = @import("x86_64/ps2_manager.zig");
pub const apic = @import("x86_64/apic.zig");
pub const clock_manager = @import("x86_64/clock_manager.zig");

// Architecture specific kernel feature implementation

pub const page_allocation = @import("x86_64/page_allocation.zig");
pub const virtual_page_mapping = @import("x86_64/virtual_page_mapping.zig");
pub const interrupts = @import("x86_64/interrupts.zig");
pub const tls = @import("x86_64/tls.zig");

// Other platform exports

pub const build_options = @import("root").build_options.arch.x86_64;
pub const platform = struct {
    pub const acpi = @import("../platform/acpi.zig");
};

// Bootloader stubs

const limine_entry = @import("x86_64/limine_entry.zig");
comptime {
    _ = limine_entry;
}

// Initialisation steps

const std = @import("std");
const KernelArgs = common.KernelArgs;
const root = @import("root");
const logging = root.logging;
const heap_allocator = root.heap.heap_allocator_ptr;
const acpica = platform.acpi.acpica;
const AcpiStatus = acpica.AcpiStatus;
const AcpiBoolean = acpica.AcpiBoolean;

const logger = std.log.scoped(.x86_64);

pub fn stage1Init(_args: *KernelArgs) void {
    gdt.loadNoReloadSegmentDescriptors();
    tss.loadTssIntoGdt();
    interrupts.initIDT();
    logging.tryEnableSerialWriters();
    // Enable bochs writer if port returns 0xE9
    if (common.port.readByte(0xE9) == 0xE9) logging.bochs_writer = .{};
}

pub fn stage2Init(args: *KernelArgs) void {
    // Initialise TLS
    tls.initTls();
    // Initialise ACPICA
    if (args.arch.acpi_ptr) |acpi_ptr| {
        acpica.os_layer.rsdp_pointer = @ptrToInt(acpi_ptr);
    }
    if (acpica.subsystem.initialiseSubsystem().isErr()) {
        @panic("initialising ACPI subsystem failed");
    }
    logger.debug("Initalised ACPI subsystem", .{});
    if (acpica.table_manager.initialiseTables(null, 16, false).isErr()) {
        @panic("initialising ACPI tables failed");
    }
    logger.debug("Initalised ACPI tables", .{});
    // Initialise interrupts
    var madt: *platform.acpi.Madt = undefined;
    clock_manager.updateClockFunctions();
    if (acpica.table_manager.getTable(platform.acpi.Madt, 1, &madt).isErr()) {
        @panic("MADT not found");
    }
    interrupts.apic.initFromMadt(madt);
    clock_manager.apic_timer.calibrate();
    clock_manager.apic_timer.map() catch @panic("out of vectors");
    clock_manager.updateClockFunctions();
    // const before_time: u64 = asm (
    //     \\cpuid
    //     \\rdtsc
    //     \\shlq $32, %%rdx
    //     \\orq %%rdx, %%rax
    //     : [out] "={rax}" (-> u64)
    //     :
    //     : "rdx", "ecx", "ebx"
    // );
    // const power_management_flags: u32 = asm (
    //     "cpuid"
    //     : [out] "={edx}" (-> u32)
    //     : [leaf] "{eax}" (@as(u32, 0x80000007))
    //     : "eax", "ebx", "ecx"
    // );
    // const flags: u32 = asm (
    //     "cpuid"
    //     : [out] "={ecx}" (-> u32)
    //     : [leaf] "{eax}" (@as(u32, 0x00000001))
    //     : "eax", "ebx", "edx"
    // );
    // const after_time: u64 = asm (
    //     \\rdtsc
    //     \\shlq $32, %%rdx
    //     \\orq %%rdx, %%rax
    //     : [out] "={rax}" (-> u64)
    //     :
    //     : "rdx"
    // );
    // logger.debug("Flags: {X}", .{flags});
    // logger.debug("Times: {} vs {}", .{before_time, after_time});
    // while (true) asm volatile ("hlt");
}
