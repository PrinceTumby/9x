const std = @import("std");
const mem = std.mem;
const uefi = std.os.uefi;
const fmt = std.fmt;
const fmtIntSizeDec = std.fmt.fmtIntSizeDec;
const utf8ToUtf16 = std.unicode.utf8ToUtf16LeStringLiteral;
pub const arch = @import("x86_64.zig");
pub const KernelArgs = arch.KernelArgs;
const cpio = @import("cpio.zig");
const elf = @import("elf.zig");
const logging = @import("logging.zig");
pub const Framebuffer = @import("core_graphics.zig").FrameBuffer;
pub const text_lib = @import("text_lib.zig");

pub const log = logging.log;
pub const log_level: std.log.Level = .debug;
// Screen logging
const font_file = @embedFile("../../../../initrd/template/etc/kernel/standard_font.psf");
var framebuffer: Framebuffer = undefined;
var text_display: text_lib.TextDisplay(Framebuffer) = undefined;

// Embedded kernel ELF file
const kernel: []const u8 = @embedFile("../../../out/kernel");

pub const allocator = @import("allocation.zig").efi_allocator.allocator();
const logger = std.log.scoped(.main);
const config_path: []const u8 = "etc/kernel/config";
const flags_global: usize = arch.PageTableEntry.generateU64(.{
    .present = true,
    .writable = true,
});

/// Allocates contiguous physical pages to the given size (aligned up to page size).
fn allocateMem(size: u64) []allowzero u8 {
    const allocatePages = uefi.system_table.boot_services.?.allocatePages;
    const num_pages = if (size & 0xFFF != 0) (size >> 12) + 1 else size >> 12;
    var new_address: [*]align(4096) u8 = undefined;
    const status = allocatePages(.AllocateAnyPages, .LoaderData, num_pages, &new_address);
    if (status != .Success) {
        logger.err("allocation of {} pages failed, returned {}", .{num_pages, status});
        @panic("page allocation failed");
    }
    const new_size = num_pages << 12;
    return new_address[0..new_size];
}

pub const InitrdError = error {
    DriveMountError,
    FileOpenError,
    FileReadError,
    AllocationError,
};

fn loadInitrd(image_handle: uefi.Handle) InitrdError![]align(8) u8 {
    const boot_services = uefi.system_table.boot_services.?;
    // Get loaded image protocol
    var loaded_image: *uefi.protocols.LoadedImageProtocol = undefined;
    if (boot_services.handleProtocol(
            image_handle, &uefi.protocols.LoadedImageProtocol.guid,
            @ptrCast(*?*anyopaque, &loaded_image),
        ) != .Success
    ) {
        return error.DriveMountError;
    }
    // Get boot volume file system
    var drive_protocol: *uefi.protocols.SimpleFileSystemProtocol = undefined;
    if (boot_services.handleProtocol(
            loaded_image.device_handle.?,
            &uefi.protocols.SimpleFileSystemProtocol.guid,
            @ptrCast(*?*anyopaque, &drive_protocol)) != .Success
    ) {
        return error.DriveMountError;
    }
    // Open volume
    var file_system_protocol: *const uefi.protocols.FileProtocol = undefined;
    if (drive_protocol.openVolume(&file_system_protocol) != .Success) {
        return error.DriveMountError;
    }
    // Open initrd
    var initrd_file: *const uefi.protocols.FileProtocol = undefined;
    if (file_system_protocol.open(
            &initrd_file,
            utf8ToUtf16("\\boot\\initrd.cpio"),
            0x1,
            0x0,
        ) != .Success
    ) {
        return error.FileOpenError;
    }
    defer _ = initrd_file.close();

    // Get size
    // Hardcoding the buffer size should be fine here, as the file name length is known
    var info_buffer: [128]u8 align(8) = undefined;
    var info_size: usize = info_buffer.len;
    var file_info_guid align(8) = uefi.protocols.FileInfo.guid;
    if (initrd_file.getInfo(&file_info_guid, &info_size, &info_buffer) != .Success) {
        return error.FileReadError;
    }
    const info = @ptrCast(*const uefi.protocols.FileInfo, &info_buffer);
    const initrd_size = info.file_size;
    // 4GB check for 32 bit machines
    if (initrd_size > 0xFFFFFFFF) @panic("initrd over 4GB unsupported");

    // Read initrd
    var buffer: [*]align(8) u8 = undefined;
    if (boot_services.allocatePool(.LoaderData, initrd_size, &buffer) != .Success) {
        return error.AllocationError;
    }
    errdefer _ = boot_services.freePool(buffer);
    var buffer_used_len = initrd_size;
    if (initrd_file.read(&buffer_used_len, buffer) != .Success) {
        return error.FileReadError;
    }
    return buffer[0..buffer_used_len];
}

pub fn main() void {
    const con_out = uefi.system_table.con_out.?;
    _ = con_out.reset(false);
    logging.setLogDevice(con_out);
    const boot_services = uefi.system_table.boot_services.?;
    const image_handle = uefi.handle;

    // Load initrd from boot volume
    const initrd = loadInitrd(image_handle) catch |err| switch (err) {
        error.DriveMountError => @panic("drive mounting failed"),
        error.FileOpenError => @panic("opening initrd failed"),
        error.FileReadError => @panic("reading initrd failed"),
        error.AllocationError => @panic("allocation failed"),
    };
    logger.info("loaded initrd at {*}, {}", .{initrd.ptr, fmtIntSizeDec(initrd.len)});

    // Get graphics framebuffer, if available
    var fb_ptr: ?[*]volatile u8 = null;
    var fb_size: u32 = undefined;
    var fb_width: u32 = undefined;
    var fb_height: u32 = undefined;
    var fb_scanline_length: u32 = undefined;
    var fb_color_format: KernelArgs.Framebuffer.ColorFormat = undefined;
    var fb_color_bitmask: KernelArgs.Framebuffer.ColorBitmask = undefined;
    blk: {
        var graphics: *uefi.protocols.GraphicsOutputProtocol = undefined;
        if (.Success == boot_services.locateProtocol(
                &uefi.protocols.GraphicsOutputProtocol.guid,
                null,
                @ptrCast(*?*anyopaque, &graphics),
        )) {
            if (graphics.setMode(graphics.mode.mode) != .Success) {
                break :blk;
            }
            const mode = graphics.mode;
            const info = mode.info;
            switch (info.pixel_format) {
                .PixelRedGreenBlueReserved8BitPerColor => fb_color_format = .RGBR8,
                .PixelBlueGreenRedReserved8BitPerColor => fb_color_format = .BGRR8,
                .PixelBitMask => {
                    fb_color_format = .Bitmask;
                    const bitmask = info.pixel_information;
                    fb_color_bitmask = .{
                        .red_mask = bitmask.red_mask,
                        .green_mask = bitmask.green_mask,
                        .blue_mask = bitmask.blue_mask,
                        .reserved_mask = bitmask.reserved_mask,
                    };
                },
                else => break :blk,
            }
            fb_ptr = @intToPtr([*]volatile u8, mode.frame_buffer_base);
            fb_size = @truncate(u32, mode.frame_buffer_size);
            fb_width = info.horizontal_resolution;
            fb_height = info.vertical_resolution;
            fb_scanline_length = info.pixels_per_scan_line;
            framebuffer = Framebuffer.init(.{
                .ptr = fb_ptr,
                .size = fb_size,
                .width = fb_width,
                .height = fb_height,
                .scanline = fb_scanline_length,
                .color_format = fb_color_format,
                .color_bitmask = fb_color_bitmask,
            });
            const font = text_lib.Font.init(font_file) orelse break :blk;
            text_display = text_lib.TextDisplay(Framebuffer).init(&framebuffer, font);
            logging.setScreenLogger(&text_display);
        }
    }

    // Allocate page tables covering all of physical memory, return size
    var mapper: arch.PageMapper = undefined;
    var total_mappable_size: usize = blk: {
        // Get memory map
        const standard_flags = comptime arch.PageTableEntry.generateU64(.{
            .present = true,
            .writable = true,
        });
        const mmio_flags = comptime arch.PageTableEntry.generateU64(.{
            .present = true,
            .writable = true,
            .cache_disabled = true,
        });
        const framebuffer_flags = comptime arch.PageTableEntry.generateU64(.{
            .present = true,
            .writable = true,
            .write_through_caching_enabled = true,
        });
        var memory_map_allocated = false;
        var memory_map: [*]uefi.tables.MemoryDescriptor = undefined;
        var memory_map_size: usize = 0;
        var memory_map_key: usize = undefined;
        var descriptor_size: usize = undefined;
        var descriptor_version: u32 = undefined;
        while (.BufferTooSmall == boot_services.getMemoryMap(
            &memory_map_size,
            memory_map,
            &memory_map_key,
            &descriptor_size,
            &descriptor_version,
        )) {
            if (memory_map_allocated) {
                _ = boot_services.freePool(@ptrCast([*]align(8) u8, memory_map));
            }
            if (.Success != boot_services.allocatePool(
                .LoaderData,
                memory_map_size,
                @ptrCast(*[*]align(8) u8, &memory_map),
            )) {
                @panic("memory map allocation failed");
            }
            memory_map_allocated = true;
        }
        defer _ = boot_services.freePool(@ptrCast([*]align(8) u8, memory_map));
        const memory_map_slice =
            memory_map[0 .. memory_map_size / @sizeOf(uefi.tables.MemoryDescriptor)];
        var return_size: usize = 0;
        // Map pages, set correct properties for MMIO areas
        mapper = arch.PageMapper.new();
        for (memory_map_slice) |*desc| {
            const flags = switch (desc.type) {
                .MemoryMappedIO, .MemoryMappedIOPortSpace => mmio_flags,
                else => standard_flags,
            };
            const end_address = desc.physical_start +% (desc.number_of_pages * 4096) -% 1;
            if (end_address > return_size) return_size = end_address;
            mapper.offsetMapMem(
                desc.physical_start,
                desc.physical_start,
                flags,
                desc.number_of_pages * 4096,
            );
        }
        // Map graphics framebuffer
        if (fb_ptr) |fb| {
            mapper.offsetMapMem(
                @ptrToInt(fb),
                @ptrToInt(fb),
                framebuffer_flags,
                fb_size,
            );
        }
        break :blk return_size;
    };
    logger.info("total physical memory area: {}", .{fmtIntSizeDec(total_mappable_size)});

    // Allocate environment, add arguments from initrd
    var environment_map = std.BufMap.init(allocator);
    if (cpio.cpioFindFile(initrd, config_path)) |config_file| {
        // Parse kernel config file
        // Workaround for Zig switching not working against optionals
        const Maybe2Chars = union(enum) {
            none: void,
            some: [2]u8,

            const Self = @This();

            pub fn eql(self: Self, a: u8, b: u8) bool {
                switch (self) {
                    .none => return false,
                    .some => |chars| return chars[0] == a and chars[1] == b,
                }
            }
        };
        const sliceGet = struct {
            /// Gets an element from a slice, or null if out of range.
            pub fn function(slice: []const u8, index: usize) Maybe2Chars {
                if (index + 1 < slice.len)
                    return .{.some = [2]u8{slice[index], slice[index + 1]}}
                else
                    return .{.none = undefined};
            }
        }.function;
        const State = enum {
            LineStart,
            SingleLineComment,
            MultilineComment,
            BeforeEquals,
            AfterEquals,
        };
        var current_state: State = .LineStart;
        var selection_start: usize = 0;
        var before_equals_slice: []const u8 = undefined;
        var pos: usize = 0;
        while (pos < config_file.len) {
            const chars = sliceGet(config_file, pos);
            const char = config_file[pos];
            switch (current_state) {
                .LineStart => if (chars.eql('/', '/')) {
                    pos += 2;
                    current_state = .SingleLineComment;
                } else if (chars.eql('/', '*')) {
                    pos += 2;
                    current_state = .MultilineComment;
                } else {
                    switch (char) {
                        '\n' => {
                            pos += 1;
                            current_state = .LineStart;
                        },
                        else => {
                            selection_start = pos;
                            pos += 1;
                            current_state = .BeforeEquals;
                        },
                    }
                },
                .SingleLineComment => switch (char) {
                    '\n' => {
                        pos += 1;
                        current_state = .LineStart;
                    },
                    else => pos += 1,
                },
                .MultilineComment => if (chars.eql('*', '/')) {
                    pos += 2;
                    current_state = .LineStart;
                } else {
                    pos += 1;
                },
                .BeforeEquals => switch (char) {
                    '=' => {
                        before_equals_slice = config_file[selection_start .. pos];
                        pos += 1;
                        selection_start = pos;
                        current_state = .AfterEquals;
                    },
                    '\n' => {
                        pos += 1;
                        current_state = .LineStart;
                    },
                    else => pos += 1,
                },
                .AfterEquals => switch (char) {
                    '\n' => {
                        const after_equals_slice = config_file[selection_start .. pos];
                        environment_map.put(before_equals_slice, after_equals_slice) catch {
                            @panic("environment map setting failed");
                        };
                        pos += 1;
                        current_state = .LineStart;
                    },
                    else => pos += 1,
                },
            }
        }
        switch (current_state) {
            .AfterEquals => {
                const after_equals_slice = config_file[selection_start .. pos];
                environment_map.put(before_equals_slice, after_equals_slice) catch {
                    @panic("environment map setting failed");
                };
            },
            .LineStart, .SingleLineComment => {},
            else => logger.warn("malformed config file", .{}),
        }
    } else {
        logger.warn("config file not found, ignoring", .{});
    }
    // Add command line arguments to environment map
    uefi_command_line: {
        // Get load options string from loaded image
        var loaded_image: *uefi.protocols.LoadedImageProtocol = undefined;
        if (boot_services.handleProtocol(
                image_handle, &uefi.protocols.LoadedImageProtocol.guid,
                @ptrCast(*?*anyopaque, &loaded_image),
        ) != .Success
        ) {
            break :uefi_command_line;
        }
        const load_options_ptr = loaded_image.load_options orelse break :uefi_command_line;
        const load_options = @ptrCast([*]u8, load_options_ptr)[0..loaded_image.load_options_size];
        // Parse load options string
        const State = enum {
            SkipPath,
            NewArg,
            BeforeEquals,
            AfterEquals,
        };
        var current_state: State = .SkipPath;
        var selection_start: usize = 0;
        var before_equals_slice: []const u8 = undefined;
        logger.debug("Command line options: {s}", .{load_options});
        for (load_options) |char, pos| {
            switch (current_state) {
                .SkipPath => if (char == ' ') {current_state = .NewArg;},
                .NewArg => switch (char) {
                    ' ' => {},
                    else => {
                        selection_start = pos;
                        current_state = .BeforeEquals;
                    },
                },
                .BeforeEquals => switch (char) {
                    ' ' => current_state = .NewArg,
                    '=' => {
                        before_equals_slice = load_options[selection_start .. pos];
                        selection_start = pos + 1;
                        current_state = .AfterEquals;
                    },
                    else => {},
                },
                .AfterEquals => switch (char) {
                    ' ' => {
                        const after_equals_slice = load_options[selection_start .. pos];
                        environment_map.put(before_equals_slice, after_equals_slice) catch {
                            @panic("environment map setting failed");
                        };
                        current_state = .NewArg;
                    },
                    else => {},
                },
            }
        }
        switch (current_state) {
            .AfterEquals => {
                const after_equals_slice = load_options[selection_start..];
                environment_map.put(before_equals_slice, after_equals_slice) catch {
                    @panic("environment map setting failed");
                };
            },
            .BeforeEquals => logger.warn("malformed last command line option, ignoring", .{}),
            else => {},
        }
    }
    // Create environment string from environment map
    const environment = env_blk: {
        // Get size required to store environment string
        const environment_len: usize = len_blk: {
            var iterator = environment_map.iterator();
            var current_size: usize = 0;
            while (iterator.next()) |entry| {
                // Add on key and value lengths, along with overhead for '=' and '\n'
                current_size += entry.key_ptr.len + entry.value_ptr.len + 2;
            }
            break :len_blk current_size;
        };
        // Allocate environment string
        var buffer: [*]align(8) u8 = undefined;
        if (boot_services.allocatePool(.LoaderData, environment_len, &buffer) != .Success) {
            @panic("environment string allocation failed");
        }
        // Fill environment string with options
        var iterator = environment_map.iterator();
        var pos: usize = 0;
        while (iterator.next()) |entry| {
            @memcpy(buffer + pos, entry.key_ptr.ptr, entry.key_ptr.len);
            pos += entry.key_ptr.len;
            buffer[pos] = '=';
            pos += 1;
            @memcpy(buffer + pos, entry.value_ptr.ptr, entry.value_ptr.len);
            pos += entry.value_ptr.len;
            buffer[pos] = '\n';
            pos += 1;
        }
        break :env_blk buffer[0..environment_len];
    };
    
    // Clean up environment map
    environment_map.deinit();

    // Load kernel from initrd
    logger.info("loading kernel...", .{});
    const elf_header = elf.Elf64.parseFile(kernel) orelse @panic("couldn't parse kernel elf");
    const program_header = elf_header.getProgramHeader(kernel);
    // Copy each section into memory
    var entry_addr: usize = undefined;
    for (program_header) |*entry| {
        if (entry.type != .Loadable) continue;
        const mem_slice = allocateMem(entry.segment_memory_size);
        const segment_slice = @ptrCast(
            [*]const allowzero u8,
            &kernel[entry.segment_offset],
        )[0..entry.segment_image_size];
        // Copy segment into memory
        {
            var i: usize = 0;
            while (i < segment_slice.len) : (i += 1) {
                mem_slice[i] = segment_slice[i];
            }
        }
        // Clear memory
        if (mem_slice.len > segment_slice.len) {
            for (mem_slice[segment_slice.len ..]) |*byte| {
                byte.* = 0;
            }
        }
        // Map segment in page table
        mapper.offsetMapMem(
            @ptrToInt(mem_slice.ptr),
            entry.segment_virt_addr,
            flags_global,
            entry.segment_memory_size,
        );
        // Attempt to locate entry point
        const virt_entry_addr = elf_header.prog_entry_pos;
        if (virt_entry_addr >= entry.segment_virt_addr and
            virt_entry_addr < entry.segment_virt_addr + entry.segment_memory_size) {
            entry_addr =
                @ptrToInt(segment_slice.ptr) + (virt_entry_addr - entry.segment_virt_addr);
        }
    }
    logger.info("loaded kernel", .{});

    // Allocate kernel arguments area
    const kernel_args_phys_ptr = allocateMem(@sizeOf(KernelArgs)).ptr;
    
    // Read architecture pointers from configuration table
    const efi_ptr: usize = @ptrToInt(uefi.system_table);
    var acpi_ptr: usize = 0;
    var smbi_ptr: usize = 0;
    {
        const guidEqual = struct {
            fn function(first: uefi.Guid, second: uefi.Guid) bool {
                return first.time_low == second.time_low and
                    first.time_mid == second.time_mid and
                    first.time_high_and_version == second.time_high_and_version and
                    first.clock_seq_high_and_reserved == second.clock_seq_high_and_reserved and
                    first.clock_seq_low == second.clock_seq_low and
                    std.mem.eql(u8, &first.node, &second.node);
            }
        }.function;
        const Guids = uefi.tables.ConfigurationTable;
        const sys_table = uefi.system_table;
        const config_table = sys_table.configuration_table[0..sys_table.number_of_table_entries];
        for (config_table) |*entry| {
            if (guidEqual(entry.vendor_guid, Guids.acpi_10_table_guid)) {
                acpi_ptr = @ptrToInt(entry.vendor_table);
            } else if (guidEqual(entry.vendor_guid, Guids.acpi_10_table_guid)) {
                acpi_ptr = @ptrToInt(entry.vendor_table);
            } else if (guidEqual(entry.vendor_guid, Guids.acpi_20_table_guid)) {
                acpi_ptr = @ptrToInt(entry.vendor_table);
            } else if (guidEqual(entry.vendor_guid, Guids.smbios_table_guid)) {
                smbi_ptr = @ptrToInt(entry.vendor_table);
            } else if (guidEqual(entry.vendor_guid, Guids.smbios3_table_guid)) {
                smbi_ptr = @ptrToInt(entry.vendor_table);
            }
        }
    }
    logger.info(
        "architecture pointers:\n EFI: {x},\nACPI: {x},\nSMBI: {x}",
        .{efi_ptr, acpi_ptr, smbi_ptr},
    );

    // Generate kernel memory map
    var memory_map_size: usize = undefined;
    var memory_map_ptr: [*]u8 = undefined;
    {
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
        const bit_ratio = @TypeOf(mapper).page_size;
        // Number of mapped bytes per byte
        const byte_ratio = bit_ratio * 8;
        memory_map_size = total_mappable_size / byte_ratio;
        // Allocate memory
        const memory_map_slice = allocateMem(memory_map_size);
        memory_map_ptr = @ptrCast([*]u8, memory_map_slice.ptr);
        // Set memory to all used
        for (memory_map_slice) |*byte| {
            byte.* = 0xFF;
        }
        // Get memory map
        var uefi_map_ptr: [*]uefi.tables.MemoryDescriptor = undefined;
        var uefi_map_size: usize = 0;
        var uefi_map_key: usize = undefined;
        var descriptor_size: usize = undefined;
        var descriptor_version: u32 = undefined;
        var uefi_map_allocated = false;
        while (.BufferTooSmall == boot_services.getMemoryMap(
            &uefi_map_size,
            uefi_map_ptr,
            &uefi_map_key,
            &descriptor_size,
            &descriptor_version,
        )) {
            if (uefi_map_allocated) {
                _ = boot_services.freePool(@ptrCast([*]align(8) u8, uefi_map_ptr));
            }
            if (.Success != boot_services.allocatePool(
                .LoaderData,
                uefi_map_size,
                @ptrCast(*[*]align(8) u8, &uefi_map_ptr),
            )) {
                @panic("memory map allocation failed");
            }
            uefi_map_allocated = true;
        }
        defer _ = boot_services.freePool(@ptrCast([*]align(8) u8, uefi_map_ptr));
        const uefi_map = uefi_map_ptr[0 .. uefi_map_size / @sizeOf(uefi.tables.MemoryDescriptor)];
        // Clear free entries
        for (uefi_map) |*desc| {
            const desc_size = desc.number_of_pages * 4096;
            if (desc.type == .ConventionalMemory) {
                const start_bit_index = desc.physical_start / bit_ratio;
                const end_bit_index = start_bit_index + 
                    if (desc_size / bit_ratio > 0)
                        (desc_size / bit_ratio - 1)
                    else
                        0;
                const start_index = start_bit_index / 8;
                const end_index = end_bit_index / 8;
                const start_bit_pos = @truncate(u3, start_bit_index);
                const end_bit_pos = @truncate(u3, end_bit_index);
                if (start_index == end_index) {
                    memory_map_slice[start_index] &=
                        ~start_masks[start_bit_pos] | ~end_masks[end_bit_pos];
                } else {
                    memory_map_slice[start_index] &= ~start_masks[start_bit_pos];
                    var cur_index: usize = start_index + 1;
                    while (cur_index < end_index) : (cur_index += 1) {
                        memory_map_slice[cur_index] = 0;
                    }
                    memory_map_slice[end_index] &= ~end_masks[end_bit_pos];
                }
            }
        }
    }
    logger.info("kernel memory map initialised", .{});
    
    // Initialise kernel arguments
    const kernel_args_ptr = @ptrCast(
        *KernelArgs,
        @alignCast(@alignOf(KernelArgs), kernel_args_phys_ptr),
    );
    kernel_args_ptr.* = KernelArgs{
        .kernel_elf = .{
            .ptr = kernel.ptr,
            .len = kernel.len,
        },
        .page_table_ptr = @ptrCast(*[512]u64, mapper.page_table),
        .environment = .{
            .ptr = environment.ptr,
            .len = environment.len,
        },
        .memory_map = .{
            .ptr = memory_map_ptr,
            .size = memory_map_size,
            .mapped_size = total_mappable_size,
        },
        .initrd = .{
            .ptr = initrd.ptr,
            .size = initrd.len,
        },
        .arch = .{
            .acpi_ptr = acpi_ptr,
            .smbi_ptr = smbi_ptr,
            .efi_ptr = efi_ptr,
            .mp_ptr = 0,
        },
        .fb = .{
            .ptr = fb_ptr,
            .size = fb_size,
            .width = fb_width,
            .height = fb_height,
            .scanline = fb_scanline_length,
            .color_format = fb_color_format,
            .color_bitmask = fb_color_bitmask,
        },
    };
    logger.info("kernel arguments initialised", .{});

    // Get memory map again, exit boot services
    {
        logger.debug("PML4: {x}", .{@ptrToInt(mapper.page_table)});
        logger.info("exiting boot services...", .{});
        var uefi_map_ptr: [*]uefi.tables.MemoryDescriptor = undefined;
        var uefi_map_size: usize = 0;
        var uefi_map_key: usize = 0;
        var descriptor_size: usize = undefined;
        var descriptor_version: u32 = undefined;
        while (.BufferTooSmall == boot_services.getMemoryMap(
            &uefi_map_size,
            uefi_map_ptr,
            &uefi_map_key,
            &descriptor_size,
            &descriptor_version,
        )) {
            if (.Success != boot_services.allocatePool(
                .LoaderData,
                uefi_map_size,
                @ptrCast(*[*]align(8) u8, &uefi_map_ptr),
            )) {
                @panic("memory map allocation failed");
            }
        }
        if (boot_services.exitBootServices(image_handle, uefi_map_key) != .Success) {
            @panic("exit boot services failed");
        }
        // Invalidate UEFI boot structures
        logging.removeLogDevice();
    }

    arch.jumpTo(entry_addr, kernel_args_ptr);
}

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace) noreturn {
    logger.err("LOADER PANIC: {s}", .{message});
    while (true) {
        asm volatile ("hlt");
    }
}
