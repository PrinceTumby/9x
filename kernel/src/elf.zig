const std = @import("std");

const logger = std.log.scoped(.elf);

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
        section_table: ?SectionTable,
        /// First entry is always reserved
        string_table: ?StringTable,
        /// First entry is always reserved
        symbol_table: ?[]const SymbolTableEntry,

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
            __undefined: u64,
            segment_image_size: u64,
            segment_memory_size: u64,
            alignment: u64,

            pub const Type = enum(u32) {
                Null = 0x0,
                Loadable = 0x1,
                DynamicLinkingInfo = 0x2,
                InterpreterInfo = 0x3,
                AuxiliaryInfo = 0x4,
                ProgHeaderTable = 0x6,
                ThreadLocalStorageTemplate = 0x7,
            };

            pub const flag_values = struct {
                pub const executable: u32 = 0b1;
                pub const writable: u32 = 0b10;
                pub const readable: u32 = 0b100;
            };
        };

        pub const SectionTable = struct {
            /// First entry is always reserved
            header_names: StringTable,
            /// First entry is always reserved
            entries: []const Entry,

            pub const Entry = packed struct {
                name: u32,
                type: Type,
                flags: u64,
                virtual_address: u64,
                offset: u64,
                size: u64,
                link: u32,
                info: u32,
                address_align: u64,
                entry_size: u64,

                pub const Type = enum(u32) {
                    Null = 0,
                    ProgramBits = 1,
                    SymbolTable = 2,
                    StringTable = 3,
                    Rela = 4,
                    Hash = 5,
                    Dynamic = 6,
                    Note = 7,
                    Nobits = 8,
                    Rel = 9,
                    SharedLib = 10,
                    DynamicSymbolTable = 11,
                    _,
                };

                pub const flag_values = struct {
                    pub const writable: u64 = 0b1;
                    pub const allocated: u64 = 0b10;
                    pub const executable_instructions: u64 = 0b100;
                };
            };
        };

        pub const StringTable = struct {
            table: []const u8,

            pub fn getString(self: *const StringTable, string_index: u32) ?[:0]const u8 {
                if (string_index == 0) return null;
                // Create string slice by finding sentinel
                var scan_i: usize = string_index;
                while (scan_i < self.table.len) : (scan_i += 1) {
                    if (self.table[scan_i] == '\x00') break;
                } else return null;
                return @ptrCast([*:0]const u8, self.table.ptr)[string_index..scan_i :0];
            }
        };

        pub const SymbolTableEntry = packed struct {
            /// Index in string table of symbol name, or 0
            name: u32,
            /// Type and binding attributes
            info: u8,
            /// Reserved
            other: u8,
            /// Section table index where symbol is 'defined', or 0
            section_index: u16,
            /// Value of the symbol, either an absolute value or an address
            value: u64,
            /// Size of the symbol, or 0
            size: u64,

            pub const Info = packed struct {
                type: Type,
                binding_attributes: BindingAttributes,

                pub const Type = enum(u4) {
                    NoType = 0,
                    Object = 1,
                    Function = 2,
                    Section = 3,
                    File = 4,
                    _,
                };

                pub const BindingAttributes = enum(u4) {
                    Local = 0,
                    Global = 1,
                    Weak = 2,
                    _,
                };
            };

            pub fn getInfo(self: *const SymbolTableEntry) Info {
                return @bitCast(Info, self.info);
            }
        };

        /// Finds the function symbol containing `address`
        pub fn getFunctionAtAddress(self: Elf64, address: usize) ?FunctionSymbol {
            const string_table = self.string_table orelse return null;
            const symbol_table = self.symbol_table orelse return null;
            var current_symbol_maybe: ?FunctionSymbol = null;
            for (symbol_table[1..]) |symbol| {
                if (symbol.getInfo().type != .Function) continue;
                if (symbol.value > address) continue;
                if (symbol.value + symbol.size <= address) continue;
                if (current_symbol_maybe) |current_symbol| {
                    if (symbol.value <= current_symbol.address) continue;
                }
                current_symbol_maybe = FunctionSymbol{
                    .name = string_table.getString(symbol.name) orelse return null,
                    .address = symbol.value,
                    .size = symbol.size,
                };
            }
            return current_symbol_maybe;
        }

        // TODO Implement basic ELF validation
        pub fn init(file: []const u8, header: *const Header) Elf64 {
            // Get program header
            const program_header = @ptrCast(
                [*]const ProgramHeaderEntry,
                &file[header.prog_header_table_pos],
            )[0..header.prog_header_table_num];
            // Try to get section header
            const section_header_maybe: ?SectionTable = blk: {
                if (header.section_header_names_index == 0) break :blk null;
                const section_table = @ptrCast(
                    [*]const SectionTable.Entry,
                    &file[header.section_header_table_pos],
                )[0..header.section_header_table_num];
                if (section_table.len <= header.section_header_names_index) break :blk null;
                const header_name_section = section_table[header.section_header_names_index];
                if (header_name_section.type != .StringTable) break :blk null;
                const slice_start = header_name_section.offset;
                const slice_end = std.math.min(
                    slice_start + header_name_section.size,
                    file.len,
                );
                break :blk SectionTable{
                    .header_names = StringTable{
                        .table = file[slice_start..slice_end],
                    },
                    .entries = section_table,
                };
            };
            // Try to get string table from section header
            const str_table_maybe: ?StringTable = blk: {
                if (section_header_maybe) |section_header| {
                    for (section_header.entries[1..]) |section| {
                        const section_name = section_header.header_names.getString(section.name)
                            orelse continue;
                        if (!std.mem.eql(u8, section_name, ".strtab")) continue;
                        if (section.type != .StringTable) break :blk null;
                        const slice_start = std.math.min(section.offset, file.len);
                        const slice_end = std.math.min(slice_start + section.size, file.len);
                        break :blk StringTable{ .table = file[slice_start..slice_end] };
                    }
                }
                break :blk null;
            };
            // Try to get symbol table from section header
            const sym_table_maybe: ?[]const SymbolTableEntry = blk: {
                if (str_table_maybe == null) break :blk null;
                if (section_header_maybe) |section_header| {
                    for (section_header.entries[1..]) |section| {
                        const section_name = section_header.header_names.getString(section.name)
                            orelse continue;
                        if (!std.mem.eql(u8, section_name, ".symtab")) continue;
                        if (section.type != .SymbolTable) break :blk null;
                        if (section.offset + section.size > file.len) break :blk null;
                        break :blk @ptrCast(
                            [*]const SymbolTableEntry,
                            &file[section.offset],
                        )[0 .. section.size / @sizeOf(SymbolTableEntry)];
                    }
                }
                break :blk null;
            };
            return Elf64{
                .file = file,
                .header = header,
                .program_header = program_header,
                .section_table = section_header_maybe,
                .string_table = str_table_maybe,
                .symbol_table = sym_table_maybe,
            };
        }
    };

    pub const FunctionSymbol = struct {
        name: [:0]const u8,
        address: usize,
        size: usize,
    };

    pub fn getFunctionAtAddress(self: Elf, address: usize) ?FunctionSymbol {
        switch (self) {
            .Bit64 => |self_64| return self_64.getFunctionAtAddress(address),
        }
    }

    pub fn init(file: []const u8) !Elf {
        // Check magic
        for (file[0..4]) |char, i| {
            if (char != magic_const[i]) return error.InvalidMagic;
        }
        // Check fields
        const header = @ptrCast(*const Elf64.Header, file);
        switch (header.bit_width) {
            .Bit32 => return error.Bit32Unimplemented,
            .Bit64 => {
                if (header.elf_version != 1) return error.WrongElfVersion;
                if (header.os_abi != .SystemV) return error.WrongOsAbi;
                return Elf{ .Bit64 = Elf64.init(file, header) };
            },
        }
    }
};
