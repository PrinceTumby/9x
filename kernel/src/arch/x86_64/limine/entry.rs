use crate::arch::kernel_args;
use crate::arch::page_allocation;
use crate::logging;
use crate::physical_block_allocator::{MaxCapacity, PageBox, PageVec, PhysicalBlockAllocator};
use core::arch::asm;
use core::fmt::Write;

mod requests {
    use crate::arch::limine::requests::*;

    /// Reads a request through a volatile pointer. Required to stop read from being optimized
    /// away.
    pub fn read_request_volatile<T>(request: &T) -> T {
        let request_ptr = request as *const T;
        unsafe { core::ptr::read_volatile(request_ptr) }
    }

    #[unsafe(no_mangle)]
    #[used]
    pub static ENTRY_POINT: EntryPoint = EntryPoint::new(super::limine_entry);

    #[unsafe(no_mangle)]
    #[used]
    pub static FRAMEBUFFER: Framebuffer = Framebuffer::new();

    #[unsafe(no_mangle)]
    #[used]
    pub static KERNEL_FILE: KernelFile = KernelFile::new();

    #[unsafe(no_mangle)]
    #[used]
    pub static MODULE: Module = Module::new();

    #[unsafe(no_mangle)]
    #[used]
    pub static RSDP: Rsdp = Rsdp::new();

    #[unsafe(no_mangle)]
    #[used]
    pub static SMBIOS: Smbios = Smbios::new();

    #[unsafe(no_mangle)]
    #[used]
    pub static EFI_SYSTEM_TABLE: EfiSystemTable = EfiSystemTable::new();

    #[unsafe(no_mangle)]
    #[used]
    pub static MEMORY_MAP: MemoryMap = MemoryMap::new();
}

unsafe extern "C" {
    unsafe fn init64(kernel_args_ptr: core::ptr::NonNull<kernel_args::Args>) -> !;
}

struct LimineDebugLogger;

macro_rules! impl_writers_func_body {
    ($write_fn: ident, $arg: ident) => {
        crate::arch::debug_output::ArchWriter.$write_fn($arg)?;
        return Ok(());
    };
}

impl Write for LimineDebugLogger {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        impl_writers_func_body!(write_str, s);
    }

    fn write_char(&mut self, c: char) -> core::fmt::Result {
        impl_writers_func_body!(write_char, c);
    }

    fn write_fmt(&mut self, args: core::fmt::Arguments) -> core::fmt::Result {
        impl_writers_func_body!(write_fmt, args);
    }
}

impl log::Log for LimineDebugLogger {
    fn enabled(&self, _metadata: &log::Metadata) -> bool {
        true
    }

    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            _ = writeln!(
                Self,
                "[{}] ({}) {}",
                record.level(),
                record.target(),
                record.args()
            );
        }
    }

    fn flush(&self) {}
}

// TODO: Should we implement a framebuffer logger in this stage? Probably unnecessary unless a
// computer doesn't work and we can't debug it using serial (for some reason).
static LOGGER: LimineDebugLogger = LimineDebugLogger;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn limine_entry() -> ! {
    unsafe {
        use requests::read_request_volatile;
        // Clear stack base, enable SSE
        asm!(
            "xor rbp, rbp",
            "mov rax, cr0",
            "and ax, 0xFFFB",
            "or ax, 0x2",
            "mov cr0, rax",
            "mov rax, cr4",
            "or ax, (3 << 9)",
            "mov cr4, rax",
            out("rax") _,
        );
        // Setup printing to Limine terminals
        crate::arch::debug_output::init_writers();
        logging::init_wrapper();
        _ = logging::CURRENT_LOGGER.lock().replace(&LOGGER);
        // Get kernel ELF for debugging symbols
        let kernel_file = read_request_volatile(&requests::KERNEL_FILE)
            .response
            .unwrap_or_else(|| {
                panic!("bootloader didn't provide kernel_file");
            })
            .file
            .read();
        crate::debugging::KERNEL_ELF_FILE = Some(core::slice::from_raw_parts(
            kernel_file.ptr,
            kernel_file.size as usize,
        ));
        // Get memory map from bootloader
        let memory_map = read_request_volatile(&requests::MEMORY_MAP)
            .response
            .unwrap_or_else(|| {
                panic!("bootloader didn't provide a memory map");
            })
            .get_entries();
        // Find the amount of mappable memory for the memory bitmap
        let mappable_bytes = memory_map.iter().fold(0, |acc, entry| {
            core::cmp::max(acc, entry.base + entry.length)
        });
        // Generate kernel memory bitmap, initialise page allocator
        {
            // Bit indexing masks
            #[rustfmt::skip]
        const START_MASKS: [u8; 8] = [
            0b11111111,
            0b01111111,
            0b00111111,
            0b00011111,
            0b00001111,
            0b00000111,
            0b00000011,
            0b00000001,
        ];
            #[rustfmt::skip]
        const END_MASKS: [u8; 8] = [
            0b10000000,
            0b11000000,
            0b11100000,
            0b11110000,
            0b11111000,
            0b11111100,
            0b11111110,
            0b11111111,
        ];
            /// Number of mapped bytes per bitmap bit
            const BIT_RATIO: usize = 4096;
            /// Number of mapped bytes per bitmap byte
            const BYTE_RATIO: usize = BIT_RATIO * 8;
            // Allocate kernel memory map
            let memory_map_page_size = (mappable_bytes / BYTE_RATIO).next_multiple_of(4096);
            let kernel_bitmap = memory_map
                .iter()
                .find_map(|entry| match entry.entry_type {
                    super::MemoryMapEntryType::Usable if entry.length >= memory_map_page_size => {
                        Some(core::slice::from_raw_parts_mut(
                            entry.base as *mut u8,
                            memory_map_page_size,
                        ))
                    }
                    _ => None,
                })
                .unwrap_or_else(|| {
                    panic!("not enough contiguous memory for memory bitmap");
                });
            // Set memory to all used
            kernel_bitmap.fill(0xFF);
            // Free pages in kernel bitmap for memory map entries that are usable
            let usable_entries_iter = memory_map
                .iter()
                .filter(|entry| entry.entry_type == super::MemoryMapEntryType::Usable);
            for entry in usable_entries_iter {
                // Find start and ending bit indices in the bitmap
                let start_bitmap_i = entry.base / BIT_RATIO;
                let end_bitmap_i = (entry.base + entry.length - 1) / BIT_RATIO;
                // Indices of bytes containing the start and end bits
                let start_byte_i = start_bitmap_i / 8;
                let end_byte_i = end_bitmap_i / 8;
                // Indices of bits in bytes containing the start and end bits
                let start_bit_i = start_bitmap_i % 8;
                let end_bit_i = end_bitmap_i % 8;
                // Go through all the bytes modified, clear out bits
                if start_byte_i == end_byte_i {
                    kernel_bitmap[start_byte_i] &=
                        !START_MASKS[start_bit_i] | !END_MASKS[end_bit_i];
                } else {
                    kernel_bitmap[start_byte_i] &= !START_MASKS[start_bit_i];
                    kernel_bitmap[start_byte_i + 1..end_byte_i].fill(0);
                    kernel_bitmap[end_byte_i] &= !END_MASKS[end_bit_i];
                }
            }
            // Reserve space used for kernel bitmap in kernel bitmap
            {
                // Find start and ending bit indices in the bitmap
                let start_bitmap_i = kernel_bitmap.as_ptr() as usize / BIT_RATIO;
                let end_bitmap_i = kernel_bitmap.as_ptr() as usize + kernel_bitmap.len() - 1;
                // Indices of bytes containing the start and end bits
                let start_byte_i = start_bitmap_i / 8;
                let end_byte_i = end_bitmap_i / 8;
                // Indices of bits in bytes containing the start and end bits
                let start_bit_i = start_bitmap_i % 8;
                let end_bit_i = end_bitmap_i % 8;
                // Go through all the bytes modified, clear out bits
                if start_byte_i == end_byte_i {
                    kernel_bitmap[start_byte_i] |= START_MASKS[start_bit_i] & END_MASKS[end_bit_i];
                } else {
                    kernel_bitmap[start_byte_i] |= START_MASKS[start_bit_i];
                    kernel_bitmap[start_byte_i + 1..end_byte_i].fill(0xFF);
                    kernel_bitmap[end_byte_i] |= END_MASKS[end_bit_i];
                }
            }
            log::debug!(
                "Allocated kernel memory bitmap - ptr: {:p}, len: {:#x}",
                kernel_bitmap,
                kernel_bitmap.len(),
            );
            let page_table_address = {
                let mut address: usize;
                asm!("mov {}, cr3", out(reg) address, options(nomem, nostack));
                address
            };
            page_allocation::init(page_table_address, kernel_bitmap, mappable_bytes / 4096);
        };
        // Allocate framebuffers
        let framebuffers = match read_request_volatile(&requests::FRAMEBUFFER).response {
            Some(response) => {
                let mut framebuffers = PageVec::new_with_max_capacity();
                let limine_framebuffers = response.get_framebuffers();
                if framebuffers.capacity() < limine_framebuffers.len() {
                    log::warn!(
                        "Only able to allocate {} out of {} framebuffers",
                        framebuffers.capacity(),
                        limine_framebuffers.len(),
                    );
                }
                for (i, fb) in limine_framebuffers.iter().enumerate() {
                    if fb.bpp != 32 {
                        log::warn!("Skipping framebuffer {i} because of unknown BPP {}", fb.bpp);
                        continue;
                    }
                    if fb.memory_model != super::FramebufferModel::Rgb {
                        log::warn!(
                            "Skipping framebuffer {i} because of unknown memory model {:?}",
                            fb.memory_model
                        );
                        continue;
                    }
                    let scanline_length = fb.pitch as u32 / (fb.bpp as u32 / 8);
                    framebuffers.push(kernel_args::Framebuffer {
                        ptr: fb.ptr,
                        ptr_type: kernel_args::PtrType::Linear,
                        size: scanline_length * fb.height as u32 * (fb.bpp as u32 / 8),
                        width: fb.width as u32,
                        height: fb.height as u32,
                        scanline_length,
                        color_format: kernel_args::ColorFormat::Bgrr8,
                    });
                    log::debug!("Added framebuffer {i}");
                    if framebuffers.len() == framebuffers.capacity() {
                        break;
                    }
                }
                let framebuffers_slice = framebuffers.leak();
                kernel_args::Slice {
                    ptr: framebuffers_slice.as_ptr(),
                    len: framebuffers_slice.len(),
                }
            }
            None => {
                log::info!("Bootloader provided no framebuffers");
                kernel_args::Slice::null()
            }
        };
        // Get initrd file
        let Some(module_response) = read_request_volatile(&requests::MODULE).response else {
            panic!("no initrd module was provided to the kernel");
        };
        if module_response.module_count < 1 {
            panic!("no initrd module was provided to the kernel");
        }
        let initrd_file = *module_response.modules;
        // Get architecture pointers
        let efi_ptr = match read_request_volatile(&requests::EFI_SYSTEM_TABLE).response {
            Some(response) => response.ptr,
            None => 0,
        };
        let acpi_ptr = match read_request_volatile(&requests::RSDP).response {
            Some(response) => response.ptr,
            None => None,
        };
        // Write kernel arguments
        let kernel_args_ptr = PageBox::new_in(
            kernel_args::Args {
                kernel_elf: kernel_args::Slice {
                    ptr: kernel_file.ptr,
                    len: kernel_file.size as usize,
                },
                page_table_address: page_allocation::page_table_address(),
                environment: kernel_args::Slice {
                    ptr: core::ptr::null(),
                    len: 0,
                },
                memory_bitmap: kernel_args::MemoryBitmap {
                    slice: page_allocation::memory_bitmap(),
                    mapped_size: mappable_bytes,
                },
                initrd: kernel_args::Slice {
                    ptr: initrd_file.ptr,
                    len: initrd_file.size as usize,
                },
                arch_ptrs: kernel_args::ArchPointers {
                    efi_ptr,
                    acpi_ptr,
                    smbi_ptr: 0,
                    mp_ptr: 0,
                },
                framebuffers,
            },
            PhysicalBlockAllocator,
        );
        page_allocation::deinit_and_remove().unwrap();
        // Call kernel init64 entry point
        init64(PageBox::leak(kernel_args_ptr).into());
    }
}
