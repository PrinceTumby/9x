use super::CalibrationTimer;
use crate::arch::port;
use core::arch::asm;
use spin::Mutex;

pub mod register {
    pub const SECONDS: u8 = 0x0;
    pub const MINUTES: u8 = 0x2;
    pub const HOURS: u8 = 0x4;
    pub const WEEKDAY: u8 = 0x6;
    pub const DAY_OF_MONTH: u8 = 0x7;
    pub const MONTH: u8 = 0x8;
    pub const YEAR: u8 = 0x9;
    pub const STATUS_A: u8 = 0xA;
    pub const STATUS_B: u8 = 0xB;
    pub const STATUS_C: u8 = 0xC;
}

pub struct Cmos;

pub static CMOS: Mutex<Cmos> = Mutex::new(Cmos);

impl Cmos {
    pub unsafe fn read_byte(&self, disable_nmi: bool, register: u8) -> u8 {
        unsafe {
            let nmi_bit = (disable_nmi as u8) << 7;
            port::write_byte(port::CMOS_NMI_AND_REGISTER, register | nmi_bit);
            port::read_byte(port::CMOS_DATA)
        }
    }

    pub unsafe fn write_byte(&self, disable_nmi: bool, register: u8, byte: u8) {
        unsafe {
            let nmi_bit = (disable_nmi as u8) << 7;
            port::write_byte(port::CMOS_NMI_AND_REGISTER, register | nmi_bit);
            port::write_byte(port::CMOS_DATA, byte);
        }
    }
}

pub const CALIBRATION_TIMER: CalibrationTimer = CalibrationTimer { calibration_sleep };

unsafe fn calibration_sleep(start_timer: &mut dyn FnMut()) -> u32 {
    unsafe {
        let _cmos = CMOS.lock();
        // Wait until next second has just started
        asm!(
            "2:",
            "mov al, 0xA",
            "out 0x70, al",
            "in al, 0x71",
            "test al, 0x80",
            "jz 2b",
            "3:",
            "mov al, 0xA",
            "out 0x70, al",
            "in al, 0x71",
            "test al, 0x80",
            "jnz 3b",
            out("al") _,
            options(nomem, nostack),
        );
        // Run measurement function
        start_timer();
        // Wait until current second has ended
        asm!(
            "2:",
            "mov al, 0xA",
            "out 0x70, al",
            "in al, 0x71",
            "test al, 0x80",
            "jz 2b",
            "3:",
            "mov al, 0xA",
            "out 0x70, al",
            "in al, 0x71",
            "test al, 0x80",
            "jnz 3b",
            out("al") _,
            options(nomem, nostack),
        );
        1_000_000
    }
}
