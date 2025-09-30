use super::super::apic::local::{LocalApicRegister, TimerLvt, TimerMode};
use super::super::{idt, interrupts, tls};
use super::{InterruptType, MANAGER, TIMERS, Timer};
use core::arch::asm;

unsafe extern "x86-interrupt" fn sleep_handler(_interrupt_frame: idt::InterruptFrame) {
    unsafe {
        (*tls::get_mut()).local_apic.interrupt_received = true;
        (*tls::get_mut())
            .local_apic
            .apic
            .as_mut()
            .unwrap()
            .signal_eoi();
    }
}

pub unsafe fn calibrate() {
    unsafe {
        let local_apic_tls = &mut (*tls::get_mut()).local_apic;
        let local_apic = local_apic_tls.apic.as_mut().unwrap();
        // Divide by 16
        local_apic.write_register(LocalApicRegister::DivideConfiguration, 0b011);
        // Calibrate timer
        let time_slept = {
            let mut start_timer =
                || local_apic.write_register(LocalApicRegister::InitialCount, 0xFFFFFFFF);
            (MANAGER.lock().calibration_timer.calibration_sleep)(&mut start_timer)
        };
        let end_ticks = local_apic.read_register(LocalApicRegister::CurrentCount);
        let num_ticks = 0xFFFFFFFF - end_ticks;
        local_apic_tls.timer_us_numerator = num_ticks as usize;
        local_apic_tls.timer_us_denominator = time_slept as usize;
    }
}

pub unsafe fn setup() {
    unsafe {
        let local_apic_tls = &mut (*tls::get_mut()).local_apic;
        let local_apic = local_apic_tls.apic.as_mut().unwrap();
        let entry_index = interrupts::apic::try_find_and_reserve_entry().unwrap();
        local_apic_tls.interrupt_idt_index = Some(entry_index as usize);
        // Enable APIC one-shot timer_interrupts
        let mut timer_lvt =
            TimerLvt::from_u32(local_apic.read_register(LocalApicRegister::LvtTimer));
        timer_lvt.set_interrupt_vector(128 + entry_index);
        timer_lvt.set_masked(true);
        timer_lvt.set_timer_mode(TimerMode::OneShot);
        local_apic.write_register(LocalApicRegister::LvtTimer, timer_lvt.to_u32());
        local_apic.write_register(LocalApicRegister::DivideConfiguration, 0b011);
        local_apic.write_register(LocalApicRegister::InitialCount, 0xFFFFFFFF);
        TIMERS.lock().apic = true;
    }
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

unsafe fn set_interrupt_type(interrupt_type: &InterruptType) {
    unsafe {
        let entry_index = (*tls::get()).local_apic.interrupt_idt_index.unwrap();
        let interrupt_handler = match *interrupt_type {
            InterruptType::Sleep => sleep_handler,
            InterruptType::ContextSwitch => todo!(),
        };
        (*tls::get_mut()).idt.apic_interrupts[entry_index] =
            idt::Entry::with_handler_and_generic_stack(interrupt_handler);
    }
}

unsafe fn sleep_ms(time_ms: u32) {
    unsafe {
        {
            let time_us = time_ms as usize * 1000;
            // Calculate number of APIC timer ticks
            let local_apic_tls = &mut (*tls::get_mut()).local_apic;
            let local_apic = local_apic_tls.apic.as_mut().unwrap();
            let numerator = local_apic_tls.timer_us_numerator;
            let denominator = local_apic_tls.timer_us_denominator;
            let time_apic_ticks = ((numerator * time_us) / denominator) as u32;
            // Enable timer interrupts, set one shot mode
            let mut timer_lvt =
                TimerLvt::from_u32(local_apic.read_register(LocalApicRegister::LvtTimer));
            timer_lvt.set_masked(false);
            timer_lvt.set_timer_mode(TimerMode::OneShot);
            local_apic.write_register(LocalApicRegister::LvtTimer, timer_lvt.to_u32());
            // Request interrupt in requested number of ticks
            local_apic_tls.interrupt_received = false;
            local_apic.write_register(LocalApicRegister::InitialCount, time_apic_ticks);
        }
        // Wait for timer interrupt
        while !(*tls::get_mut()).local_apic.interrupt_received {
            asm!("sti; hlt; cli");
        }
        (*tls::get_mut()).local_apic.interrupt_received = false;
    }
}

// Countdown functions
unsafe fn start_countdown_ms(time_ms: u32) {
    unsafe {
        let time_us = time_ms as usize * 1000;
        // Calculate number of APIC timer ticks
        let local_apic_tls = &mut (*tls::get_mut()).local_apic;
        let local_apic = local_apic_tls.apic.as_mut().unwrap();
        let numerator = local_apic_tls.timer_us_numerator;
        let denominator = local_apic_tls.timer_us_denominator;
        let time_apic_ticks = ((numerator * time_us) / denominator) as u32;
        // Enable timer interrupts, set one shot mode
        let mut timer_lvt =
            TimerLvt::from_u32(local_apic.read_register(LocalApicRegister::LvtTimer));
        timer_lvt.set_masked(false);
        timer_lvt.set_timer_mode(TimerMode::OneShot);
        local_apic.write_register(LocalApicRegister::LvtTimer, timer_lvt.to_u32());
        // Request interrupt in requested number of ticks
        local_apic_tls.interrupt_received = false;
        local_apic.write_register(LocalApicRegister::InitialCount, time_apic_ticks);
    }
}

unsafe fn countdown_remaining_ms() -> u32 {
    unsafe {
        // Read current count, convert ticks to microseconds, then to milliseconds
        let local_apic_tls = &mut (*tls::get_mut()).local_apic;
        let local_apic = local_apic_tls.apic.as_mut().unwrap();
        let numerator = local_apic_tls.timer_us_numerator;
        let denominator = local_apic_tls.timer_us_denominator;
        let time_apic_ticks = local_apic.read_register(LocalApicRegister::CurrentCount) as usize;
        ((time_apic_ticks * denominator) / numerator / 1000) as u32
    }
}

unsafe fn countdown_ended() -> bool {
    unsafe { (*tls::get()).local_apic.interrupt_received }
}

unsafe fn stop_countdown() {
    unsafe {
        // Disable timer interrupts
        let local_apic = &mut (*tls::get_mut()).local_apic.apic.as_mut().unwrap();
        let mut timer_lvt =
            TimerLvt::from_u32(local_apic.read_register(LocalApicRegister::LvtTimer));
        timer_lvt.set_masked(true);
        local_apic.write_register(LocalApicRegister::LvtTimer, timer_lvt.to_u32());
    }
}

unsafe fn acknowledge_countdown_interrupt() {
    unsafe {
        (*tls::get_mut())
            .local_apic
            .apic
            .as_mut()
            .unwrap()
            .signal_eoi();
    }
}
