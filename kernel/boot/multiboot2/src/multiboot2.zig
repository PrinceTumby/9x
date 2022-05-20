pub const BootInformation = extern struct {
    total_size: u32,
    reserved: u32,
    first_tag: tag.Basic,
};

pub const tag = struct {
    pub const Type = extern enum(u32) {
        End = 0,
        CommandLine = 1,
        BootLoaderName = 2,
        Module = 3,
        BasicMemoryInfo = 4,
        BiosBootDevice = 5,
        MemoryMap = 6,
        VbeInfo = 7,
        FramebufferInfo = 8,
        ElfSymbols = 9,
        ApmTable = 10,
        EfiSystemTable32 = 11,
        EfiSystemTable64 = 12,
        SmbiosTables = 13,
        AcpiRsdp1 = 14,
        AcpiRsdp2 = 15,
        NetworkInfo = 16,
        EfiMemoryMap = 17,
        EfiBootServicesNotTerminated = 18,
        EfiImageHandle32 = 19,
        EfiImageHandle64 = 20,
        ImageLoadBasePhysicalAddress = 21,
        _,
    };

    pub const Basic = extern struct {
        tag_type: Type,
        tag_size: u32,

        pub fn isEndTag(self: *const Basic) bool {
            return self.tag_type == .End and self.tag_size == 8;
        }
    };

    pub const BasicMemoryInfo = extern struct {
        tag_type: Type = .BasicMemoryInfo,
        tag_size: u32,
        mem_lower: u32,
        mem_upper: u32,
    };
};
