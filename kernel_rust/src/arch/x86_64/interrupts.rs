// TODO Rename to io_interrupts

use super::apic::io::{DeliveryMode, DestinationMode, IoApic, Polarity, TriggerMode};
use super::apic::local::{LocalApic, LocalApicRegister};
use super::platform::acpi::table::{Madt, MadtEntry};
use super::{idt, tls};
use alloc::vec::Vec;
use spin::Mutex;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Controller {
    Apic,
}

pub static ACTIVE_IO_INTERRUPT_SYSTEM: Mutex<Option<Controller>> = Mutex::new(None);

/// Signals to the interrupt controller that the interrupt handler has ended
pub fn signal_eoi() {
    unsafe {
        match *ACTIVE_IO_INTERRUPT_SYSTEM.lock() {
            Some(Controller::Apic) => (*tls::get_mut())
                .local_apic
                .apic
                .as_mut()
                .unwrap()
                .signal_eoi(),
            None => panic!("signal_eoi called with no active interrupt system"),
        }
    }
}

struct IoHandler {
    pub idt_entry: *mut idt::Entry<idt::HandlerFunc>,
    pub entry_index: u8,
}

unsafe impl Send for IoHandler {}

static LEGACY_IRQS: Mutex<[Option<IoHandler>; 16]> = Mutex::new([
    None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None,
]);

pub unsafe fn map_legacy_irq(irq: u8, handler: idt::HandlerFunc) {
    assert!(irq < 16);
    let mut legacy_irqs = LEGACY_IRQS.lock();
    let idt = &mut (*tls::get_mut()).idt;
    match *ACTIVE_IO_INTERRUPT_SYSTEM.lock() {
        Some(Controller::Apic) => {
            let index = apic::try_find_and_reserve_entry()
                .expect("APIC should have interrupt vectors available");
            idt.apic_interrupts[index as usize] =
                idt::Entry::with_handler_and_generic_stack(handler);
            apic::register_legacy_irq(irq, 128 + index);
            assert!(legacy_irqs[irq as usize].is_none());
            legacy_irqs[irq as usize] = Some(IoHandler {
                idt_entry: &mut idt.apic_interrupts[index as usize]
                    as *mut idt::Entry<idt::HandlerFunc>,
                entry_index: index,
            });
        }
        None => panic!("map_legacy_irq called with no active interrupt system"),
    }
}

pub unsafe fn unmap_legacy_id(irq: u8) {
    assert!(irq < 16);
    let mut legacy_irqs = LEGACY_IRQS.lock();
    match *ACTIVE_IO_INTERRUPT_SYSTEM.lock() {
        Some(Controller::Apic) => {
            let irq_info = legacy_irqs[irq as usize].take().unwrap();
            apic::unregister_legacy_irq(irq);
            apic::free_entry(irq_info.entry_index);
            unsafe {
                *irq_info.idt_entry = idt::Entry::missing();
            }
        }
        None => panic!("map_legacy_irq called with no active interrupt system"),
    }
}

pub unsafe fn scoped_map_legacy_irq(irq: u8, handler: idt::HandlerFunc) -> ScopedLegacyIrqMapping {
    map_legacy_irq(irq, handler);
    ScopedLegacyIrqMapping(irq)
}

#[repr(transparent)]
pub struct ScopedLegacyIrqMapping(u8);

impl Drop for ScopedLegacyIrqMapping {
    fn drop(&mut self) {
        unsafe {
            unmap_legacy_id(self.0);
        }
    }
}

pub mod apic {
    use super::{
        tls, Controller, DeliveryMode, DestinationMode, IoApic, LocalApic, LocalApicRegister, Madt,
        MadtEntry, Mutex, Polarity, TriggerMode, Vec, ACTIVE_IO_INTERRUPT_SYSTEM,
    };

    struct State {
        pub io_apics: Vec<IoApic>,
        pub interrupt_source_overrides: Vec<InterruptSourceOverride>,
        pub interrupt_vector_map: [u64; 2],
    }

    struct InterruptSourceOverride {
        pub _bus_source: u8,
        pub irq_source: u8,
        pub global_system_interrupt: u32,
        // TODO Standardise these as bitflags (check if ACPI and MP specs use different flags)
        pub flags: u16,
    }

    static STATE: Mutex<Option<State>> = Mutex::new(None);

    pub unsafe fn init_from_madt(madt: &Madt) {
        let mut io_apics = Vec::new();
        let mut interrupt_source_overrides = Vec::new();
        log::debug!("MADT found at {madt:p}");
        log::debug!("Enabling Local APIC at {:#x}", madt.bsp_local_apic_address);
        let mut bsp_apic = LocalApic::new(madt.bsp_local_apic_address as usize);
        bsp_apic.enable_bsp_local_apic();
        log::debug!("Local APIC enabled");
        (*tls::get_mut()).local_apic.apic = Some(bsp_apic);
        for entry in madt.entry_iter() {
            match entry {
                MadtEntry::IoApic {
                    io_apic_id,
                    io_apic_address,
                    global_system_interrupt_base,
                } => io_apics.push(IoApic::new(
                    io_apic_address as usize,
                    io_apic_id,
                    global_system_interrupt_base,
                )),
                MadtEntry::InterruptSourceOverride {
                    bus_source,
                    irq_source,
                    global_system_interrupt,
                    flags,
                } => interrupt_source_overrides.push(InterruptSourceOverride {
                    _bus_source: bus_source,
                    irq_source,
                    global_system_interrupt,
                    flags,
                }),
                _ => {}
            }
        }
        ACTIVE_IO_INTERRUPT_SYSTEM.lock().replace(Controller::Apic);
        *STATE.lock() = Some(State {
            io_apics,
            interrupt_source_overrides,
            interrupt_vector_map: [1 << 63, 0],
        });
    }

    // TODO Make this return an error instead of panicking
    /// Registers a legacy IRQ to be sent to `interrupt_vector` on the Local APIC
    pub unsafe fn register_legacy_irq(irq: u8, interrupt_vector: u8) {
        assert!(irq < 16);
        let mut state_lock = STATE.lock();
        let state = state_lock.as_mut().unwrap();
        let mut polarity = Polarity::High;
        let mut trigger_mode = TriggerMode::EdgeSensitive;
        let mut irq = irq as u32;
        if let Some(source_override) = state
            .interrupt_source_overrides
            .iter()
            .find(|source_override| source_override.irq_source as u32 == irq)
        {
            polarity = match source_override.flags & 2 != 0 {
                false => Polarity::High,
                true => Polarity::Low,
            };
            trigger_mode = match source_override.flags & 8 != 0 {
                false => TriggerMode::EdgeSensitive,
                true => TriggerMode::LevelSensitive,
            };
            assert!(source_override.global_system_interrupt <= 255);
            irq = source_override.global_system_interrupt;
        }
        let local_apic_id = (*tls::get())
            .local_apic
            .apic
            .as_ref()
            .unwrap()
            .read_register(LocalApicRegister::LapicId);
        assert!(local_apic_id < 256);
        // Set entry in I/O APIC
        for io_apic in &mut state.io_apics {
            let start_irq = io_apic.global_system_interrupt_base();
            let end_irq = start_irq + io_apic.num_redirection_entries() as u32;
            if start_irq <= irq && irq < end_irq {
                assert!(irq - start_irq <= 0x3F);
                let index = (irq - start_irq) as u8;
                let mut redirect = io_apic.read_redirection_entry(index);
                redirect.set_interrupt_vector(interrupt_vector);
                redirect.set_delivery_mode(DeliveryMode::Normal);
                redirect.set_destination_mode(DestinationMode::Physical);
                redirect.set_polarity(polarity);
                redirect.set_trigger_mode(trigger_mode);
                redirect.set_destination(local_apic_id as u8);
                redirect.set_masked(false);
                io_apic.write_redirection_entry(index, redirect);
                return;
            }
        }
        unreachable!();
    }

    pub unsafe fn unregister_legacy_irq(irq: u8) {
        let mut state_lock = STATE.lock();
        let state = state_lock.as_mut().unwrap();
        let irq = state
            .interrupt_source_overrides
            .iter()
            .find(|source_override| source_override.irq_source == irq)
            .map(|source_override| source_override.irq_source as u32)
            .unwrap_or(irq as u32);
        // Set entry in I/O APIC
        for io_apic in &mut state.io_apics {
            let start_irq = io_apic.global_system_interrupt_base();
            let end_irq = start_irq + io_apic.num_redirection_entries() as u32;
            if start_irq <= irq && irq < end_irq {
                assert!(irq - start_irq <= 0x3F);
                let index = (irq - start_irq) as u8;
                let mut redirect = io_apic.read_redirection_entry(index);
                redirect.set_interrupt_vector(0);
                redirect.set_destination(0);
                redirect.set_masked(true);
                io_apic.write_redirection_entry(index, redirect);
                return;
            }
        }
        unreachable!();
    }

    pub fn try_find_and_reserve_entry() -> Option<u8> {
        let mut state_lock = STATE.lock();
        let state = state_lock.as_mut().unwrap();
        for (group_index, group) in state.interrupt_vector_map.iter_mut().enumerate() {
            if *group != !0 {
                let index_in_group = group.leading_ones();
                *group |= (1 << 63) >> index_in_group;
                return Some(group_index as u8 + index_in_group as u8);
            }
        }
        None
    }

    pub fn free_entry(i: u8) {
        let mut state_lock = STATE.lock();
        let state = state_lock.as_mut().unwrap();
        let group_index = i as usize >> 6;
        let index_in_group = i & 0x3F;
        state.interrupt_vector_map[group_index] &= !((1 << 63) >> index_in_group);
    }
}
