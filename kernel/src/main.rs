#![warn(clippy::all)]
#![allow(clippy::missing_safety_doc)]

#![no_std]
#![no_main]

// Used in in `x86_64`.
#![feature(abi_x86_interrupt)]
// Used for giving a custom panic message on allocation errors.
#![feature(alloc_error_handler)]
// Used in various places for `Box::try_new`, `Vec::try_new`, etc as well as
// `physical_block_allocator`.
#![feature(allocator_api)]
// Used as a substitute for `cfg_if` in various places.
#![feature(cfg_select)]
// Used in ACPI for defining implementations of `AcpiOsPrintf` and `AcpiOsVprintf`.
#![feature(c_variadic)]
// Used in various places, including the process Virtual Memory Allocator.
#![feature(offset_of_enum)]

pub mod arch;
pub mod core_graphics;
pub mod cpio;
pub mod debugging;
pub mod heap;
pub mod logging;
pub mod physical_block_allocator;
pub mod platform;
pub mod process;
pub mod terminal;
pub mod vma;

extern crate alloc;

use log::{debug, warn};

unsafe extern "C" {
    static HEAP_BASE: usize;
    static HEAP_END: usize;
    static LOCAL_APIC_BASE: usize;
}

const FONT_PATH: &str = "etc/kernel/standard_font.psf";

#[unsafe(no_mangle)]
pub extern "C" fn kernel_main(args: &arch::kernel_args::Args) -> ! {
    // Set up logging
    unsafe {
        arch::debug_output::init_writers();
        logging::init_wrapper();
        _ = logging::CURRENT_LOGGER
            .lock()
            .replace(&logging::KERNEL_LOGGER);
    }
    debug!("Early logging initialised");
    unsafe {
        arch::page_allocation::init(
            args.page_table_address,
            args.memory_bitmap.slice.get_slice_mut(),
            args.memory_bitmap.mapped_size,
        );
    }
    debug!("Page allocator initialised");
    arch::init_stage_1(args);
    debug!("Architecture stage 1 initialised");
    // Initialise heap
    unsafe {
        let heap_start_addr = &HEAP_BASE as *const usize as usize;
        let heap_size = (&HEAP_END as *const usize as usize) - heap_start_addr + 1;
        heap::init_heap(heap_start_addr, heap_size);
    }
    let initrd = unsafe { args.initrd.get_slice() };
    assert!(
        initrd.as_ptr() as usize > 0xF000_0000_0000_0000,
        "lower half initrd currently unsupported"
    );
    // Initialise framebuffer logging
    unsafe {
        'fb_log: {
            // Initialise framebuffer
            match args.framebuffers.len {
                0 => {
                    debug!("No framebuffer found");
                    break 'fb_log;
                }
                1 => debug!("1 framebuffer found, initialising..."),
                x => warn!(
                    concat!(
                        "{} framebuffers found, ",
                        "but 9x currently only supports using a single framebuffer"
                    ),
                    x
                ),
            }
            let framebuffer_arg = args.framebuffers.get_slice()[0];
            assert!(
                framebuffer_arg.ptr.as_ptr() as usize > 0xF000_0000_0000_0000,
                "lower half framebuffers currently unsupported",
            );
            if framebuffer_arg.ptr_type != arch::kernel_args::PtrType::Linear {
                warn!("Physical location framebuffers currently unsupported");
                break 'fb_log;
            }
            if framebuffer_arg.color_format != arch::kernel_args::ColorFormat::Bgrr8 {
                warn!(
                    "Unsupported framebuffer format: {:?}, ignoring provided framebuffer",
                    framebuffer_arg.color_format
                );
                break 'fb_log;
            }
            // Swap in new feamebuffer
            {
                let mut global_framebuffer = core_graphics::FRAMEBUFFER.lock();
                let mut new_framebuffer = core_graphics::Framebuffer {
                    buffer: core::slice::from_raw_parts_mut(
                        framebuffer_arg.ptr.as_ptr(),
                        framebuffer_arg.size as usize,
                    ),
                    width: framebuffer_arg.width,
                    height: framebuffer_arg.height,
                    scanline_length: framebuffer_arg.scanline_length,
                    color_format: framebuffer_arg.color_format,
                };
                new_framebuffer.clear();
                _ = global_framebuffer.replace(new_framebuffer);
            }
            // Initialise console font for terminal
            let font_result: Result<_, &str> = 'font: {
                let Some(font_file) = cpio::find_file(initrd, FONT_PATH.as_bytes()) else {
                    break 'font Err("file not found");
                };
                terminal::psf::Font::new(font_file)
            };
            let font = match font_result {
                Ok(font) => font,
                Err(err_msg) => {
                    warn!("Terminal initialisation failed - font load error: \"{err_msg}\"");
                    break 'fb_log;
                }
            };
            // Swap in new terminal
            {
                let mut global_terminal = terminal::TERMINAL.lock();
                let new_terminal = terminal::Terminal::new(font).unwrap();
                _ = global_terminal.replace(new_terminal);
            }
            debug!("Framebuffer terminal initialised");
        }
    }
    // Architecture stage 2 init
    unsafe {
        arch::init_stage_2(args);
    }
    debug!("Finished, entering infinite loop!");
    #[allow(clippy::empty_loop)]
    loop {}
}

#[alloc_error_handler]
fn alloc_error(layout: alloc::alloc::Layout) -> ! {
    panic!("out of memory when allocating with layout {layout:?}");
}
