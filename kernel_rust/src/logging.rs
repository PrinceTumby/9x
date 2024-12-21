use crate::arch;
use crate::terminal;
use core::fmt::Write;
use log::{LevelFilter, Log, Metadata, Record};
use spin::Mutex;

/// Initialises the global logger wrapper. Can be called multiple times. This is not thread safe,
/// refer to the safety constraints of `log::set_logger_racy` for more details.
pub unsafe fn init_wrapper() {
    if !LOG_WRAPPER_INITIALISED {
        LOG_WRAPPER_INITIALISED = true;
        _ = log::set_logger_racy(&LOG_WRAPPER).map(|()| log::set_max_level(LevelFilter::Trace));
    }
}

static mut LOG_WRAPPER_INITIALISED: bool = false;
static LOG_WRAPPER: LogWrapper = LogWrapper;
pub static CURRENT_LOGGER: Mutex<Option<&'static dyn Log>> = Mutex::new(None);

struct LogWrapper;

impl log::Log for LogWrapper {
    fn enabled(&self, _metadata: &Metadata) -> bool {
        true
    }

    fn log(&self, record: &Record) {
        if let Some(logger) = CURRENT_LOGGER.lock().as_mut() {
            logger.log(record);
        }
    }

    fn flush(&self) {
        if let Some(logger) = CURRENT_LOGGER.lock().as_ref() {
            logger.flush();
        }
    }
}

pub static KERNEL_LOGGER: KernelLogger = KernelLogger;

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct KernelLogger;

macro_rules! impl_writers_func_body {
    ($write_fn: ident, $arg: ident) => {
        arch::debug_output::ArchWriter.$write_fn($arg)?;
        if let Some(terminal) = terminal::TERMINAL.lock().as_mut() {
            terminal.$write_fn($arg)?;
        }
        return Ok(());
    };
}

impl core::fmt::Write for KernelLogger {
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

impl log::Log for KernelLogger {
    fn enabled(&self, _metadata: &Metadata) -> bool {
        true
    }

    fn log(&self, record: &Record) {
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
