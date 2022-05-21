//! Structures and functions specific to the x86_64 architecture

const std = @import("std");
const uefi = std.os.uefi;
const elf = @import("elf.zig");
const assertEqual = @import("misc.zig").assertEqual;

const logger = std.log.scoped(.x86_64);

const PageTable = [512]PageTableEntry;

pub const PageTableEntry = packed struct {
    __data: u64,

    const Self = @This();

    pub fn isPresent(self: Self) bool {
        return self.__data & 0x0000000000000001 == 1;
    }

    pub fn isWritable(self: Self) bool {
        return self.__data & 0x0000000000000002 == 1;
    }

    pub fn isUserAccessable(self: Self) bool {
        return self.__data & 0x0000000000000004 == 1;
    }

    pub fn writeThroughCachingEnabled(self: Self) bool {
        return self.__data & 0x0000000000000008 == 1;
    }

    pub fn cacheDisabled(self: Self) bool {
        return self.__data & 0x0000000000000010 == 1;
    }

    pub fn isAccessed(self: Self) bool {
        return self.__data & 0x0000000000000020 == 1;
    }

    pub fn isDirty(self: Self) bool {
        return self.__data & 0x0000000000000040 == 1;
    }

    pub fn isHugePage(self: Self) bool {
        return self.__data & 0x0000000000000080 == 1;
    }

    pub fn isGlobal(self: Self) bool {
        return self.__data & 0x0000000000000100 == 1;
    }

    pub fn fromU64(entry: u64) Self {
        return @bitCast(Self, entry);
    }

    pub fn toU64(self: Self) u64 {
        return @bitCast(u64, self);
    }

    const InputFlags = struct {
        present: bool = false,
        writable: bool = false,
        user_accessable: bool = false,
        write_through_caching_enabled: bool = false,
        cache_disabled: bool = false,
        accessed: bool = false,
        dirty: bool = false,
        huge_page: bool = false,
        global: bool = false,
        physical_address: usize = 0,
        no_execute: bool = false,
    };

    pub fn generateU64(flags: InputFlags) u64 {
        return @as(u64, 0) |
            @as(u64, if (flags.present) 0x1 else 0) |
            @as(u64, if (flags.writable) 0x2 else 0) |
            @as(u64, if (flags.user_accessable) 0x4 else 0) |
            @as(u64, if (flags.write_through_caching_enabled) 0x8 else 0) |
            @as(u64, if (flags.cache_disabled) 0x10 else 0) |
            @as(u64, if (flags.accessed) 0x20 else 0) |
            @as(u64, if (flags.dirty) 0x40 else 0) |
            @as(u64, if (flags.huge_page) 0x80 else 0) |
            @as(u64, if (flags.global) 0x100 else 0) |
            @as(u64, if (flags.no_execute) 0x8000000000000000 else 0) |
            @as(u64, (flags.physical_address << 12) & 0x000FFFFFFFFFF000);
    }

    pub fn getAddress(self: Self) u64 {
        const addr = self.__data & 0x000FFFFFFFFFF000;
        if (addr & 0x0008000000000000 != 0) {
            return addr | 0xFFFE000000000000;
        } else {
            return addr;
        }
    }

    pub fn getPtr(self: Self) *allowzero align(4096) PageTable {
        return @intToPtr(*allowzero align(4096) PageTable, self.getAddress());
    }

    pub fn isNoExecute(self: Self) bool {
        return self.__data & 0x8000000000000000 == 1;
    }

    comptime {
        assertEqual(@bitSizeOf(Self), @bitSizeOf(u64));
        assertEqual(@sizeOf(Self), @sizeOf(u64));
    }
};

pub fn isDescFree(descriptor: *const uefi.tables.MemoryDesciptor) bool {
    return switch (descriptor.type) {
        .ConventionalMemory => true,
        .LoaderCode => true,
        .LoaderData => true,
        else => false,
    };
}

pub fn isDescUsable(descriptor: *const uefi.tables.MemoryDesciptor) bool {
    return switch (descriptor.type) {
        .UnusableMemory => false,
        .ReservedMemory => false,
        .MemoryMappedIO => false,
        .MemoryMappedIOPortSpace => false,
        else => true,
    };
}

pub const DescriptorTablePointer = packed struct {
    /// Size of the DT
    limit: u16,
    /// Pointer to the DT
    base: u64,
};

pub const PageMapper = struct {
    page_table: *align(4096) PageTable,

    pub const page_size: usize = 4096;

    const Self = @This();

    pub fn new() Self {
        const boot_services = uefi.system_table.boot_services.?;
        var address: [*]align(4096) u8 = undefined;
        const status = boot_services.allocatePages(.AllocateAnyPages, .LoaderData, 1, &address);
        if (status != .Success) {
            logger.emerg("PML4, page allocator returned {}", .{status});
            @panic("PageMapper.new() panicked at ");
        }
        // Zero out page table
        for (address[0..4096]) |*entry| {
            entry.* = 0;
        }
        return Self{
            .page_table = @ptrCast(*align(4096) PageTable, address),
        };
    }
    
    pub fn translateAddress(self: *const Self, virtual_address: u64) ?u64 {
        const level_masks = [_]u64{
            0xFF80_0000_0000,
            0x007F_C000_0000,
            0x0000_3FE0_0000,
            0x0000_001F_F000,
        };
        var current_address = @ptrToInt(self.page_table);
        for (level_masks) |level_mask, i| {
            const current_table_ptr = @intToPtr(*align(4096) [512]u64, current_address);
            const current_table = @ptrCast(*align(4096) PageTable, current_table_ptr);
            const index = @truncate(
                u9,
                (level_mask & virtual_address) >> @truncate(u6, (3 - i) * 9 + 12),
            );
            var entry = current_table[index];
            if (entry.isPresent()) {
                if (entry.isUserAccessable() or entry.isHugePage()) @panic("page flags wrong");
                current_address = entry.getAddress();
            } else {
                return null;
            }
        }
        return current_address | (virtual_address & 0xFFF);
    }

    /// Allocates contiguous physical pages and maps them from the given virtual address
    /// (aligned down, top 12 bits ignored) to the given size (aligned up).
    /// `flags` are the flags applied to parent pages.
    /// No flags are applied to already existing pages.
    /// Returns a slice of the total allocated physical memory
    pub fn allocateMem(
        self: *Self,
        virtual_address: u64,
        flags: u64,
        size: u64,
        // use_huge_pages: bool,
    ) []allowzero align(4096) u8 {
        const allocatePages = uefi.system_table.boot_services.?.allocatePages;
        const num_pages = if (size & 0xFFF != 0) (size >> 12) + 1 else size >> 12;
        // Allocate contiguous pages from UEFI
        var new_address: [*]align(4096) u8 = undefined;
        const status = allocatePages(.AllocateAnyPages, .LoaderData, num_pages, &new_address);
        if (status != .Success) {
            logger.emerg("allocation of {} pages failed, returned {}", .{num_pages, status});
            @panic("page allocation failed");
        }
        // Map pages into page table
        const new_size = num_pages << 12;
        self.offsetMapMem(@ptrToInt(new_address), virtual_address, flags, new_size);
        return new_address[0..new_size];
    }

    /// Maps physical memory to virtual memory at start offsets. Setting the
    /// physical start equal to the virtual start identity maps memory.
    /// `flags` are the flags applied to child pages.
    pub fn offsetMapMem(
        self: *Self,
        physical_start_address: u64,
        virtual_start_address: u64,
        flags: u64,
        size: u64,
        // use_huge_pages: bool,
    ) void {
        const actual_physical_start_address = physical_start_address & 0x000FFFFFFFFFF000;
        const actual_flags = (flags & 0x80000000000001FE) | 0x1;
        const parent_flags = @as(u64, 0x0000000000000003);
        const level_masks = [_]u64{
            0xFF80_0000_0000,
            0x007F_C000_0000,
            0x0000_3FE0_0000,
            0x0000_001F_F000,
        };
        const num_pages = if (size & 0xFFF != 0) (size >> 12) + 1 else size >> 12;
        var page_i: usize = 0;
        while (page_i < num_pages) : (page_i += 1) {
            const physical_address = actual_physical_start_address + (page_i << 12);
            const virtual_address = virtual_start_address + (page_i << 12);
            const allocatePages = uefi.system_table.boot_services.?.allocatePages;
            var current_address = @ptrToInt(self.page_table);
            for (level_masks) |level_mask, i| {
                const current_table_ptr = @intToPtr(*align(4096) [512]u64, current_address);
                const current_table = @ptrCast(*align(4096) PageTable, current_table_ptr);
                const index = @truncate(
                    u9,
                    (level_mask & virtual_address) >> @truncate(u6, (3 - i) * 9 + 12),
                );
                var entry = current_table[index];
                // Allocate page if required
                if (!entry.isPresent()) {
                    if (i < 3) {
                        // Allocate parent entry
                        var new_address: [*]align(4096) u8 = undefined;
                        const status = allocatePages(
                            .AllocateAnyPages,
                            .LoaderData,
                            1,
                            &new_address,
                        );
                        if (status != .Success) {
                            logger.emerg("page mapping, page allocator returned {}", .{status});
                            @panic("page mapping failed");
                        }
                        // Zero out page
                        for (new_address[0..4096]) |*byte| {
                            byte.* = 0;
                        }
                        // Set entry to new page table
                        const stripped_address = @ptrToInt(new_address) & 0x000FFFFFFFFFF000;
                        const new_entry: u64 = stripped_address | parent_flags;
                        current_table_ptr[index] = new_entry;
                        entry = PageTableEntry.fromU64(new_entry);
                    } else {
                        // Offset map child entry
                        const stripped_address = physical_address & 0x000FFFFFFFFFF000;
                        const new_entry: u64 = stripped_address | actual_flags;
                        current_table_ptr[index] = new_entry;
                    }
                } else {
                    if (i == 3) @panic("entry present");
                }
                current_address = entry.getAddress();
            }
        }
    }
};

const gdt: [8]u64 align(16) = [_]u64{
    // Null desciptors
    0x0000000000000000,
    0x0000000000000000,
    0x0000000000000000,
    0x0000000000000000,
    0x0000000000000000,
    0x0000000000000000,
    // Kernel data segment
    0x00CF93000000FFFF,
    // Kernel code segment
    0x00AF9B000000FFFF,
};

pub inline fn jumpTo(entry_point: usize, kernel_args: *const KernelArgs) noreturn {
    asm volatile (
        \\jmpq *%[entry_point]
        :
        : [entry_point] "r" (entry_point),
          [kernel_args] "{rdi}" (kernel_args)
    );
    @panic("kernel jump failed");
}

// Must be kept in sync with kernel
pub const KernelArgs = extern struct {
    kernel_elf: extern struct {
        ptr: [*]const u8,
        len: usize,
    },
    page_table_ptr: *[512]u64,
    environment: extern struct {
        ptr: [*]const u8,
        len: usize,
    },
    memory_map: extern struct {
        /// Pointer to the start of the memory map
        ptr: [*]u8,
        /// Size of the memory map in bytes
        size: usize,
        /// Size of area represented by map
        mapped_size: usize,
    },
    initrd: extern struct {
        ptr: [*]const u8,
        size: usize,
    },
    arch: extern struct {
        efi_ptr: usize,
        acpi_ptr: usize,
        mp_ptr: usize,
        smbi_ptr: usize,
    },
    framebuffers: extern struct {
        ptr: [*]const Framebuffer,
        len: usize,
    },

    pub const Framebuffer = extern struct {
        ptr: [*]volatile u8,
        size: u32,
        width: u32,
        height: u32,
        scanline: u32,
        color_format: ColorFormat,
        /// Bitmasks for specifying color positions in u32.
        /// All values are undefined if color_info_format != .Bitmask
        color_bitmask: ColorBitmask = undefined,

        pub const ColorFormat = enum(u32) {
            /// Red, Green, Blue, Reserved - 8 bits per color
            RGBR8,
            /// Red, Green, Blue, Reserved - 8 bits per color
            BGRR8,
            Bitmask,
        };

        /// Bitmasks for specifying color positions in u32.
        /// All values are undefined if color_format != .Bitmask
        pub const ColorBitmask = extern struct {
            red_mask: u32,
            green_mask: u32,
            blue_mask: u32,
            reserved_mask: u32,
        };
    };
};
