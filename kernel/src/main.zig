const std = @import("std");
const cpio = @import("cpio.zig");
pub const build_options = @import("config/config.zig");
pub const zig_extensions = @import("zig_extensions.zig");
pub const Framebuffer = @import("core_graphics.zig").FrameBuffer;
pub const text_lib = @import("text_lib.zig");
pub const elf = @import("elf.zig");
pub const heap = @import("heap.zig");
pub const smp = @import("smp.zig");
pub const scheduling = @import("scheduling.zig");
pub const arch = @import("arch.zig");
pub const platform = arch.platform;
pub const KernelArgs = arch.common.KernelArgs;
pub const debugging = @import("debugging.zig");
pub const logging = @import("logging.zig");
pub const misc = @import("misc.zig");
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
        args.memory_map.size,
        args.memory_map.mapped_size,
    );
    arch.stage1Init(args);
    heap.initHeap(@ptrCast([*]u8, &HEAP_BASE)[0..HEAP_SIZE])
        catch @panic("heap initialisation failed");
    logger.debug("Heap initialised", .{});
    const initrd = args.initrd.ptr[0..args.initrd.size];
    outer: {
        if (args.framebuffers.len < 1) {
            logger.debug("No framebuffer found", .{});
            break :outer;
        }
        fb = Framebuffer.init(args.framebuffers.ptr[0]) catch |err| {
            logger.debug("Framebuffer failed initialisation: {}", .{err});
            break :outer;
        };
        fb_initialised = true;
        fb.clear();
        if (cpio.cpioFindFile(initrd, font_path)) |font_file| {
            // Init debug text display
            const font = text_lib.Font.init(
                heap_allocator.dupe(u8, font_file) catch break :outer
            ) orelse break :outer;
            text_display = text_lib.TextDisplay(Framebuffer).init(
                &fb,
                font,
                heap_allocator,
            ) catch break :outer;
            text_display_initialised = true;
            logging.enableTextDisplayLogger(&text_display);
        } else {
            @panic("text display failed to initialise");
        }
    }
    if (text_display_initialised)
        logger.debug("Framebuffer initialised", .{})
    else
        logger.debug("Framebuffer not initialised", .{});
    arch.stage2Init(args);
    // Load IA32_STAR
    arch.common.msr.write(arch.common.msr.IA32_STAR, @as(u64, arch.gdt.offset.user_code_32) << 48);
    // Load IA32_FMASK
    arch.common.msr.write(arch.common.msr.IA32_FMASK, 0x2);
    logger.debug("Set IA32_STAR and IA32_FMASK", .{});
    // Parse test program ELF
    const test_program_path = "bin/sys/test_program";
    const test_program = cpio.cpioFindFile(initrd, test_program_path)
        orelse @panic("test program not found");
    const program_elf = (elf.Elf.init(test_program)
        catch @panic("couldn't parse test program elf")).Bit64;
    // Create virtual memory mapper for process
    var mem_mapper = arch.virtual_page_mapping.VirtualPageMapper.init(page_allocator) catch {
        @panic("out of memory");
    };
    // TODO Add in validation of addresses and lengths
    // Load program segments into memory, mapping and setting flags
    for (program_elf.program_header) |*entry| {
        if (entry.type != .Loadable) continue;
        // Get segment in program file
        const segment_slice = @ptrCast(
            [*]const u8,
            &program_elf.file[entry.segment_offset],
        )[0..entry.segment_image_size];
        // Map segment to process memory
        mem_mapper.mapMemCopyFromBuffer(
            entry.segment_virt_addr,
            entry.segment_memory_size,
            segment_slice,
        ) catch @panic("out of memory");
        // Set flags for segment
        mem_mapper.changeFlags(
            entry.segment_virt_addr,
            arch.paging.PageTableEntry.generateU64(.{
                .present = true,
                .writable = entry.flags & 2 == 2,
                .no_execute = entry.flags & 1 == 0,
                .user_accessable = true,
            }),
            entry.segment_memory_size,
        );
    }
    for (@intToPtr(*[512]u64, mem_mapper.page_table.getAddress())) |entry, i| {
        if (entry != 0) logger.debug("Entry {}: {X}", .{i, entry});
    }
    for (@intToPtr(*[512]u64, page_allocator.page_table.getAddress())) |entry, i| {
        if (entry != 0) logger.debug("Entry {}: {X}", .{i, entry});
    }
    const entry_pos = program_elf.header.prog_entry_pos;
    logger.debug("Mapped test program, switching address spaces...", .{});
    // asm volatile ("hlt");
    asm volatile ("movq %%rax, %%cr3"
        :
        : [page_table] "{rax}" (mem_mapper.page_table.getAddress())
        : "memory"
    );
    logger.debug("Address spaces switched!", .{});
    // TODO Figure out why interrupts don't work in switched address space
    arch.interrupts.kernel_idt.load();
    // asm volatile ("hlt");
    @breakpoint();
    asm volatile ("hlt");
    // asm volatile ("callq *%[code]" :: [code] "r" (entry_pos));
    logger.debug("Running test program...", .{});
    // asm volatile ("hlt");
    asm volatile ("sysretq"
        :
        : [rip] "{rcx}" (entry_pos),
          [flags] "{r11}" (@as(u64, 2))
    );
    asm volatile ("hlt");
    // Find a page to store user code
    const code_test_page = page_allocator.findAndReservePage() catch @panic("out of memory");
    logger.debug("Allocated page at 0x{x}", .{@ptrToInt(code_test_page)});
    // Write cli instruction (invalid in ring 3)
    // @intToPtr(*volatile u8, 0xDEADBEEF0).* = 255;
    // logger.debug("{}", .{@intToPtr(*volatile u8, 0xDEADBEEF0).*});
    const test_bytes = [_]u8{
        0x48, 0x8D, 0x05, 0x00, 0x00, 0x00, 0x00, // leaq loop(%rip), %rax
        // loop:
        0xFF, 0xE0, // jmp *%rax
        // 0xFA, // cli
        0xC3, // retq
    };
    for (test_bytes) |byte, i| {
        code_test_page[i] = byte;
    }
    logger.debug("Written test program", .{});
    // Change page to executable only
    page_allocator.changeFlagsRelaxing(
        @ptrToInt(code_test_page),
        arch.paging.PageTableEntry.generateU64(.{
            .present = true,
            .writable = false,
            .user_accessable = true,
        }),
        4096,
    );
    logger.debug("Set flags", .{});
    // logger.debug("Running test...", .{});
    // asm volatile ("sti");
    // logger.debug("RFLAGS: {X}", .{asm ("pushf; popq %[out]" : [out] "=r" (-> usize))});
    // asm volatile ("callq *%[code]" :: [code] "r" (@ptrToInt(code_test_page)));
    // logger.debug("RFLAGS: {X}", .{asm ("pushf; popq %[out]" : [out] "=r" (-> usize))});
    // Execute code
    asm volatile (
        "sysretq"
        :
        : [rip] "{rcx}" (@ptrToInt(code_test_page)),
          [flags] "{r11}" (@as(u64, 0x2))
    );
    // logger.debug("Keyboard tests:", .{});
    // var fadt: *platform.acpi.Fadt = undefined;
    // if (platform.acpi.acpica.table_manager.getTable(platform.acpi.Fadt, 1, &fadt).isErr()) {
    //     @panic("FADT not found");
    // }
    // logger.debug("8042 controller present: {}", .{
    //     fadt.arch_flags & platform.acpi.Fadt.arch_flag_values.ps2_8042_present != 0,
    // });
    // arch.ps2_manager.init() catch |err| {
    //     logger.err("PS/2 Manager Initialisation error: {}", .{err});
    //     @panic("PS/2 init error");
    // };
    // logger.debug("Inititalised PS/2 manager", .{});
    // logger.debug("Now accepting keyboard input:", .{});
    // if (arch.ps2_manager.keyboard) |keyboard| {
    //     while (true) {
    //         // logger.debug("Got byte: {}", .{keyboard.port.readByteBlocking()});
    //         const char = keyboard.getNextCharacter();
    //         // logging.log(.debug, .main, "{c}", .{char});
    //         logging.logRaw("{c}", .{char});
    //         // logging.logRaw("{c}", .{keyboard.getNextCharacter()});
    //         // logger.debug("{c}", .{keyboard.getNextCharacter()});
    //     }
    // }
    logger.debug("KERNEL END", .{});
    while (true) {
        asm volatile ("hlt");
    }
}

const PrintMessageTaskArgs = struct {
    message: []const u8,
};

fn printMessageTaskFunc(args: *PrintMessageTaskArgs) void {
    logging.logString(.info, .print_message_task, "", args.message);
    // logging.log(.info, .print_message_task, "{s}", .{args.message});
}

fn testTaskFunction(_args: *scheduling.VoidType) void {
    logger.info("Hello world!", .{});
}
