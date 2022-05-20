const std = @import("std");
const root = @import("root");
const limine = @import("limine.zig");
const AbstractWriter = root.logging.AbstractWriter;
const logging = root.logging;
const KernelArgs = root.arch.common.KernelArgs;
const Terminal = limine.LimineTerminal;

const logger = std.log.scoped(.limine_stub);

export var entry_point_request_ptr = &entry_point_request;
export var entry_point_request align(8) = limine.requests.EntryPoint{
    .entry = limine_entry,
};

export var terminal_request_ptr = &terminal_request;
export var terminal_request align(8) = limine.requests.Terminal{
    .callback = terminal_callback,
};

export var framebuffer_request_ptr = &framebuffer_request;
export var framebuffer_request align(8) = limine.requests.Framebuffer{};

export var kernel_file_request_ptr = &kernel_file_request;
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
    terminal: *limine.LimineTerminal,
    event_type: u64,
    param1: u64,
    param2: u64,
    param3: u64,
) callconv(.C) void {
    _ = terminal;
    _ = event_type;
    _ = param1;
    _ = param2;
    _ = param3;
}

pub const terminal_writer = struct {
    var write_buffer: [256]u8 = undefined;
    var terminalWriteFunc: fn (*anyopaque, [*]const u8, u64) callconv(.C) void = undefined;

    pub const Error = AbstractWriter.Error;

    pub inline fn writeAll(terminal: *anyopaque, bytes: []const u8) Error!void {
        terminalWriteFunc(terminal, bytes.ptr, bytes.len);
    }

    pub fn writeByte(terminal: *anyopaque, byte: u8) Error!void {
        const char = [1]u8{byte};
        terminalWriteFunc(terminal, &char, 1);
    }

    pub fn writeByteNTimes(terminal: *anyopaque, byte: u8, n: usize) Error!void {
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
            .writer_pointer = @ptrCast(*anyopaque, terminal),
            .writeAllFunc = writeAll,
            .writeByteFunc = writeByte,
            .writeByteNTimesFunc = writeByteNTimes,
        };
    }
};

const PageAllocator = struct {
    memory_map: []const *const limine.MemoryMapEntry,
    current_space_index: usize,
    current_space: []align(4096) allowzero [4096]u8,
    current_page_index: usize = 0,

    pub fn new(memory_map: []const *const limine.MemoryMapEntry) PageAllocator {
        var current_space_index: usize = 0;
        var current_space: []align(4096) allowzero [4096]u8 = undefined;
        for (memory_map) |entry, i| {
            if (entry.type == .Usable) {
                current_space = @intToPtr(
                    [*]align(4096) allowzero [4096]u8,
                    entry.base,
                )[0 .. entry.length / 4096];
                current_space_index = i;
                break;
            }
        } else @panic("no usable pages for alloctor");
        return PageAllocator{
            .memory_map = memory_map,
            .current_space_index = current_space_index,
            .current_space = current_space,
        };
    }

    fn nextSpace(self: *PageAllocator) void {
        for (self.memory_map[self.current_space_index..]) |entry, i| {
            if (entry.type == .Usable) {
                self.current_space = @intToPtr(
                    [*]align(4096) allowzero [4096]u8,
                    entry.base,
                )[0 .. entry.length / 4096];
                self.current_space_index += i;
                break;
            }
        } else @panic("out of memory");
    }

    fn nextPage(self: *PageAllocator) void {
        self.current_page_index += 1;
        if (self.current_page_index >= self.current_space.len) {
            self.nextSpace();
            self.current_page_index = 0;
        }
    }

    pub fn getNextPage(self: *PageAllocator) *align(4096) allowzero [4096]u8 {
        @setRuntimeSafety(false);
        if (self.current_space_index >= self.memory_map.len) {
            @panic("out of memory");
        }
        defer self.nextPage();
        return @alignCast(4096, &self.current_space[self.current_page_index]);
    }
};

pub fn breakpointLine(src: std.builtin.SourceLocation) void {
    logger.debug("Reached line {}", .{src.line});
    // asm volatile ("xchgw %%bx, %%bx");
}

fn limine_entry() callconv(.C) void {
    asm volatile ("xchgw %%bx, %%bx");
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
    root.debugging.disable_trace_logging = true;
    // // Add logging devices for Limine terminals
    // if (terminal_request.response) |terminal_info| terminal: {
    //     terminal_writer.terminalWriteFunc = @ptrCast(
    //         @TypeOf(terminal_writer.terminalWriteFunc),
    //         terminal_info.write,
    //     );
    //     var i: usize = 0;
    //     while (i < terminal_info.terminal_count) : (i += 1) {
    //         const new_writer = terminal_writer.createAbstractWriter(terminal_info.terminals[i]);
    //         logging.abstract_writers.append(new_writer) catch break :terminal;
    //     }
    //     if (terminal_info.terminal_count == 1) {
    //         logger.debug("Initialised 1 terminal", .{});
    //     } else {
    //         logger.debug("Initialised {} terminals", .{terminal_info.terminal_count});
    //     }
    // }
    // Create page allocator
    var page_allocator = blk: {
        const response = memory_map_request.response
            orelse @panic("no memory map from bootloader");
        break :blk PageAllocator.new(response.entries[0..response.entry_count]);
    };
    // Allocate kernel arguments
    const kernel_args_ptr = @ptrCast(*KernelArgs, page_allocator.getNextPage());
    // Allocate framebuffers
    var framebuffers_arg = @TypeOf(kernel_args_ptr.framebuffers){
        .ptr = undefined,
        .len = 0,
    };
    if (framebuffer_request.response) |info| {
        const framebuffers: []KernelArgs.Framebuffer = @ptrCast(
            [*]KernelArgs.Framebuffer,
            page_allocator.getNextPage(),
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
            framebuffers[framebuffer_i] = KernelArgs.Framebuffer{
                .ptr = fb.ptr,
                .size = @as(u32, fb.pitch) * @as(u32, fb.height) * @as(u32, fb.bpp) / 8,
                .width = fb.width,
                .height = fb.height,
                .scanline = fb.pitch,
                .color_format = .RGBR8,
            };
            framebuffer_i += 1;
        }
        framebuffers_arg.ptr = framebuffers.ptr;
        framebuffers_arg.len = framebuffer_i;
    }
    // Print out memory map entries
    if (memory_map_request.response) |memory_map| {
        var i: usize = 0;
        while (i < memory_map.entry_count) : (i += 1) {
            const entry = memory_map.entries[i];
            logger.debug("Entry {}: {{base: {x}, length: {x}, type: {}}}", .{
                i,
                entry.base,
                entry.length,
                entry.type,
            });
        }
    }
    {
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            logger.debug("Page {}: {*}", .{i, page_allocator.getNextPage()});
        }
    }
    // logger.debug(
    //     \\Framebuffer 0: {}
    //     \\Kernel file: {}
    //     \\Module 0: {}
    //     \\RSDP: {}
    //     \\SMBIOS: {}
    //     \\EFI: {}
    //     , .{
    //         framebuffer_request.response.?.framebuffers[0],
    //         kernel_file_request.response,
    //         module_request.response.?.modules[0],
    //         rsdp_request.response,
    //         smbios_request.response,
    //         efi_system_table_request.response,
    //     }
    // );
    while (true) {
        asm volatile ("xchgw %%bx, %%bx");
        asm volatile ("hlt");
    }
}
