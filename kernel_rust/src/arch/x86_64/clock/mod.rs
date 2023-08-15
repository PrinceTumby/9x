pub mod apic;
pub mod cmos;
pub mod rtc;

use spin::Mutex;

#[derive(Clone, Copy, Debug)]
pub enum Clock {
    Pit,
    Cmos,
    Rtc,
    Apic,
    Hpet,
    Tsc,
}

macro_rules! clock_from_name {
    (pit) => {
        Clock::Pit
    };
    (cmos) => {
        Clock::Cmos
    };
    (rtc) => {
        Clock::Rtc
    };
    (apic) => {
        Clock::Apic
    };
    (hpet) => {
        Clock::Hpet
    };
    (tsc) => {
        Clock::Tsc
    };
}

macro_rules! define_clock_list {
    ($list_name:ident, [ $( $clock_name:ident ),* $(,)? ]) => {
        pub struct $list_name {
            $(
                pub $clock_name: bool,
            )*
        }

        impl $list_name {
            pub fn get_preferred_clock(&self) -> Option<Clock> {
                $(
                    if self.$clock_name {
                        return Some(clock_from_name!($clock_name));
                    }
                )*
                None
            }
        }
    };
}

#[derive(Clone, Copy, Debug)]
pub enum InterruptType {
    Sleep,
    ContextSwitch,
}

// These were originally traits that the timers would implement, but compilation was missing code
// (not sure if compiler bug or programmer error). So we implement these manually as function
// tables instead.

#[derive(Clone, Copy)]
pub struct CalibrationTimer {
    pub calibration_sleep: unsafe fn(start_timer: &mut dyn FnMut()) -> u32,
}

#[derive(Clone, Copy)]
pub struct Timer {
    pub set_interrupt_type: unsafe fn(interrupt_type: &InterruptType),
    pub sleep_ms: unsafe fn(num_ms: u32),
    pub start_countdown_ms: unsafe fn(num_ms: u32),
    pub countdown_remaining_ms: unsafe fn() -> u32,
    pub countdown_ended: unsafe fn() -> bool,
    pub stop_countdown: unsafe fn(),
    pub acknowledge_countdown_interrupt: unsafe fn(),
}

// APIC is only ever true if the exact tick rate is able to be found via CPUID
define_clock_list!(CalibrationTimers, [hpet, apic, pit, rtc, cmos,]);
define_clock_list!(Timers, [apic, hpet, pit]);
#[rustfmt::skip]
define_clock_list!(Counters, [
    // True counters
    tsc,
    hpet,
    // Emulated counters
    apic,
    pit,
    rtc,
]);

pub static CALIBRATION_TIMERS: Mutex<CalibrationTimers> = Mutex::new(CalibrationTimers {
    hpet: false,
    apic: false,
    pit: false,
    rtc: true,
    cmos: true,
});
pub static TIMERS: Mutex<Timers> = Mutex::new(Timers {
    apic: false,
    hpet: false,
    pit: false,
});
pub static COUNTERS: Mutex<Counters> = Mutex::new(Counters {
    tsc: false,
    hpet: false,
    apic: false,
    pit: false,
    rtc: false,
});

// TODO Change unit of time from milliseconds to microseconds
pub struct Manager {
    pub calibration_timer: CalibrationTimer,
    pub timer: Timer,
}

pub static MANAGER: Mutex<Manager> = Mutex::new(Manager::new());

impl Manager {
    pub const fn new() -> Self {
        Self {
            calibration_timer: dummy_clock::CALIBRATION_TIMER,
            timer: dummy_clock::TIMER,
        }
    }

    pub fn update_clock_functions(
        &mut self,
        calibration_timers: &CalibrationTimers,
        timers: &Timers,
    ) {
        self.calibration_timer = match calibration_timers.get_preferred_clock() {
            None => dummy_clock::CALIBRATION_TIMER,
            Some(Clock::Rtc) => rtc::CALIBRATION_TIMER,
            Some(Clock::Cmos) => cmos::CALIBRATION_TIMER,
            Some(other) => unimplemented!("CalibrationTimer impl for Clock::{other:?}"),
        };
        self.timer = match timers.get_preferred_clock() {
            None => dummy_clock::TIMER,
            Some(Clock::Apic) => apic::TIMER,
            Some(other) => unimplemented!("Timer impl for `Clock::{other:?}`"),
        };
    }
}

mod dummy_clock {
    use super::{CalibrationTimer, InterruptType, Timer};

    pub const CALIBRATION_TIMER: CalibrationTimer = CalibrationTimer { calibration_sleep };

    unsafe fn calibration_sleep(_start_timer: &mut dyn FnMut()) -> u32 {
        unimplemented!();
    }

    pub const TIMER: Timer = Timer {
        set_interrupt_type,
        sleep_ms,
        start_countdown_ms,
        countdown_remaining_ms,
        countdown_ended,
        stop_countdown,
        acknowledge_countdown_interrupt,
    };

    unsafe fn set_interrupt_type(_interrupt_type: &InterruptType) {
        unimplemented!();
    }

    unsafe fn sleep_ms(_num_ms: u32) {
        unimplemented!();
    }

    unsafe fn start_countdown_ms(_num_ms: u32) {
        unimplemented!();
    }

    unsafe fn countdown_remaining_ms() -> u32 {
        unimplemented!();
    }

    unsafe fn countdown_ended() -> bool {
        unimplemented!();
    }

    unsafe fn stop_countdown() {
        unimplemented!();
    }

    unsafe fn acknowledge_countdown_interrupt() {
        unimplemented!();
    }
}
