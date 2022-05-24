const std = @import("std");
const root = @import("root");
const limine = @import("limine.zig");
const common = @import("common.zig");
const paging = @import("paging.zig");
const page_allocation = @import("page_allocation.zig");
const AbstractWriter = root.logging.AbstractWriter;
const logging = root.logging;
const Terminal = limine.LimineTerminal;
const KernelArgs = common.KernelArgs;
const PageAllocator = page_allocation.PageAllocator;

const logger = std.log.scoped(.limine_stub);

export var entry_point_request_ptr linksection(".limine_reqs") = &entry_point_request;
export var entry_point_request align(8) = limine.requests.EntryPoint{
    .entry = limine_entry,
};

export var terminal_request_ptr linksection(".limine_reqs") = &terminal_request;
export var terminal_request align(8) = limine.requests.Terminal{
    .callback = terminal_callback,
};

export var framebuffer_request_ptr linksection(".limine_reqs") = &framebuffer_request;
export var framebuffer_request align(8) = limine.requests.Framebuffer{};

export var kernel_file_request_ptr linksection(".limine_reqs") = &kernel_file_request;
export var kernel_file_request align(8) = limine.requests.KernelFile{};

export var module_request_ptr linksection(".limine_reqs") = &module_request;
export var module_request align(8) = limine.requests.Module{};

export var rsdp_request_ptr linksection(".limine_reqs") = &rsdp_request;
export var rsdp_request align(8) = limine.requests.Rsdp{};

export var smbios_request_ptr linksection(".limine_reqs") = &smbios_request;
export var smbios_request align(8) = limine.requests.Module{};

export var efi_system_table_request_ptr linksection(".limine_reqs") = &efi_system_table_request;
export var efi_system_table_request align(8) = limine.requests.EfiSystemTable{};

export var memory_map_request_ptr linksection(".limine_reqs") = &memory_map_request;
export var memory_map_request align(8) = limine.requests.MemoryMap{};

fn terminal_callback(
    _terminal: *limine.LimineTerminal,
    _type: u64,
    _param1: u64,
    _param2: u64,
    _param3: u64,
) callconv(.C) void {}

pub const terminal_writer = struct {
    var write_buffer: [256]u8 = undefined;
    var terminalWriteFunc: fn (*c_void, [*]const u8, u64) callconv(.C) void = undefined;

    pub const Error = AbstractWriter.Error;

    pub inline fn writeAll(terminal: *c_void, bytes: []const u8) Error!void {
        terminalWriteFunc(terminal, bytes.ptr, bytes.len);
    }

    pub fn writeByte(terminal: *c_void, byte: u8) Error!void {
        const char = [1]u8{byte};
        terminalWriteFunc(terminal, &char, 1);
    }

    pub fn writeByteNTimes(terminal: *c_void, byte: u8, n: usize) Error!void {
        std.mem.set(u8, write_buffer[0..], byte);
        var remaining: usize = n;
        while (remaining > 0) {
            const to_write = std.math.min(remaining, write_buffer.len);
            try writeAll(terminal, write_buffer[0..to_write]);
            remaining -= to_write;
        }
    }

    pub fn createAbstractWriter(terminal: *Terminal) AbstractWriter {
        return AbstractWriter{
            .writer_pointer = @ptrCast(*c_void, terminal),
            .writeAllFunc = writeAll,
            .writeByteFunc = writeByte,
            .writeByteNTimesFunc = writeByteNTimes,
        };
    }
};

extern fn init64(kernel_args_ptr: *KernelArgs) noreturn;
extern var STACK_BASE: u8;

fn limine_entry() callconv(.C) void {
    // Setup stack, enable SSE
    asm volatile (
        \\andq $~0xF, %%rsp
        \\movq %%rsp, %%rbp
        \\movq %%cr0, %%rax
        \\andw $0xFFFB, %%ax
        \\orw $0x2, %%ax
        \\movq %%rax, %%cr0
        \\movq %%cr4, %%rax
        \\orw $(3 << 9), %%ax
        \\movq %%rax, %%cr4
        :
        :
        : "rax"
    );
    // root.debugging.disable_trace_logging = true;
    // Add logging devices for Limine terminals
    if (terminal_request.response) |terminal_info| terminal: {
        terminal_writer.terminalWriteFunc = @ptrCast(
            @TypeOf(terminal_writer.terminalWriteFunc),
            terminal_info.write,
        );
        var i: usize = 0;
        while (i < terminal_info.terminal_count) : (i += 1) {
            const new_writer = terminal_writer.createAbstractWriter(terminal_info.terminals[i]);
            logging.abstract_writers.append(new_writer) catch break :terminal;
        }
        if (terminal_info.terminal_count == 1) {
            logger.debug("Initialised 1 terminal", .{});
        } else {
            logger.debug("Initialised {} terminals", .{terminal_info.terminal_count});
        }
    }
    // Get kernel ELF for debugging symbols
    const kernel_file_response = kernel_file_request.response
        orelse @panic("bootloader didn't provide kernel file");
    const kernel_file = kernel_file_response.kernel_file;
    root.debugging.kernel_elf_file = kernel_file.address[0..kernel_file.size];
    // Get memory map from bootloader
    const memory_map_response = memory_map_request.response
        orelse @panic("bootloader didn't provide a memory map");
    const memory_map = memory_map_response.entries[0..memory_map_response.entry_count];
    // Get highest mappable address
    const total_mappable_size: usize = blk: {
        var return_size: usize = 0;
        for (memory_map) |entry| {
            const end_address = entry.base + entry.length;
            if (end_address > return_size) return_size = end_address;
        }
        break :blk return_size;
    };
    // Generate kernel memory map, create page allocator
    var page_allocator = allocator_blk: {
        // Bit indexing masks
        const start_masks = [8]u8{
            0b11111111,
            0b01111111,
            0b00111111,
            0b00011111,
            0b00001111,
            0b00000111,
            0b00000011,
            0b00000001,
        };
        const end_masks = [8]u8{
            0b10000000,
            0b11000000,
            0b11100000,
            0b11110000,
            0b11111000,
            0b11111100,
            0b11111110,
            0b11111111,
        };
        // Number of mapped bytes per bit
        const bit_ratio: usize = 4096;
        // Number of mapped bytes per byte
        const byte_ratio: usize = bit_ratio * 8;
        // Allocate kernel memory map
        const memory_map_page_size = std.mem.alignForward(total_mappable_size / byte_ratio, 4096);
        const kernel_memory_map = blk: for (memory_map) |entry| {
            if (entry.type == .Usable and entry.length >= memory_map_page_size) {
                break :blk @intToPtr([*]u8, entry.base)[0..memory_map_page_size];
            }
        } else @panic("not enough contiguous memory for memory map");
        // Set memory to all used
        for (kernel_memory_map) |*byte| {
            byte.* = 0xFF;
        }
        // Clear usable entries
        for (memory_map) |entry| {
            if (entry.type != .Usable) continue;
            const start_bit_index = entry.base / bit_ratio;
            const end_bit_index = start_bit_index +
                if (entry.length / bit_ratio > 0)
                    entry.length / bit_ratio - 1
                else
                    0;
            const start_index = start_bit_index / 8;
            const end_index = end_bit_index / 8;
            const start_bit_pos = @truncate(u3, start_bit_index);
            const end_bit_pos = @truncate(u3, end_bit_index);
            if (start_index == end_index) {
                kernel_memory_map[start_index] &=
                    ~start_masks[start_bit_pos] | ~end_masks[end_bit_pos];
            } else {
                kernel_memory_map[start_index] &= ~start_masks[start_bit_pos];
                var cur_index: usize = start_index + 1;
                while (cur_index < end_index) : (cur_index += 1) {
                    kernel_memory_map[cur_index] = 0;
                }
                kernel_memory_map[end_index] &= ~end_masks[end_bit_pos];
            }
        }
        // Reserve kernel memory map allocation in kernel memory map
        {
            const start_bit_index = @ptrToInt(kernel_memory_map.ptr) / bit_ratio;
            const end_bit_index = start_bit_index +
                if (kernel_memory_map.len / bit_ratio > 0)
                    kernel_memory_map.len / bit_ratio - 1
                else
                    0;
            const start_index = start_bit_index / 8;
            const end_index = end_bit_index / 8;
            const start_bit_pos = @truncate(u3, start_bit_index);
            const end_bit_pos = @truncate(u3, end_bit_index);
            if (start_index == end_index) {
                kernel_memory_map[start_index] |=
                    start_masks[start_bit_pos] & end_masks[end_bit_pos];
            } else {
                kernel_memory_map[start_index] |= start_masks[start_bit_pos];
                var cur_index: usize = start_index + 1;
                while (cur_index < end_index) : (cur_index += 1) {
                    kernel_memory_map[cur_index] = 0xFF;
                }
                kernel_memory_map[end_index] |= end_masks[end_bit_pos];
            }
        }
        logger.debug(
            "Allocated kernel_memory_map - ptr: {*}, len: {x}",
            .{kernel_memory_map.ptr, kernel_memory_map.len},
        );
        break :allocator_blk PageAllocator.new(
           asm ("movq %%cr3, %[out]" : [out] "=r" (-> *[512]u64)),
           kernel_memory_map,
           total_mappable_size / 4096,
       );
    };
    // Allocate kernel stack
    page_allocator.mapPage(
        @ptrToInt(&STACK_BASE),
        paging.PageTableEntry.generateU64(.{
            .present = true,
            .writable = true,
            .no_execute = true,
        }),
    ) catch @panic("out of memory allocating kernel stack");
    // Allocate kernel arguments
    const kernel_args_ptr = @ptrCast(
        *KernelArgs,
        page_allocator.findAndReservePage() catch @panic("out of memory"),
    );
    // Allocate framebuffers
    var framebuffers_arg = @TypeOf(kernel_args_ptr.framebuffers){
        .ptr = undefined,
        .len = 0,
    };
    if (framebuffer_request.response) |info| {
        const framebuffers: []KernelArgs.Framebuffer = @ptrCast(
            [*]KernelArgs.Framebuffer,
            page_allocator.findAndReservePage() catch @panic("out of memory"),
        )[0 .. 4096 / @sizeOf(KernelArgs.Framebuffer)];
        const limine_framebuffers = info.framebuffers[0..info.framebuffer_count];
        const max_framebuffers = std.math.min(
            limine_framebuffers.len,
            framebuffers.len,
        );
        if (max_framebuffers < limine_framebuffers.len) logger.warn(
            "Only allocating {} out of {} framebuffers",
            .{max_framebuffers, limine_framebuffers.len},
        );
        var framebuffer_i: usize = 0;
        for (limine_framebuffers[0..max_framebuffers]) |fb, i| {
            if (fb.bpp != 32) {
                logger.warn("Skipping framebuffer {} because of unknown BPP {}", .{i, fb.bpp});
                continue;
            }
            const scanline: u32 = fb.pitch / (@as(u32, fb.bpp) / 8);
            framebuffers[framebuffer_i] = KernelArgs.Framebuffer{
                .ptr = fb.ptr,
                .ptr_type = .Linear,
                .size = scanline * @as(u32, fb.height) * @as(u32, fb.bpp) / 8,
                .width = fb.width,
                .height = fb.height,
                .scanline = scanline,
                .color_format = .BGRR8,
            };
            logger.debug("Allocated {}", .{framebuffers[framebuffer_i]});
            framebuffer_i += 1;
        }
        framebuffers_arg.ptr = framebuffers.ptr;
        framebuffers_arg.len = framebuffer_i;
    }
    // Write kernel arguments
    const module_response = module_request.response
        orelse @panic("bootloader didn't provide initrd");
    if (module_response.module_count < 1) @panic("bootloader didn't provide initrd");
    const initrd_file = module_response.modules[0];
    const efi_ptr: @TypeOf(kernel_args_ptr.arch.efi_ptr) = blk: {
        break :blk (efi_system_table_request.response orelse break :blk null).efi_ptr;
    };
    const rsdp_ptr: @TypeOf(kernel_args_ptr.arch.acpi_ptr) = blk: {
        break :blk (rsdp_request.response orelse break :blk null).rsdp_ptr;
    };
    // TODO Add in SMBIOS support
    kernel_args_ptr.* = KernelArgs{
        .kernel_elf = .{
            .ptr = kernel_file.address,
            .len = kernel_file.size,
        },
        .page_table_ptr = asm ("movq %%cr3, %[out]" : [out] "=r" (-> *[512]u64)),
        .environment = .{
            .ptr = @as([]u8, "").ptr,
            .len = 0,
        },
        .memory_map = .{
            .ptr = page_allocator.memory_map.ptr,
            .len = page_allocator.memory_map.len,
            .mapped_size = total_mappable_size,
        },
        .initrd = .{
            .ptr = initrd_file.address,
            .len = initrd_file.size,
        },
        .arch = .{
            .efi_ptr = efi_ptr,
            .acpi_ptr = rsdp_ptr,
            .smbi_ptr = null,
            .mp_ptr = null,
        },
        .framebuffers = framebuffers_arg,
    };
    // Remove Limine terminal writers
    logging.abstract_writers.clear();
    // Call kernel init64 entry point
    init64(kernel_args_ptr);
}
