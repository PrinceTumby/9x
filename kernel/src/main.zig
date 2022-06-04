pub const build_options = @import("config/config.zig");
pub const cpio = @import("cpio.zig");
pub const zig_extensions = @import("zig_extensions.zig");
pub const Framebuffer = @import("core_graphics.zig").FrameBuffer;
pub const text_lib = @import("text_lib.zig");
pub const debug_elf = @import("debug_elf.zig");
pub const elf = @import("elf.zig");
pub const heap = @import("heap.zig");
pub const smp = @import("smp.zig");
pub const process = @import("process.zig");
pub const arch = @import("arch.zig");
pub const platform = arch.platform;
pub const KernelArgs = arch.common.KernelArgs;
pub const debugging = @import("debugging.zig");
pub const logging = @import("logging.zig");
pub const misc = @import("misc.zig");
const std = @import("std");
const initPageAllocator = arch.page_allocation.initPageAllocator;
const page_allocator = arch.page_allocation.page_allocator_ptr;
const heap_allocator = heap.heap_allocator_ptr;

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
    logger.debug("{s}:{}", .{src.file, src.line});
    // asm volatile ("xchgw %%bx, %%bx");
}

// Called by the architecture specific initialisation code
export fn kernel_main(args: *KernelArgs) noreturn {
    kernel_args = args;
    // const KERNEL_SIZE = @ptrToInt(&KERNEL_END) - @ptrToInt(&KERNEL_BASE) + 1;
    // const STACK_SIZE = @ptrToInt(&STACK_END) - @ptrToInt(&STACK_BASE) + 1;
    const HEAP_SIZE = @ptrToInt(&HEAP_END) - @ptrToInt(&HEAP_BASE) + 1;
    logger.debug("KERNEL START", .{});
    initPageAllocator(
        args.page_table_ptr,
        args.memory_map.ptr,
        args.memory_map.len,
        args.memory_map.mapped_size,
    );
    logger.debug("Page allocator initialised, map size {}", .{page_allocator.memory_map.len});
    arch.stage1Init(args);
    heap.initHeap(@ptrCast([*]u8, &HEAP_BASE)[0..HEAP_SIZE])
        catch @panic("heap initialisation failed");
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
            const font = text_lib.Font.init(
                heap_allocator.dupe(u8, font_file) catch break :outer
            ) orelse break :outer;
            text_display = text_lib.TextDisplay(Framebuffer).init(
                &fb,
                font,
                heap_allocator,
            // ) catch break :outer;
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
    {
        // Load IA32_STAR
        const user_base: u64 = arch.gdt.offset.user_code_32;
        const kernel_base: u64 = arch.gdt.offset.kernel_code;
        arch.common.msr.write(arch.common.msr.IA32_STAR, user_base << 48 | kernel_base << 32);
        // Load IA32_LSTAR
        logger.debug("Loading IA32_LSTAR with 0x{x}", .{@ptrToInt(syscallEntrypoint)});
        arch.common.msr.write(arch.common.msr.IA32_LSTAR, @ptrToInt(syscallEntrypoint));
        // Load IA32_FMASK
        arch.common.msr.write(arch.common.msr.IA32_FMASK, ~@as(u32, 0x2));
        logger.debug("Set IA32_STAR, IA32_LSTAR and IA32_FMASK", .{});
    }
    // Parse test program ELF
    const test_program_path = "bin/sys/test_program";
    const test_program = cpio.cpioFindFile(initrd, test_program_path)
        orelse @panic("test program not found");
    // const program_elf = (elf.Elf.init(test_program) catch |err| {
    //     logger.emerg("Failure - {}", .{err});
    //     @panic("couldn't parse test program elf");
    // }).Bit64;
    // // Create virtual memory mapper for process
    // var mem_mapper = arch.virtual_page_mapping.VirtualPageMapper.init(page_allocator) catch {
    //     @panic("out of memory");
    // };
    // // Load program segments into memory, mapping and setting flags
    // for (program_elf.program_header) |*entry| {
    //     if (entry.type != .Loadable) continue;
    //     // Get segment in program file
    //     const segment_slice = @ptrCast(
    //         [*]const u8,
    //         &program_elf.file[entry.segment_offset],
    //     )[0..entry.segment_image_size];
    //     // Map segment to process memory
    //     mem_mapper.mapMemCopyFromBuffer(
    //         entry.segment_virt_addr,
    //         entry.segment_memory_size,
    //         segment_slice,
    //     ) catch @panic("out of memory");
    //     // Set flags for segment
    //     mem_mapper.changeFlagsRelaxing(
    //         entry.segment_virt_addr,
    //         arch.paging.PageTableEntry.generateU64(.{
    //             .present = true,
    //             .writable = entry.flags & 2 == 2,
    //             .no_execute = entry.flags & 1 == 0,
    //             .user_accessable = true,
    //         }),
    //         entry.segment_memory_size,
    //     );
    // }
    // const entry_pos = program_elf.header.prog_entry_pos;
    const tls_ptr = arch.tls.getThreadLocalVariables();
    // {
    //     var test_program_process = process.Process{
    //         .process_type = .User,
    //         .page_mapper = mem_mapper,
    //     };
    //     test_program_process.registers.rip = entry_pos;
    //     tls_ptr.current_process = test_program_process;
    // }
    var test_process_1 = process.Process.initUserProcessFromElfFile(test_program) catch |err| {
        logger.emerg("Failed to initalise process - {}", .{err});
        @panic("process init failed");
    };
    var test_process_2 = process.Process.initUserProcessFromElfFile(test_program) catch |err| {
        logger.emerg("Failed to initalise process - {}", .{err});
        @panic("process init failed");
    };
    std.mem.doNotOptimizeAway(&tls_ptr.kernel_main_process);
    while (true) {
        tls_ptr.current_process = test_process_1;
        arch.task.returnToUserProcessFromSyscall(&tls_ptr.current_process);
        switch (tls_ptr.yield_info.reason) {
            .SystemCallRequest => arch.syscall.handleSystemCall(),
            .YieldSystemCall => {},
            else => {
                logger.debug("Unknown yield reason: {}", .{tls_ptr.yield_info.reason});
                @panic("unknown yield reason");
            },
        }
        test_process_1 = tls_ptr.current_process;
        tls_ptr.current_process = test_process_2;
        arch.task.returnToUserProcessFromSyscall(&tls_ptr.current_process);
        switch (tls_ptr.yield_info.reason) {
            .SystemCallRequest => arch.syscall.handleSystemCall(),
            .YieldSystemCall => {},
            else => {
                logger.debug("Unknown yield reason: {}", .{tls_ptr.yield_info.reason});
                @panic("unknown yield reason");
            },
        }
        test_process_2 = tls_ptr.current_process;
    }
    logger.debug("KERNEL END", .{});
    while (true) {
        asm volatile ("hlt");
    }
}

extern fn syscallEntrypoint() callconv(.Naked) void;
