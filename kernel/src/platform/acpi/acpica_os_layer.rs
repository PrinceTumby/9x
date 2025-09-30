#![allow(non_snake_case)]

use super::acpica_sys::{Boolean, Status};
use crate::arch::page_allocation;
use crate::arch::paging::PageTableEntry;
use crate::logging::KERNEL_LOGGER;
use alloc::alloc::{Layout, alloc, dealloc};
use alloc::boxed::Box;
use core::ffi::{CStr, VaList, c_char};
use core::fmt::Write;
use core::ptr::NonNull;
use spin::Mutex;

pub static RSDP_ADDRESS: Mutex<usize> = Mutex::new(0);

// TODO Check uses of `usize` and `u64` against the manual

// Environment and tables

#[unsafe(no_mangle)]
extern "C" fn AcpiOsInitialize() -> Status {
    Status::OK
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsTerminate() -> Status {
    Status::OK
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsGetRootPointer() -> usize {
    *RSDP_ADDRESS.lock()
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsPredefinedOverride(
    _predefined_object: usize,
    new_value: &mut Option<NonNull<()>>,
) -> Status {
    *new_value = None;
    Status::OK
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsTableOverride(
    _existing_table: usize,
    new_table: &mut Option<NonNull<()>>,
) -> Status {
    *new_table = None;
    Status::OK
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsPhysicalTableOverride(
    _existing_table: usize,
    new_table: &mut Option<NonNull<()>>,
    _new_length: u32,
) -> Status {
    *new_table = None;
    Status::OK
}

// Memory management

#[unsafe(no_mangle)]
extern "C" fn AcpiOsMapMemory(physical_address: u64, _length: u64) -> u64 {
    // Entirety of physical memory is identity mapped, so this should be fine
    physical_address
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsUnmapMemory(_physical_address: u64, _length: u64) -> Status {
    // No mapping done in AcpiOsMapMemory, so do nothing here
    Status::OK
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsGetPhysicalAddress(
    logical_address: usize,
    physical_address: &mut usize,
) -> Status {
    // All of physical memory is identity mapped
    *physical_address = logical_address;
    Status::OK
}

#[unsafe(no_mangle)]
unsafe extern "C" fn AcpiOsAllocate(size: usize) -> *mut u8 {
    unsafe { alloc(Layout::from_size_align(size, 8).unwrap()) }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn AcpiOsFree(ptr: *mut u8) {
    unsafe {
        // SAFETY: Current heap allocator does not rely on knowing size of allocation
        dealloc(ptr, Layout::from_size_align(8, 8).unwrap())
    }
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsReadable(virtual_address_start: usize, len: usize) -> Boolean {
    page_allocation::check_flags(virtual_address_start, len, PageTableEntry::READ).into()
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsWritable(virtual_address_start: usize, len: usize) -> Boolean {
    page_allocation::check_flags(virtual_address_start, len, PageTableEntry::READ_WRITE).into()
}

// Mutual exclusion and synchronization
// We use dummy synchronization primitives here, as we're only running ACPICA single threaded.

#[unsafe(no_mangle)]
unsafe extern "C" fn AcpiOsCreateMutex(out_handle: Option<&mut *mut bool>) -> Status {
    let Some(out_handle) = out_handle else {
        return Status::BAD_PARAMETER;
    };
    let Ok(dummy_mutex) = Box::try_new(false) else {
        return Status::NO_MEMORY;
    };
    *out_handle = Box::leak(dummy_mutex) as *mut bool;
    Status::OK
}

#[unsafe(no_mangle)]
unsafe extern "C" fn AcpiOsDeleteMutex(handle: Option<NonNull<bool>>) {
    unsafe {
        let Some(handle) = handle else {
            return;
        };
        drop(Box::from_raw(handle.as_ptr()));
    }
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsAcquireMutex(handle: Option<&mut bool>, timeout: u16) -> Status {
    let Some(dummy_mutex) = handle else {
        return Status::BAD_PARAMETER;
    };
    if *dummy_mutex {
        if timeout == 0xFFFF {
            panic!("mutex poisoned");
        } else {
            Status::TIME
        }
    } else {
        *dummy_mutex = true;
        Status::OK
    }
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsReleaseMutex(handle: Option<&mut bool>) {
    let Some(dummy_mutex) = handle else {
        return;
    };
    if *dummy_mutex {
        *dummy_mutex = false;
    } else {
        panic!("mutex poisoned");
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn AcpiOsCreateSemaphore(
    max_units: u32,
    initial_units: u32,
    out_handle: Option<&mut *mut ()>,
) -> Status {
    if initial_units > max_units {
        return Status::BAD_PARAMETER;
    }
    let Some(out_handle) = out_handle else {
        return Status::BAD_PARAMETER;
    };
    *out_handle = core::ptr::null_mut();
    Status::OK
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsDeleteSemaphore(_handle: Option<NonNull<()>>) -> Status {
    Status::OK
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsWaitSemaphore(
    _handle: Option<NonNull<()>>,
    _units: u32,
    _timeout: u16,
) -> Status {
    Status::OK
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsSignalSemaphore(_handle: Option<NonNull<bool>>, _units: u32) -> Status {
    Status::OK
}

#[unsafe(no_mangle)]
unsafe extern "C" fn AcpiOsCreateLock(out_handle: Option<&mut *mut ()>) -> Status {
    let Some(out_handle) = out_handle else {
        return Status::BAD_PARAMETER;
    };
    *out_handle = core::ptr::null_mut();
    Status::OK
}

#[unsafe(no_mangle)]
unsafe extern "C" fn AcpiOsDeleteLock(_handle: Option<NonNull<()>>) {}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsAcquireLock(_handle: Option<&mut ()>) -> usize {
    0
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsReleaseLock(_handle: Option<&mut ()>, _flags: usize) {}

// Printing functions

#[unsafe(no_mangle)]
unsafe extern "C" fn AcpiOsPrintf(format_string_ptr: *const c_char, mut args: ...) {
    unsafe {
        AcpiOsVprintf(format_string_ptr, args.as_va_list());
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn AcpiOsVprintf(format_string_ptr: *const c_char, mut args: VaList) {
    unsafe {
        #[derive(Clone, Copy, Debug)]
        enum State {
            RawString { string_start: usize },
            FormatStart,
            Flags,
            Width,
            Precision,
        }
        #[derive(Clone, Copy)]
        struct FormatInfo {
            pub right_aligned: Option<bool>,
            pub fill_char: char,
            pub width: usize,
            pub precision: Option<usize>,
        }
        impl Default for FormatInfo {
            fn default() -> Self {
                Self {
                    right_aligned: None,
                    fill_char: ' ',
                    width: 0,
                    precision: None,
                }
            }
        }
        let mut kernel_logger = KERNEL_LOGGER;
        let format_string = CStr::from_ptr(format_string_ptr)
            .to_str()
            .expect("format string should be valid UTF-8");
        let mut state = State::RawString { string_start: 0 };
        let mut format_info = FormatInfo::default();
        let mut print_type = |specifier: char, format_info: FormatInfo| {
            let mut kernel_logger = KERNEL_LOGGER;
            macro_rules! write_formatted {
                ($arg:expr, $width:expr, $right_aligned:expr, $fill_char:expr, $precision:expr) => {
                    write_formatted_with_type!(
                        $arg,
                        "",
                        $width,
                        $right_aligned,
                        $fill_char,
                        $precision
                    )
                };
            }
            macro_rules! write_formatted_with_type {
                ($arg:expr, $type:expr, $width:expr, $right_aligned:expr, $fill_char:expr, $precision:expr) => {
                    match ($right_aligned, $fill_char, $precision) {
                        (false, ' ', None) => write!(
                            kernel_logger,
                            concat!("{arg:<width$", $type, "}"),
                            arg = $arg,
                            width = $width,
                        )
                        .unwrap(),
                        (false, '0', None) => write!(
                            kernel_logger,
                            concat!("{arg:0<width$", $type, "}"),
                            arg = $arg,
                            width = $width,
                        )
                        .unwrap(),
                        (true, ' ', None) => write!(
                            kernel_logger,
                            concat!("{arg:>width$", $type, "}"),
                            arg = $arg,
                            width = $width,
                        )
                        .unwrap(),
                        (true, '0', None) => write!(
                            kernel_logger,
                            concat!("{arg:0>width$", $type, "}"),
                            arg = $arg,
                            width = $width,
                        )
                        .unwrap(),
                        (false, ' ', Some(precision)) => write!(
                            kernel_logger,
                            concat!("{arg:<width$.precision$", $type, "}"),
                            arg = $arg,
                            width = $width,
                            precision = precision,
                        )
                        .unwrap(),
                        (false, '0', Some(precision)) => write!(
                            kernel_logger,
                            concat!("{arg:0<width$.precision$", $type, "}"),
                            arg = $arg,
                            width = $width,
                            precision = precision,
                        )
                        .unwrap(),
                        (true, ' ', Some(precision)) => write!(
                            kernel_logger,
                            concat!("{arg:>width$.precision$", $type, "}"),
                            arg = $arg,
                            width = $width,
                            precision = precision,
                        )
                        .unwrap(),
                        (true, '0', Some(precision)) => write!(
                            kernel_logger,
                            concat!("{arg:0>width$.precision$", $type, "}"),
                            arg = $arg,
                            width = $width,
                            precision = precision,
                        )
                        .unwrap(),
                        (_, fill, _) => panic!("unknown fill char {fill:?}"),
                    }
                };
            }
            match specifier {
                'c' => write!(
                    kernel_logger,
                    "{}",
                    char::from_u32(args.arg::<u32>()).unwrap()
                )
                .unwrap(),
                's' => {
                    let string = {
                        let string_ptr = args.arg::<*const u8>();
                        let mut string_len = 0;
                        match format_info.precision {
                            Some(precision) => {
                                while string_len < precision {
                                    if *string_ptr == b'\0' {
                                        break;
                                    } else {
                                        string_len += 1;
                                    }
                                }
                            }
                            None => loop {
                                if *string_ptr == b'\0' {
                                    break;
                                } else {
                                    string_len += 1;
                                }
                            },
                        }
                        core::str::from_utf8(core::slice::from_raw_parts(string_ptr, string_len))
                            .expect("formatted string should be UTF-8")
                    };
                    write_formatted!(
                        string,
                        format_info.width,
                        format_info.right_aligned.unwrap_or(true),
                        format_info.fill_char,
                        format_info.precision
                    );
                }
                'd' | 'i' => {
                    let print_num = args.arg::<core::ffi::c_int>();
                    // C99 says precision for decimal types should pad digits up to precision, so we
                    // set the fill character to 0 and increase width to precision to get closer to
                    // the standard
                    match format_info.precision {
                        Some(precision) => {
                            assert!(format_info.width <= precision);
                            write_formatted!(
                                print_num,
                                precision,
                                format_info.right_aligned.unwrap_or(true),
                                '0',
                                format_info.precision
                            );
                        }
                        None => write_formatted!(
                            print_num,
                            format_info.width,
                            format_info.right_aligned.unwrap_or(true),
                            format_info.fill_char,
                            format_info.precision
                        ),
                    }
                }
                'u' => {
                    let print_num = args.arg::<core::ffi::c_uint>();
                    // Ditto
                    match format_info.precision {
                        Some(precision) => {
                            assert!(format_info.width <= precision);
                            write_formatted!(
                                print_num,
                                precision,
                                format_info.right_aligned.unwrap_or(true),
                                '0',
                                format_info.precision
                            );
                        }
                        None => write_formatted!(
                            print_num,
                            format_info.width,
                            format_info.right_aligned.unwrap_or(true),
                            format_info.fill_char,
                            format_info.precision
                        ),
                    }
                }
                'o' => {
                    let print_num = args.arg::<core::ffi::c_uint>();
                    // Ditto
                    match format_info.precision {
                        Some(precision) => {
                            assert!(format_info.width <= precision);
                            write_formatted_with_type!(
                                print_num,
                                "o",
                                precision,
                                format_info.right_aligned.unwrap_or(true),
                                '0',
                                format_info.precision
                            );
                        }
                        None => write_formatted_with_type!(
                            print_num,
                            "o",
                            format_info.width,
                            format_info.right_aligned.unwrap_or(true),
                            format_info.fill_char,
                            format_info.precision
                        ),
                    }
                }
                'x' => {
                    let print_num = args.arg::<core::ffi::c_uint>();
                    // Ditto
                    match format_info.precision {
                        Some(precision) => {
                            assert!(format_info.width <= precision);
                            write_formatted_with_type!(
                                print_num,
                                "x",
                                precision,
                                format_info.right_aligned.unwrap_or(true),
                                '0',
                                format_info.precision
                            );
                        }
                        None => write_formatted_with_type!(
                            print_num,
                            "x",
                            format_info.width,
                            format_info.right_aligned.unwrap_or(true),
                            format_info.fill_char,
                            format_info.precision
                        ),
                    }
                }
                'X' => {
                    let print_num = args.arg::<core::ffi::c_uint>();
                    // Ditto
                    match format_info.precision {
                        Some(precision) => {
                            assert!(format_info.width <= precision);
                            write_formatted_with_type!(
                                print_num,
                                "X",
                                precision,
                                format_info.right_aligned.unwrap_or(true),
                                '0',
                                format_info.precision
                            );
                        }
                        None => write_formatted_with_type!(
                            print_num,
                            "X",
                            format_info.width,
                            format_info.right_aligned.unwrap_or(true),
                            format_info.fill_char,
                            format_info.precision
                        ),
                    }
                }
                _ => panic!("unknown type specifier {specifier:?}"),
            }
        };
        for (char_pos, character) in format_string.char_indices() {
            match state {
                State::RawString { string_start } => {
                    if character == '%' {
                        // Print string, start format specifier
                        if char_pos - string_start > 0 {
                            write!(kernel_logger, "{}", &format_string[string_start..char_pos])
                                .unwrap();
                        }
                        state = State::FormatStart;
                        format_info = FormatInfo::default();
                    }
                }
                State::FormatStart => match character {
                    // Flags
                    '-' => {
                        state = State::Flags;
                        format_info.right_aligned = Some(false);
                    }
                    '0' => {
                        state = State::Flags;
                        format_info.fill_char = '0';
                    }
                    flag @ ('+' | ' ' | '#') => panic!("unimplemented flag {flag:?}"),
                    // Width
                    '1'..='9' => {
                        state = State::Width;
                        format_info.width = format_info.width * 10 + (character as usize - 48);
                    }
                    // Precision
                    '.' => {
                        state = State::Precision;
                        format_info.precision = Some(0);
                    }
                    // Type
                    specifier @ ('c' | 'C' | 'd' | 'i' | 'o' | 'u' | 'x' | 'X' | 'e' | 'E'
                    | 'f' | 'F' | 'g' | 'G' | 'a' | 'A' | 'n' | 'p' | 's' | 'S'
                    | 'Z') => {
                        print_type(specifier, format_info);
                        state = State::RawString {
                            string_start: char_pos + 1,
                        };
                        format_info = FormatInfo::default();
                    }
                    // Escape
                    '%' => {
                        state = State::RawString {
                            string_start: char_pos,
                        };
                        format_info = FormatInfo::default();
                    }
                    // Unexpected character
                    _ => panic!(
                        "malformed format specifier in format string {:?} - {:?} at position {}",
                        format_string, character, char_pos
                    ),
                },
                State::Flags => match character {
                    // Flags
                    '-' => format_info.right_aligned = Some(false),
                    '0' => format_info.fill_char = '0',
                    flag @ ('+' | ' ' | '#') => panic!("unimplemented flag {flag:?}"),
                    // Width
                    '1'..='9' => {
                        state = State::Width;
                        format_info.width = format_info.width * 10 + (character as usize - 48);
                    }
                    // Precision
                    '.' => {
                        state = State::Precision;
                        format_info.precision = Some(0);
                    }
                    // Type
                    specifier @ ('c' | 'C' | 'd' | 'i' | 'o' | 'u' | 'x' | 'X' | 'e' | 'E'
                    | 'f' | 'F' | 'g' | 'G' | 'a' | 'A' | 'n' | 'p' | 's' | 'S'
                    | 'Z') => {
                        print_type(specifier, format_info);
                        state = State::RawString {
                            string_start: char_pos + 1,
                        };
                        format_info = FormatInfo::default();
                    }
                    // Unexpected character
                    _ => panic!(
                        "malformed format specifier in format string {:?} - {:?} at position {}",
                        format_string, character, char_pos
                    ),
                },
                State::Width => match character {
                    // Width
                    '0'..='9' => {
                        format_info.width = format_info.width * 10 + (character as usize - 48)
                    }
                    // Precision
                    '.' => {
                        state = State::Precision;
                        format_info.precision = Some(0);
                    }
                    // Type
                    specifier @ ('c' | 'C' | 'd' | 'i' | 'o' | 'u' | 'x' | 'X' | 'e' | 'E'
                    | 'f' | 'F' | 'g' | 'G' | 'a' | 'A' | 'n' | 'p' | 's' | 'S'
                    | 'Z') => {
                        print_type(specifier, format_info);
                        state = State::RawString {
                            string_start: char_pos + 1,
                        };
                        format_info = FormatInfo::default();
                    }
                    // Unexpected character
                    _ => panic!(
                        "malformed format specifier in format string {:?} - {:?} at position {}",
                        format_string, character, char_pos
                    ),
                },
                State::Precision => match character {
                    // Precision
                    '0'..='9' => {
                        format_info.precision =
                            Some(format_info.precision.unwrap() * 10 + (character as usize - 48))
                    }
                    '*' => panic!("unimplemented precision specifier '*'"),
                    // Type
                    specifier @ ('c' | 'C' | 'd' | 'i' | 'o' | 'u' | 'x' | 'X' | 'e' | 'E'
                    | 'f' | 'F' | 'g' | 'G' | 'a' | 'A' | 'n' | 'p' | 's' | 'S'
                    | 'Z') => {
                        print_type(specifier, format_info);
                        state = State::RawString {
                            string_start: char_pos + 1,
                        };
                        format_info = FormatInfo::default();
                    }
                    // Unexpected character
                    _ => panic!(
                        "malformed format specifier in format string {:?} - {:?} at position {}",
                        format_string, character, char_pos
                    ),
                },
            }
        }
        // Check final state, print end of format string
        match state {
            State::RawString { string_start } => {
                if string_start < format_string.len() {
                    write!(kernel_logger, "{}", &format_string[string_start..]).unwrap();
                }
            }
            _ => panic!("invalid state {state:?} at end of printf format string"),
        }
    }
}

// TODO Replace dummy functions with proper implementations

#[unsafe(no_mangle)]
extern "C" fn AcpiOsGetThreadId() -> u64 {
    1
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsExecute(
    _execute_type: usize,
    _function: *const (),
    _context: *const (),
) -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsSleep(_: u64) {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsStall(_: u32) {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsWaitEventsComplete() {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsAcquireGlobalLock(_lock: *const u32) -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsReleaseGlobalLock(_lock: *const u32) -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsInstallInterruptHandler(
    _interrupt_level: u32,
    _handler: *const (),
    _context: *const (),
) -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsRemoveInterruptHandler(_interrupt_number: u32, _handler: *const ()) -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsReadMemory(_address: usize, _value: *const u64, _width: u32) -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsWriteMemory(_address: usize, _value: u64, _width: u32) -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsReadPort(_address: usize, _value: *const u32, _width: u32) -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsWritePort(_address: usize, _value: u32, _width: u32) -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsReadPciConfiguration() -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsWritePciConfiguration() -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsRedirectOutput(_destination: *const ()) -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsGetTimer() -> u64 {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsSignal(_function: u32, _info: *const ()) -> Status {
    unimplemented!();
}

#[unsafe(no_mangle)]
extern "C" fn AcpiOsEnterSleep(_sleep_state: u8, _rega_value: u32, _regb_value: u32) -> Status {
    unimplemented!();
}
