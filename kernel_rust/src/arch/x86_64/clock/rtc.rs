use super::super::{idt, interrupts, tls};
use super::{CalibrationTimer, cmos};
use core::arch::asm;
use spin::Mutex;

pub struct Rtc;

pub static RTC: Mutex<Rtc> = Mutex::new(Rtc);

static mut INTERRUPT_RECEIVED: bool = true;

impl Rtc {
    unsafe extern "x86-interrupt" fn sleep_handler_apic(_interrupt_frame: idt::InterruptFrame) {
        unsafe {
            INTERRUPT_RECEIVED = true;
            (*tls::get_mut())
                .local_apic
                .apic
                .as_mut()
                .unwrap()
                .signal_eoi();
        }
    }
}

pub const CALIBRATION_TIMER: CalibrationTimer = CalibrationTimer { calibration_sleep };

/// Calls `startTimer`, sleeps for an arbitrary amount of time, then returns the
/// number of microseconds slept. Used for calibrating other clocks at startup.
/// The RTC must not be mapped to an IRQ or be in use.
unsafe fn calibration_sleep(start_timer: &mut dyn FnMut()) -> u32 {
    unsafe {
        let cmos = cmos::CMOS.lock();
        // Ensure interrupts are disabled (paranoid check, but interrupts must NEVER happen
        // during RTC setup)
        asm!("cli");
        // Map RTC IRQ temporarily
        let _handler_mapping = interrupts::scoped_map_legacy_irq(8, Rtc::sleep_handler_apic);
        // Output divider of 12 generates interrupts at 16Hz (nice factor of 1_000_000)
        const RATE: u8 = 12;
        // Read old values from A and B registers, disable NMI
        let previous_a = cmos.read_byte(true, cmos::register::STATUS_A);
        let previous_b = cmos.read_byte(true, cmos::register::STATUS_B);
        // Compute new A register value
        // Take top 4 bits of old value, add bottom 4 rate bits
        let new_a = (previous_a & 0xF0) | RATE;
        // Compute new B register value
        let new_b_interrupt = previous_b | 0x40;
        // Compute B register value for disabling interrupts
        let new_b_no_interrupt = previous_b & 0xBF;
        // Reset interrupt received indicator
        INTERRUPT_RECEIVED = false;
        // Write out rate to A register
        cmos.write_byte(true, cmos::register::STATUS_A, new_a);
        // Enable periodic interrupts on B register
        cmos.write_byte(true, cmos::register::STATUS_B, new_b_interrupt);
        // Flush C register
        cmos.read_byte(true, cmos::register::STATUS_C);
        // Wait for next timer IRQ
        while !INTERRUPT_RECEIVED {
            asm!("sti; hlt; cli");
        }
        // Start timer calibration
        start_timer();
        // Flush C register, required every time timer IRQ is received
        cmos.read_byte(true, cmos::register::STATUS_C);
        // Reset interrupt received indicator
        INTERRUPT_RECEIVED = false;
        // Wait until timer indicates end of sleep period
        while !INTERRUPT_RECEIVED {
            asm!("sti; hlt; cli");
        }
        // Disable timer IRQs
        cmos.write_byte(true, cmos::register::STATUS_B, new_b_no_interrupt);
        // Flush C register again, enable NMI
        cmos.read_byte(false, cmos::register::STATUS_C);
        // Reset interrupt received indicator again
        INTERRUPT_RECEIVED = false;
        // Return number of microseconds slept for
        const FREQUENCY: u32 = 32_768 >> (RATE as u32 - 1);
        1_000_000 / FREQUENCY
    }
}
