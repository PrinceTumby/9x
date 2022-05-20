// Functions and data structures to decode ELF files (used to load the kernel)

pub const Elf64 = packed struct {
    magic: [4]u8,
    bit_width: BitWidth,
    endianness: Endianness,
    elf_header_version: u8,
    os_abi: OsAbi,
    __padding: [8]u8,
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

    pub const BitWidth = enum(u8) {
        Bit32 = 1,
        Bit64 = 2,
    };

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
    };

    pub const ElfType = enum(u16) {
        None = 0,
        Relocatable = 1,
        Executable = 2,
        Dynamic = 3,
        Core = 4,
    };

    pub const InstructionSet = enum(u16) {
        NonSpecific = 0x0,
        Sparc = 0x2,
        x86 = 0x3,
        Mips = 0x8,
        PPC = 0x14,
        PPC64 = 0x15,
        Arm = 0x28,
        Super_h = 0x2A,
        Ia_64 = 0x32,
        x86_64 = 0x3E,
        Aarch64 = 0xB7,
        RiscV = 0xF3,
    };

    pub const magic_const: [4]u8 = [_]u8{ 0x7F, 'E', 'L', 'F' };

    pub const ProgramHeaderEntry = packed struct {
        type: enum(u32) {
            Null = 0x0,
            Loadable = 0x1,
            DynamicLinkingInfo = 0x2,
            InterpreterInfo = 0x3,
            AuxiliaryInfo = 0x4,
            ProgHeaderTable = 0x6,
            ThreadLocalStorageTemplate = 0x7,
        },
        flags: u32,
        segment_offset: u64,
        segment_virt_addr: u64,
        __undefined: u64,
        segment_image_size: u64,
        segment_memory_size: u64,
        alignment: u64,

        pub const flags = struct {
            pub const executable = 0b1;
            pub const writable = 0b10;
            pub const readable = 0b100;
        };
    };

    const Self = @This();

    pub fn parseFile(file: []const u8) ?*const Self {
        // Check magic
        for (file[0..4]) |char, i| {
            if (char != magic_const[i]) return null;
        }
        const header = @ptrCast(*const Self, file);
        // Check fields
        if (header.bit_width != .Bit64 or
            header.elf_version != 1 or
            header.os_abi != .SystemV or
            header.type != .Executable or
            header.instruction_set != .x86_64) return null;
        return header;
    }

    pub fn getProgramHeader(self: *const Self, file: []const u8) []const ProgramHeaderEntry {
        return @ptrCast(
            [*]const ProgramHeaderEntry,
            &file[self.prog_header_table_pos],
        )[0..self.prog_header_table_num];
    }
};
