use super::define_asm_symbol;

/// Arguments passed to the kernel at load time.
#[repr(C)]
#[derive(Clone)]
pub struct Args {
    pub kernel_elf: Slice<u8>,
    pub page_table_address: usize,
    pub environment: Slice<u8>,
    pub memory_bitmap: MemoryBitmap,
    pub initrd: Slice<u8>,
    pub arch_ptrs: ArchPointers,
    pub framebuffers: Slice<Framebuffer>,
}

// The page table address is used in assembly, so export it here
define_asm_symbol!(
    "kernel_args::Args.page_table_address",
    core::mem::offset_of!(Args, page_table_address)
);

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Slice<T> {
    pub ptr: *const T,
    pub len: usize,
}

impl<T> Slice<T> {
    pub const fn null() -> Self {
        Self {
            ptr: core::ptr::null(),
            len: 0,
        }
    }

    pub unsafe fn get_slice<'a>(&self) -> &'a [T] {
        unsafe {
            core::slice::from_raw_parts(self.ptr, self.len)
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct MutSlice<T> {
    pub ptr: *mut T,
    pub len: usize,
}

impl<T> MutSlice<T> {
    pub const fn null() -> Self {
        Self {
            ptr: core::ptr::null_mut(),
            len: 0,
        }
    }

    pub unsafe fn get_slice_mut<'a>(&self) -> &'a mut [T] {
        unsafe {
            core::slice::from_raw_parts_mut(self.ptr, self.len)
        }
    }
}

impl<T> From<&mut [T]> for MutSlice<T> {
    fn from(slice: &mut [T]) -> Self {
        Self {
            ptr: slice.as_mut_ptr(),
            len: slice.len(),
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct MemoryBitmap {
    /// Memory bitmap slice
    pub slice: MutSlice<u8>,
    /// Size of area represented by bitmap
    pub mapped_size: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ArchPointers {
    pub efi_ptr: usize,
    pub acpi_ptr: Option<core::ptr::NonNull<()>>,
    pub mp_ptr: usize,
    pub smbi_ptr: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Framebuffer {
    pub ptr: core::ptr::NonNull<u32>,
    pub ptr_type: PtrType,
    pub size: u32,
    pub width: u32,
    pub height: u32,
    pub scanline_length: u32,
    pub color_format: ColorFormat,
}

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PtrType {
    Physical,
    Linear,
}

#[repr(C, u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorFormat {
    /// Red, Green, Blue, Reserved - 8 bits per color
    Rgbr8,
    /// Blue, Green, Red, Reserved - 8 bits per color
    Bgrr8,
    /// Custom bitmask - information derived from masks
    Bitmask(ColorBitmask),
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ColorBitmask {
    pub red_mask: u32,
    pub green_mask: u32,
    pub blue_mask: u32,
    pub reserved_mask: u32,
}
