//! ELF structures that perform significant amounts of checking,
//! used for userspace ELF files to be loaded as programs.

const std = @import("std");
const root = @import("root");
const arch = root.arch;

const logger = std.log.scoped(.elf);

pub const ElfInitError = error {
    InvalidMagic,
    FileTooSmall,
    WrongCpuArchitecture,
    InvalidEntryPointAddress,
    TableBreaksBounds,
    IncorrectTableAlignment,
    SegmentBreaksBounds,
    SegmentMisaligned,
    SegmentAddressInvalid,
    SegmentLimitInvalid,
    SegmentAlignmentInvalid,
    Overflow,
    Bit32Unimplemented,
    WrongElfVersion,
    WrongOsAbi,
    OutOfMemory,
};

pub const Elf = union(enum) {
    Bit64: Elf64,

    pub const BitWidth = enum(u8) {
        Bit32 = 1,
        Bit64 = 2,
    };

    pub const magic_const: [4]u8 = [_]u8{ 0x7F, 'E', 'L', 'F' };

    pub const Elf64 = struct {
        file: []const u8,
        header: *const Header,
        program_header: []const ProgramHeaderEntry,

        pub const Header = packed struct {
            magic: [4]u8,
            bit_width: BitWidth,
            endianness: Endianness,
            elf_header_version: u8,
            os_abi: OsAbi,
            reserved: [8]u8,
            type: ElfType,
            instruction_set: InstructionSet,
            elf_version: u32,
            prog_entry_pos: u64,
            prog_header_table_pos: u64,
            section_header_table_pos: u64,
            flags: u32,
            header_size: u16,
            prog_header_entry_size: u16,
            prog_header_table_num: u16,
            section_header_entry_size: u16,
            section_header_table_num: u16,
            section_header_names_index: u16,

            pub const Endianness = enum(u8) {
                Little = 1,
                Big = 2,
                _,
            };

            pub const OsAbi = enum(u8) {
                SystemV = 0,
                HP_UX = 1,
                NetBsd = 2,
                Linux = 3,
                GnuHurd = 4,
                Solaris = 6,
                Aix = 7,
                Irix = 8,
                FreeBsd = 9,
                _,
            };

            pub const ElfType = enum(u16) {
                None = 0,
                Relocatable = 1,
                Executable = 2,
                Dynamic = 3,
                Core = 4,
                _,
            };

            pub const InstructionSet = enum(u16) {
                NonSpecific = 0x0,
                sparc = 0x2,
                x86 = 0x3,
                mips = 0x8,
                ppc = 0x14,
                ppc64 = 0x15,
                arm = 0x28,
                super_h = 0x2A,
                ia_64 = 0x32,
                x86_64 = 0x3E,
                aarch64 = 0xB7,
                riscv = 0xF3,
                _,
            };
        };

        pub const ProgramHeaderEntry = packed struct {
            type: Type,
            flags: u32,
            segment_offset: u64,
            segment_virt_addr: u64,
            __reserved: u64,
            segment_image_size: u64,
            segment_memory_size: u64,
            alignment: u64,

            pub const Type = enum(u32) {
                Null = 0,
                Loadable = 1,
                DynamicLinkingInfo = 2,
                InterpreterInfo = 3,
                AuxiliaryInfo = 4,
                ProgHeaderTable = 6,
                ThreadLocalStorageTemplate = 7,
                GnuStack = 0x6474E551,
                _,
            };

            pub const flag_values = struct {
                pub const executable: u32 = 0b1;
                pub const writable: u32 = 0b10;
                pub const readable: u32 = 0b100;
            };
        };

        inline fn getUpperBound(slice: anytype) error{Overflow}!usize {
            return try std.math.add(usize, @ptrToInt(slice.ptr), slice.len - 1);
        }

        inline fn isAlignedLike(
            address: usize,
            comptime target_type: type,
        ) error{Overflow}!bool {
            @setRuntimeSafety(false);
            if (@alignOf(target_type) == 0) return error.Overflow;
            return address % @alignOf(target_type) == 0;
        }

        pub fn init(
            file: []align(@alignOf(Header)) const u8,
            header: *const Header,
        ) ElfInitError!Elf64 {
            const file_end = @ptrToInt(&file[file.len - 1]);
            // Some CPUs have a bug which can cause a security vulnerability with sysret if a
            // entry address is not canonical. So we check entrypoint address is lower half. More
            // info at https://lists.xen.org/archives/html/xen-announce/2012-06/msg00001.html
            if (!arch.common.process.isUserAddressValid(header.prog_entry_pos))
                return error.InvalidEntryPointAddress;
            // Get and validate program header
            if (header.prog_header_table_pos >= file.len) return error.TableBreaksBounds;
            if (!(isAlignedLike(header.prog_header_table_pos, ProgramHeaderEntry) catch false)) {
                return error.IncorrectTableAlignment;
            }
            const program_header = @intToPtr(
                [*]const ProgramHeaderEntry,
                try std.math.add(usize, @ptrToInt(file.ptr), header.prog_header_table_pos),
            )[0..header.prog_header_table_num];
            if ((try getUpperBound(program_header)) > file_end) return error.TableBreaksBounds;
            // Validate program header entries
            for (program_header) |*entry| {
                if (entry.type != .Loadable) continue;
                if (entry.segment_offset >= file.len) return error.SegmentBreaksBounds;
                if ((try std.math.add(
                    usize,
                    entry.segment_offset,
                    entry.segment_image_size,
                )) > file.len) return error.SegmentBreaksBounds;
                if (entry.alignment == 0) return error.SegmentAlignmentInvalid;
                if ((entry.segment_virt_addr -% entry.segment_offset) % entry.alignment != 0)
                    return error.SegmentMisaligned;
                if (!arch.common.process.isUserAddressValid(entry.segment_virt_addr))
                    return error.SegmentAddressInvalid;
                const upper_bound = try std.math.add(
                    usize,
                    entry.segment_virt_addr,
                    entry.segment_memory_size - 1,
                );
                if (!arch.common.process.isProgramSegmentAddressValid(upper_bound))
                    return error.SegmentLimitInvalid;
            }
            return Elf64{
                .file = file,
                .header = header,
                .program_header = program_header,
            };
        }
    };

    pub fn init(file: []align(@alignOf(Elf64.Header)) const u8) ElfInitError!Elf {
        // Check magic
        for (file[0..4]) |char, i| {
            if (char != magic_const[i]) return error.InvalidMagic;
        }
        // Check fields
        if (file.len < @sizeOf(Elf64.Header)) return error.FileTooSmall;
        const header = @ptrCast(*const Elf64.Header, file);
        switch (header.bit_width) {
            .Bit32 => return error.Bit32Unimplemented,
            .Bit64 => {
                if (!switch (std.builtin.cpu.arch) {
                    .x86_64 => header.instruction_set == .x86_64,
                    .riscv64 => header.instruction_set == .riscv,
                    else => @panic("cpu architecture unimplemented"),
                }) return error.WrongCpuArchitecture;
                if (header.elf_version != 1) return error.WrongElfVersion;
                if (header.os_abi != .SystemV) return error.WrongOsAbi;
                return Elf{ .Bit64 = try Elf64.init(file, header) };
            },
        }
    }
};
