use core::panic::PanicInfo;
use core::arch::asm;
use log::error;
use core::sync::atomic::{AtomicUsize, AtomicBool, Ordering};
use alloc::boxed::Box;
// use unwinding::abi::*;
// use core::ffi::c_void;

// This isn't really "multicore correct" code, but as long as we get fairly reasonable behaviour
// then it doesn't matter too much, given that this is just to get some debug information out if
// the kernel crashes.

static PANIC_DEPTH: AtomicUsize = AtomicUsize::new(0);
static DISABLE_TRACE_LOGGING: AtomicBool = AtomicBool::new(false);

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

#[inline(never)]
fn print_stack_trace() {
    // Get kernel ELF file for function names
    let kernel_elf = {
        // let elf_slice = 
    };
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
        }
        _ => loop {}
    }
    if !DISABLE_TRACE_LOGGING.load(Ordering::SeqCst) {
        print_stack_trace();
    }
    struct NoPayload;
    let code = unwinding::panic::begin_panic(Box::new(NoPayload));
    error!("failed to initiate panic, error code {}", code.0);
    loop {
        unsafe {
            asm!("hlt");
        }
    }
}
