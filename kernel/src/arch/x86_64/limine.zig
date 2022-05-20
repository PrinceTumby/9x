const root = @import("root");

pub const requests = struct {
    pub const common_id_magic = [2]u64{
        0xc7b1dd30df4c8b88,
        0x0a82e883a194f07b,
    };

    pub const EntryPoint = extern struct {
        id: [4]u64 = common_id_magic ++ [2]u64{
            0x13d86c035a1cd3e1,
            0x2b0caa89d8f3026a,
        },
        revision: u64 = 0,
        response: ?*responses.EntryPoint = null,
        entry: fn() callconv(.C) void,
    };

    pub const Terminal = extern struct {
        id: [4]u64 = common_id_magic ++ [2]u64{
            0x0785a0aea5d0750f,
            0x1c1936fee0d6cf6e,
        },
        revision: u64 = 0,
        response: ?*responses.Terminal = null,
        callback: fn(terminal: *LimineTerminal, type: u64, u64, u64, u64) callconv(.C) void,
    };

    pub const Framebuffer = extern struct {
        id: [4]u64 = common_id_magic ++ [2]u64{
            0xcbfe81d7dd2d1977,
            0x063150319ebc9b71,
        },
        revision: u64 = 0,
        response: ?*responses.Framebuffer = null,
    };

    pub const MemoryMap = extern struct {
        id: [4]u64 = common_id_magic ++ [2]u64{
            0x67cf3d9d378a806f,
            0xe304acdfc50c3c62,
        },
        revision: u64 = 0,
        response: ?*responses.MemoryMap = null,
    };

    pub const KernelFile = extern struct {
        id: [4]u64 = common_id_magic ++ [2]u64{
            0xad97e90e83f1ed67,
            0x31eb5d1c5ff23b69,
        },
        revision: u64 = 0,
        response: ?*responses.KernelFile = null,
    };

    pub const Module = extern struct {
        id: [4]u64 = common_id_magic ++ [2]u64{
            0x3e7e279702be32af,
            0xca1c4f3bd1280cee,
        },
        revision: u64 = 0,
        response: ?*responses.Module = null,
    };

    pub const Rsdp = extern struct {
        id: [4]u64 = common_id_magic ++ [2]u64{
            0xc5e77b6b397e7b43,
            0x27637845accdcf3c,
        },
        revision: u64 = 0,
        response: ?*responses.Rsdp = null,
    };

    pub const Smbios = extern struct {
        id: [4]u64 = common_id_magic ++ [2]u64{
            0x9e9046f11e095391,
            0xaa4a520fefbde5ee,
        },
        revision: u64 = 0,
        response: ?*responses.Smbios = null,
    };

    pub const EfiSystemTable = extern struct {
        id: [4]u64 = common_id_magic ++ [2]u64{
            0x5ceba5163eaaf6d6,
            0x0a6981610cf65fcc,
        },
        revision: u64 = 0,
        response: ?*responses.EfiSystemTable = null,
    };
};

pub const responses = struct {
    pub const EntryPoint = extern struct {
        revision: u64 = 0,
    };

    pub const Terminal = extern struct {
        revision: u64 = 0,
        terminal_count: u64,
        terminals: [*]const *LimineTerminal,
        write: fn(terminal: *LimineTerminal, string: [*]const u8, len: u64) callconv(.C) void,
    };

    pub const Framebuffer = extern struct {
        revision: u64 = 0,
        framebuffer_count: u64 = 0,
        framebuffers: [*]const *LimineFramebuffer,
    };

    pub const MemoryMap = extern struct {
        revision: u64 = 0,
        entry_count: u64,
        entries: [*]const *const MemoryMapEntry,
    };

    pub const KernelFile = extern struct {
        revision: u64 = 0,
        kernel_file: *LimineFile,
    };

    pub const Module = extern struct {
        revision: u64 = 0,
        module_count: u64,
        modules: [*]*LimineFile,
    };

    pub const Rsdp = extern struct {
        revision: u64 = 0,
        rsdp_ptr: *root.arch.platform.acpi.Rsdp,
    };

    pub const Smbios = extern struct {
        revision: u64 = 0,
        entry_32: ?*const c_void,
        entry_64: ?*const c_void,
    };

    pub const EfiSystemTable = extern struct {
        revision: u64 = 0,
        efi_ptr: [*]const u8,
    };
};

pub const LimineTerminal = extern struct {
    columns: u32,
    rows: u32,
    framebuffer: *LimineFramebuffer,
};

pub const LimineFramebuffer = extern struct {
    ptr: [*]volatile u32,
    width: u16,
    height: u16,
    pitch: u16,
    bpp: u16,
    memory_model: enum(u8) {
        Rgb = 1,
        _,
    },
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: u8,
    edid_size: u64,
    edid: ?*c_void,
};

pub const MemoryMapEntry = extern struct {
    base: u64,
    length: u64,
    type: Type,

    pub const Type = enum(u64) {
        Usable = 0,
        Reverved = 1,
        AcpiReclaimable = 2,
        AcpiNonVolatileStorage = 3,
        BadMemory = 4,
        BootloaderReclaimable = 5,
        KernelAndModules = 6,
        Framebuffer = 7,
        _,
    };
};

pub const LimineUuid = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};

pub const LimineFile = extern struct {
    revision: u64,
    address: [*]u8,
    size: u64,
    path: [*:0]u8,
    cmdline: [*:0]u8,
    media_type: enum(u32) {
        Generic = 0,
        Optical = 1,
        Tftp = 2,
        _,
    },
    unused: u32,
    tftp_ip: u32,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: LimineUuid,
    gpt_part_uuid: LimineUuid,
    part_uuid: LimineUuid,
};
