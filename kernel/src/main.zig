pub const arch = @import("arch.zig");
pub const cpio = @import("cpio.zig");
pub const zig_extensions = @import("zig_extensions.zig");
pub const Framebuffer = @import("core_graphics.zig").FrameBuffer;
pub const text_lib = @import("text_lib.zig");
pub const debug_elf = @import("debug_elf.zig");
pub const elf = @import("elf.zig");
pub const heap = @import("heap.zig");
pub const smp = @import("smp.zig");
pub const process = @import("process.zig");
pub const virtual_memory_allocation = @import("virtual_memory_allocation.zig");
pub const platform = arch.platform;
pub const KernelArgs = arch.common.KernelArgs;
pub const debugging = @import("debugging.zig");
pub const logging = @import("logging.zig");
pub const misc = @import("misc.zig");
const std = @import("std");
const page_allocator = arch.page_allocation.page_allocator_ptr;
const heap_allocator = heap.heap_allocator_ptr;
const Process = process.Process;
const range = zig_extensions.range;

const font_path = "etc/kernel/standard_font.psf";

pub var kernel_args: *KernelArgs = undefined;

// Graphics
pub var fb_initialised = false;
pub var fb: Framebuffer = undefined;
pub var text_display_initialised = false;
pub var text_display: text_lib.TextDisplay(Framebuffer) = undefined;
pub const text_display_ptr = &text_display;

// Logging
pub const log = logging.log;
pub const log_level: std.log.Level = .debug;
const logger = std.log.scoped(.main);

// Debugging
pub const panic = debugging.panic;

// ELF symbols
pub extern var KERNEL_BASE: u8;
pub extern var KERNEL_END: u8;
pub extern var TEMP_MAPPING_AREA_BASE: u8;
pub extern var TEMP_MAPPING_AREA_END: u8;
pub extern var STACK_BASE: u8;
pub extern var STACK_END: u8;
pub extern var HEAP_BASE: u8;
pub extern var HEAP_END: u8;
pub extern var FONT_START: u8;
pub extern var FONT_END: u8;
pub extern var FRAMEBUFFER_START: u32;
pub extern var FRAMEBUFFER_END: u32;

pub fn breakpointLine(src: std.builtin.SourceLocation) void {
    logger.debug("{s}:{}", .{ src.file, src.line });
    // asm volatile ("xchgw %%bx, %%bx");
}

comptime {
    if (std.builtin.cpu.arch == .arm) {
        @export(arm_kernel_main, .{ .name = "kernel_main", .linkage = .Strong });
    } else {
        @export(kernel_main, .{ .name = "kernel_main", .linkage = .Strong });
    }
}

fn arm_kernel_main(args: *KernelArgs) callconv(.C) noreturn {
    if (@hasDecl(arch, "initEarlyLoggers")) arch.initEarlyLoggers();
    kernel_args = args;
    logger.debug("KERNEL START", .{});
    while (true) {}
}

// Called by the architecture specific initialisation code
fn kernel_main(args: *KernelArgs) callconv(.C) noreturn {
    if (@hasDecl(arch, "initEarlyLoggers")) arch.initEarlyLoggers();
    // asm volatile ("hlt");
    // TODO Remove this? Doesn't look like it's actually used anywhere
    kernel_args = args;
    // const KERNEL_SIZE = @ptrToInt(&KERNEL_END) - @ptrToInt(&KERNEL_BASE) + 1;
    // const STACK_SIZE = @ptrToInt(&STACK_END) - @ptrToInt(&STACK_BASE) + 1;
    const HEAP_SIZE = @ptrToInt(&HEAP_END) - @ptrToInt(&HEAP_BASE) + 1;
    logger.debug("KERNEL START", .{});
    arch.page_allocation.initPageAllocator(
        args.page_table_ptr,
        args.memory_map.ptr,
        args.memory_map.len,
        args.memory_map.mapped_size,
    );
    logger.debug("Page allocator initialised, map size {}", .{page_allocator.memory_map.len});
    arch.stage1Init(args);
    heap.initHeap(@ptrCast([*]u8, &HEAP_BASE)[0..HEAP_SIZE]) catch {
        @panic("heap initialisation failed");
    };
    logger.debug("Heap initialised: root block {}", .{heap.list_head.?});
    const initrd = args.initrd.ptr[0..args.initrd.len];
    outer: {
        if (args.framebuffers.len < 1) {
            logger.debug("No framebuffer found", .{});
            break :outer;
        }
        fb = Framebuffer.init(args.framebuffers.ptr[0]) catch |err| {
            logger.debug("Framebuffer failed initialisation: {}", .{err});
            break :outer;
        };
        fb.clear();
        fb_initialised = true;
        if (cpio.cpioFindFile(initrd, font_path)) |font_file| {
            // Init debug text display
            const heap_font = heap_allocator.dupe(u8, font_file) catch break :outer;
            const font = text_lib.Font.init(heap_font) orelse break :outer;
            text_display = text_lib.TextDisplay(Framebuffer).init(
                &fb,
                font,
                heap_allocator,
            ) catch |err| {
                logger.debug("text display initialisation failed: {}", .{err});
                break :outer;
            };
            text_display_initialised = true;
            logging.enableTextDisplayLogger(&text_display);
        } else break :outer;
    }
    if (text_display_initialised)
        logger.debug("Framebuffer initialised", .{})
    else
        logger.debug("Framebuffer not initialised", .{});
    arch.stage2Init(args);
    logger.debug("CPU Vendor ID: {s}", .{arch.cpuid.cpu_vendor_id});
    logger.debug("CPU Brand String: {s}", .{arch.cpuid.brand_string});
    logger.debug("Invariant TSC: {}", .{arch.cpuid.invariant_tsc});
    logger.debug("Local APIC Timer TSC Deadline: {}", .{arch.cpuid.local_apic_timer_tsc_deadline});
    // Parse test program ELF
    const test_program_path = "bin/sys/test_program";
    const test_program = cpio.cpioFindFile(initrd, test_program_path) orelse {
        @panic("test program not found");
    };
    const test_zig_program_path = "bin/sys/test_zig_program";
    const test_zig_program = cpio.cpioFindFile(initrd, test_zig_program_path) orelse {
        @panic("test zig program not found");
    };
    const tls_ptr = arch.tls.getThreadLocalVariables();
    arch.clock_manager.setInterruptType(.ContextSwitch);
    if (text_display_initialised) while (true) {
        asm volatile ("hlt");
    };
    // Create processes
    for (range(1)) |_| {
        var example_process = heap_allocator.create(Process) catch @panic("out of memory");
        example_process.* = Process.initUserProcessFromElfFile(test_program) catch |err| {
            logger.emerg("Failed to initalise process - {}", .{err});
            @panic("process init failed");
        };
        process.process_list.push(127, example_process);
    }
    // {
    //     arch.tss.iopb_ptr.allowPort(0x3F8);
    //     arch.tss.iopb_ptr.allowPort(0x3FD);
    //     arch.tss.iopb_ptr.disallowPort(0x3F8);
    //     // if (@ptrToInt(&KERNEL_BASE) > 0) while (true) {};
    // }
    outer: while (true) {
        const new_process_ptr = process.process_list.tryPop() orelse break;
        tls_ptr.current_process = new_process_ptr.*;
        tls_ptr.current_process_heap_ptr = new_process_ptr;
        arch.clock_manager.startCountdown(100);
        arch.clock_manager.acknowledgeCountdownInterrupt();
        const start_time = arch.clock_manager.tsc.readCounter();
        while (true) {
            asm volatile ("xchgw %%bx, %%bx");
            arch.task.resumeUserProcess(&tls_ptr.current_process);
            // TODO Switch interrupt handlers whenever we start up a new async task.
            switch (tls_ptr.yield_info.reason) {
                .timeout => {
                    break;
                },
                .system_call_request => arch.syscall.handleSystemCall(),
                .yield_system_call => break,
                .exception => arch.syscall.handleException(),
                else => {
                    logger.debug("Unknown yield reason: {}", .{tls_ptr.yield_info.reason});
                    @panic("unknown yield reason");
                },
            }
            if (arch.clock_manager.getCountdownRemainingTime() == 0) {
                tls_ptr.yield_info.reason = .timeout;
                // arch.clock_manager.acknowledgeCountdownInterrupt();
                logger.debug("Kernel timeout!", .{});
                break;
            }
        }
        const end_time = arch.clock_manager.tsc.readCounter();
        logger.debug("Ticks spent: {}", .{end_time - start_time});
        new_process_ptr.* = tls_ptr.current_process;
        process.process_list.push(127, new_process_ptr);
    }
    logger.debug("KERNEL END", .{});
    while (true) {
        asm volatile ("hlt");
    }
}

// TODO Make testing work (root points to std.special, need a custom test environment or runner)
// test "All Tests" {
//     std.testing.refAllDecls(virtual_memory_allocation);
// }
