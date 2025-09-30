pub mod entry;

pub mod requests {
    // Requests have `Sync` manually implemented so they can be stored in static variables.
    // This is safe, as they are only ever accessed by the bootstrap thread.

    pub const COMMON_ID_MAGIC: [u64; 2] = [0xC7B1DD30DF4C8B88, 0x0A82E883A194F07B];

    #[repr(C)]
    pub struct EntryPoint {
        pub common_id_magic: [u64; 2],
        pub id: [u64; 2],
        pub revision: u64,
        pub response: Option<&'static super::responses::EntryPoint>,
        pub entry_fn: unsafe extern "C" fn() -> !,
    }

    unsafe impl Sync for EntryPoint {}

    impl EntryPoint {
        pub const fn new(entry_fn: unsafe extern "C" fn() -> !) -> Self {
            Self {
                common_id_magic: COMMON_ID_MAGIC,
                id: [0x13D86C035A1CD3E1, 0x2B0CAA89D8F3026A],
                revision: 0,
                response: None,
                entry_fn,
            }
        }
    }

    macro_rules! basic_request {
        ($name:ident, $response:path, $id:expr) => {
            #[repr(C)]
            pub struct $name {
                pub common_id_magic: [u64; 2],
                pub id: [u64; 2],
                pub revision: u64,
                pub response: Option<&'static $response>,
            }

            unsafe impl Sync for $name {}

            impl $name {
                #[allow(clippy::new_without_default)]
                pub const fn new() -> Self {
                    Self {
                        common_id_magic: COMMON_ID_MAGIC,
                        id: $id,
                        revision: 0,
                        response: None,
                    }
                }
            }
        };
    }

    use super::responses as response;

    basic_request!(
        Framebuffer,
        response::Framebuffer,
        [0x9D5827DCD881DD75, 0xA3148604F6FAB11B]
    );
    basic_request!(
        MemoryMap,
        response::MemoryMap,
        [0x67CF3D9D378A806F, 0xE304ACDFC50C3C62]
    );
    basic_request!(
        KernelFile,
        response::KernelFile,
        [0xAD97E90E83F1ED67, 0x31EB5D1C5FF23B69]
    );
    basic_request!(
        Module,
        response::Module,
        [0x3E7E279702BE32AF, 0xCA1C4F3BD1280CEE]
    );
    basic_request!(
        Rsdp,
        response::Rsdp,
        [0xC5E77B6B397E7B43, 0x27637845ACCDCF3C]
    );
    basic_request!(
        Smbios,
        response::Smbios,
        [0x9E9046F11E095391, 0xAA4A520FEFBDE5EE]
    );
    basic_request!(
        EfiSystemTable,
        response::EfiSystemTable,
        [0x5CEBA5163EAAF6D6, 0x0A6981610CF65FCC]
    );
}

pub mod responses {
    #[repr(C)]
    pub struct EntryPoint {
        pub revision: u64,
    }

    #[repr(C)]
    pub struct Framebuffer {
        pub revision: u64,
        num_framebuffers: u64,
        framebuffers: *const &'static super::Framebuffer,
    }

    impl Framebuffer {
        pub unsafe fn get_framebuffers(&self) -> &[&'static super::Framebuffer] {
            unsafe {
                core::slice::from_raw_parts(self.framebuffers, self.num_framebuffers as usize)
            }
        }
    }

    #[repr(C)]
    pub struct MemoryMap {
        pub revision: u64,
        num_entries: u64,
        entries: *const &'static super::MemoryMapEntry,
    }

    impl MemoryMap {
        pub unsafe fn get_entries(&self) -> &[&'static super::MemoryMapEntry] {
            unsafe { core::slice::from_raw_parts(self.entries, self.num_entries as usize) }
        }
    }

    #[repr(C)]
    pub struct KernelFile {
        pub revision: u64,
        pub file: *const super::File,
    }

    #[repr(C)]
    pub struct Module {
        pub revision: u64,
        pub module_count: u64,
        pub modules: *const &'static super::File,
    }

    #[repr(C)]
    pub struct Rsdp {
        pub revision: u64,
        pub ptr: Option<core::ptr::NonNull<()>>,
    }

    #[repr(C)]
    pub struct Smbios {
        pub revision: u64,
        pub entry_32: usize,
        pub entry_64: usize,
    }

    #[repr(C)]
    pub struct EfiSystemTable {
        pub revision: u64,
        pub ptr: usize,
    }
}

#[repr(C)]
pub struct Framebuffer {
    pub ptr: core::ptr::NonNull<u32>,
    pub width: u64,
    pub height: u64,
    pub pitch: u64,
    pub bpp: u16,
    pub memory_model: FramebufferModel,
    pub red_mask_size: u8,
    pub red_mask_shift: u8,
    pub green_mask_size: u8,
    pub green_mask_shift: u8,
    pub blue_mask_size: u8,
    pub blue_mask_shift: u8,
    pub unused: [u8; 7],
    pub edid_size: u64,
    pub edid: Option<core::ptr::NonNull<Edid>>,
    pub mode_count: u64,
    pub modes: *const &'static VideoMode,
}

#[repr(C)]
pub struct VideoMode {
    pub pitch: u64,
    pub width: u64,
    pub height: u64,
    pub bpp: u64,
    pub memory_model: FramebufferModel,
    pub red_mask_size: u8,
    pub red_mask_shift: u8,
    pub green_mask_size: u8,
    pub green_mask_shift: u8,
    pub blue_mask_size: u8,
    pub blue_mask_shift: u8,
}

#[repr(u8)]
#[non_exhaustive]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FramebufferModel {
    Rgb = 1,
}

#[repr(C)]
pub struct Edid {
    _data: [u8; 0],
    _marker: core::marker::PhantomData<(*mut u8, core::marker::PhantomPinned)>,
}

#[repr(C)]
pub struct MemoryMapEntry {
    pub base: usize,
    pub length: usize,
    pub entry_type: MemoryMapEntryType,
}

#[repr(u64)]
#[non_exhaustive]
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum MemoryMapEntryType {
    Usable = 0,
    Reserved = 1,
    AcpiReclaimable = 2,
    AcpiNonVolatileStorage = 3,
    BadMemory = 4,
    BootloaderReclaimable = 5,
    KernelAndModules = 6,
    Framebuffer = 7,
}

#[repr(C)]
pub struct Uuid {
    pub a: u32,
    pub b: u16,
    pub c: u16,
    pub d: [u8; 8],
}

#[repr(C)]
pub struct File {
    pub revision: u64,
    pub ptr: *const u8,
    pub size: u64,
    pub path_cstr: *const core::ffi::c_char,
    pub cmdline_cstr: *const core::ffi::c_char,
    pub media_type: FileMediaType,
    _unused: u32,
    pub tftp_ip: u32,
    pub tftp_port: u32,
    pub partition_index: u32,
    pub mbr_disk_id: u32,
    pub gpt_disk_uuid: Uuid,
    pub gpt_part_uuid: Uuid,
    pub part_uuid: Uuid,
}

#[repr(u32)]
#[non_exhaustive]
pub enum FileMediaType {
    Generic = 0,
    Optical = 1,
    Tftp = 2,
}
