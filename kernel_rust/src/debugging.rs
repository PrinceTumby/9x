use core::arch::asm;
use core::mem::{align_of, size_of};
use core::panic::PanicInfo;
use core::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use log::error;
// use alloc::boxed::Box;
// use unwinding::abi::*;
// use core::ffi::c_void;

// This isn't really "multicore correct" code, but as long as we get fairly reasonable behaviour
// then it doesn't matter too much, given that this is just to get some debug information out if
// the kernel crashes.

pub static DISABLE_TRACE_LOGGING: AtomicBool = AtomicBool::new(false);
pub static mut KERNEL_ELF_FILE: Option<&'static [u8]> = None;
static PANIC_DEPTH: AtomicUsize = AtomicUsize::new(0);

// #[inline(never)]
// fn print_stack_trace() {
//     struct CallbackData {
//         counter: usize,
//     }
//     extern "C" fn callback(
//         unwind_ctx: &mut UnwindContext,
//         arg: *mut c_void,
//     ) -> UnwindReasonCode {
//         let data = unsafe { &mut *(arg as *mut CallbackData) };
//         data.counter += 1;
//         error!(
//             "{:4}:{:#19x} - <unknown>",
//             data.counter,
//             _Unwind_GetIP(unwind_ctx)
//         );
//         UnwindReasonCode::NO_REASON
//     }
//     let mut data = CallbackData { counter: 0 };
//     _Unwind_Backtrace(callback, &mut data as *mut _ as _);
// }

struct StackFrameIterator {
    frame_address: usize,
    last_frame_address: usize,
}

impl StackFrameIterator {
    pub unsafe fn new(start_frame_address: usize) -> Self {
        Self {
            frame_address: start_frame_address,
            last_frame_address: 0,
        }
    }
}

impl Iterator for StackFrameIterator {
    type Item = usize;

    fn next(&mut self) -> Option<Self::Item> {
        if self.frame_address == self.last_frame_address {
            return None;
        }
        if self.frame_address == 0 || !self.frame_address.is_multiple_of(align_of::<usize>()) {
            return None;
        }
        let frame_pointer = self.frame_address as *const usize;
        let instruction_pointer = (self.frame_address + size_of::<usize>()) as *const usize;
        self.last_frame_address = self.frame_address;
        unsafe {
            self.frame_address = *frame_pointer;
            match *instruction_pointer {
                0 => None,
                instruction_pointer => Some(instruction_pointer),
            }
        }
    }
}

// TODO Port over ELF file parsing and function name printing
#[inline(never)]
fn print_stack_trace() {
    let stack_frame_iterator = unsafe {
        let mut first_trace_address: usize;
        asm!("mov {}, rbp", out(reg) first_trace_address);
        StackFrameIterator::new(first_trace_address)
    };
    for instruction_address in stack_frame_iterator {
        error!("  [{instruction_address:#x}]")
    }
}

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    error!("{info}");
    match PANIC_DEPTH.fetch_add(1, Ordering::SeqCst) {
        0 => {}
        1 => DISABLE_TRACE_LOGGING.store(true, Ordering::SeqCst),
        2 => loop {
            unsafe {
                asm!("hlt");
            }
        },
        _ => loop {},
    }
    if !DISABLE_TRACE_LOGGING.load(Ordering::SeqCst) {
        print_stack_trace();
    }
    // struct NoPayload;
    // let code = unwinding::panic::begin_panic(Box::new(NoPayload));
    // error!("failed to initiate panic, error code {}", code.0);
    loop {
        unsafe {
            asm!("hlt");
        }
    }
}
