use super::page_allocation;
use super::paging::PageTableEntry;
use crate::LOCAL_APIC_BASE;
use core::arch::asm;

pub mod local {
    use super::{asm, page_allocation, PageTableEntry, LOCAL_APIC_BASE};

    #[repr(transparent)]
    pub struct LocalApic(usize);

    impl LocalApic {
        pub unsafe fn new(base_address: usize) -> Self {
            let higher_half_address = &LOCAL_APIC_BASE as *const usize as usize;
            // Map Local APIC in higher half so it can be accessed when we swap out the lower half
            // of the address space for processes
            page_allocation::map_page_translation(
                base_address,
                higher_half_address,
                PageTableEntry::READ_WRITE,
            )
            .expect("out of memory when mapping Local APIC page");
            Self(higher_half_address)
        }

        pub fn enable_bsp_local_apic(&mut self) {
            unsafe {
                asm!(
                    // -- Disable PIC --
                    // PIC initialisation sequence
                    "mov al, 0x11",
                    "out 0x20, al",
                    "out 0xA0, al",
                    // Master PIC vector offset
                    "mov al, 0x20",
                    "out 0x21, al",
                    // Slave PIC vector offset
                    "mov al, 0x28",
                    "out 0xA1, al",
                    // Inform Master PIC of Slave PIC at IRQ2
                    "mov al, 0x04",
                    "out 0x21, al",
                    // Tell Slave PIC cascade identity
                    "mov al, 0x02",
                    "out 0xA1, al",
                    // Set 8086 mode
                    "mov al, 0x01",
                    "out 0x21, al",
                    "out 0xA1, al",
                    // Mask all interrupts
                    "mov al, 0xFF",
                    "out 0xA1, al",
                    "out 0x21, al",
                    // -- Enable Local APIC --
                    "mov ecx, 0x1B",
                    "rdmsr",
                    "or eax, 0x800",
                    "wrmsr",
                    out("eax") _,
                    out("ecx") _,
                    out("edx") _,
                    options(nomem, nostack),
                );
            }
            // Remap APIC Spurious Interrupt Vector Register to 0xFF and enable
            self.write_register(LocalApicRegister::SpuriousInterruptVector, 0x1FF);
        }

        /// Panics if the register is not readable
        #[inline]
        pub fn read_register(&self, register: LocalApicRegister) -> u32 {
            let reg_props = register.get_properties();
            assert!(reg_props.1, "register {register:?} is not readable");
            unsafe { ((self.0 + reg_props.0) as *const u32).read_volatile() }
        }

        /// Panics if the register is not writable
        #[inline]
        pub fn write_register(&mut self, register: LocalApicRegister, value: u32) {
            let reg_props = register.get_properties();
            assert!(reg_props.2, "register {register:?} is not writable");
            unsafe { ((self.0 + reg_props.0) as *mut u32).write_volatile(value) }
        }

        pub fn signal_eoi(&mut self) {
            self.write_register(LocalApicRegister::Eoi, 0);
        }
    }

    #[derive(Clone, Copy, Debug)]
    pub enum LocalApicRegister {
        LapicId,
        LapicVersion,
        TaskPriority,
        ArbitrationPriority,
        ProcessorPriority,
        Eoi,
        RemoteRead,
        LogicalDestination,
        DestinationFormat,
        SpuriousInterruptVector,
        ErrorStatus,
        LvtCmci,
        LvtTimer,
        LvtThermalSensor,
        LvtPerfMonitoringCounters,
        LvtLint0,
        LvtLint1,
        LvtError,
        InitialCount,
        CurrentCount,
        DivideConfiguration,
    }

    impl LocalApicRegister {
        /// Returns properties (offset, read allowed, write allowed) for a given register
        #[inline]
        pub const fn get_properties(&self) -> (usize, bool, bool) {
            match self {
                Self::LapicId => (0x20, true, true),
                Self::LapicVersion => (0x30, true, false),
                Self::TaskPriority => (0x80, true, true),
                Self::ArbitrationPriority => (0x90, true, false),
                Self::ProcessorPriority => (0xA0, true, false),
                Self::Eoi => (0xB0, false, true),
                Self::RemoteRead => (0xC0, true, false),
                Self::LogicalDestination => (0xD0, true, true),
                Self::DestinationFormat => (0xE0, true, true),
                Self::SpuriousInterruptVector => (0xF0, true, true),
                Self::ErrorStatus => (0x280, true, false),
                Self::LvtCmci => (0x2F0, true, true),
                Self::LvtTimer => (0x320, true, true),
                Self::LvtThermalSensor => (0x330, true, true),
                Self::LvtPerfMonitoringCounters => (0x340, true, true),
                Self::LvtLint0 => (0x350, true, true),
                Self::LvtLint1 => (0x360, true, true),
                Self::LvtError => (0x370, true, true),
                Self::InitialCount => (0x380, true, true),
                Self::CurrentCount => (0x390, true, false),
                Self::DivideConfiguration => (0x3E0, true, true),
            }
        }
    }

    bitfield::bitfield! {
        #[derive(Clone, Copy)]
        #[repr(transparent)]
        pub struct TimerLvt(u32);
        u8;
        pub interrupt_vector, set_interrupt_vector: 7, 0;
        pub interrupt_pending, _: 12;
        pub masked, set_masked: 16;
        timer_mode_u4, set_timer_mode_u4: 18, 17;
    }

    impl TimerLvt {
        pub fn from_u32(raw_lvt: u32) -> Self {
            Self(raw_lvt)
        }

        pub fn to_u32(&self) -> u32 {
            self.0
        }

        pub fn timer_mode(&self) -> TimerMode {
            match self.timer_mode_u4() {
                0 => TimerMode::OneShot,
                1 => TimerMode::Periodic,
                2 => TimerMode::TscDeadline,
                3 => TimerMode::Reserved,
                _ => unreachable!(),
            }
        }

        pub fn set_timer_mode(&mut self, mode: TimerMode) {
            self.set_timer_mode_u4(mode as u8);
        }
    }

    #[derive(Clone, Copy)]
    #[repr(u8)]
    pub enum TimerMode {
        OneShot = 0,
        Periodic = 1,
        TscDeadline = 2,
        Reserved = 3,
    }
}

pub mod io {
    use super::{page_allocation, PageTableEntry};

    pub struct IoApic {
        base_address: usize,
        _id: u8,
        global_system_interrupt_base: u32,
        num_redirection_entries: u16,
    }

    impl IoApic {
        pub unsafe fn new(base_address: usize, id: u8, global_system_interrupt_base: u32) -> Self {
            if !page_allocation::is_address_identity_mapped(base_address) {
                page_allocation::map_page_translation(
                    base_address,
                    base_address,
                    PageTableEntry::READ_WRITE,
                )
                .expect("out of memory when mapping IO APIC page");
            }
            let mut io_apic = Self {
                base_address,
                _id: id,
                global_system_interrupt_base,
                num_redirection_entries: 0,
            };
            let num_redirection_entries =
                io_apic.read_register(IoApicRegister::NumRedirectionEntries) as u16;
            assert!(num_redirection_entries < 0x3F);
            log::debug!("I/O APIC {id} has {num_redirection_entries} redirection entries");
            io_apic.num_redirection_entries = num_redirection_entries;
            io_apic
        }

        #[inline]
        pub fn global_system_interrupt_base(&self) -> u32 {
            self.global_system_interrupt_base
        }

        #[inline]
        pub fn num_redirection_entries(&self) -> u16 {
            self.num_redirection_entries
        }

        /// Panics if the register is not readable
        #[inline]
        pub fn read_register(&mut self, register: IoApicRegister) -> u32 {
            let reg_props = register.get_properties();
            assert!(reg_props.1, "register {register:?} is not readable");
            unsafe {
                // Write register index to selection register
                (self.base_address as *mut u32).write_volatile(reg_props.0);
                // Read value from register window
                ((self.base_address + 0x10) as *const u32).read_volatile()
            }
        }

        /// Panics if the register is not writable
        #[inline]
        pub fn write_register(&mut self, register: IoApicRegister, value: u32) {
            let reg_props = register.get_properties();
            assert!(reg_props.2, "register {register:?} is not writable");
            unsafe {
                // Write register index to selection register
                (self.base_address as *mut u32).write_volatile(reg_props.0);
                // Write value to register window
                ((self.base_address + 0x10) as *mut u32).write_volatile(value);
            }
        }

        pub fn read_redirection_entry(&mut self, i: u8) -> RedirectionEntry {
            assert!((i as u16) < self.num_redirection_entries);
            let register_start_index = i * 2 + 0x10;
            // Read both entry halves, combine into redirection entry
            unsafe {
                // Same procedure as read_register
                (self.base_address as *mut u32).write_volatile(register_start_index as u32);
                let lower = ((self.base_address + 0x10) as *const u32).read_volatile();
                (self.base_address as *mut u32).write_volatile(register_start_index as u32 + 1);
                let upper = ((self.base_address + 0x10) as *const u32).read_volatile();
                RedirectionEntry::from_u64((upper as u64) << 32 | lower as u64)
            }
        }

        pub fn write_redirection_entry(&mut self, i: u8, entry: RedirectionEntry) {
            assert!((i as u16) < self.num_redirection_entries);
            let register_start_index = i * 2 + 0x10;
            // Split into halves, write each separately
            let entry_u64 = entry.to_u64();
            let (lower, upper) = (entry_u64 as u32, (entry_u64 >> 32) as u32);
            unsafe {
                // Same procedure as write_register
                (self.base_address as *mut u32).write_volatile(register_start_index as u32);
                ((self.base_address + 0x10) as *mut u32).write_volatile(lower);
                (self.base_address as *mut u32).write_volatile(register_start_index as u32 + 1);
                ((self.base_address + 0x10) as *mut u32).write_volatile(upper);
            }
        }
    }

    #[derive(Clone, Copy, Debug)]
    #[repr(u32)]
    pub enum IoApicRegister {
        Id = 0,
        NumRedirectionEntries = 1,
        ArbitrationPriority = 2,
    }

    impl IoApicRegister {
        /// Returns properties (index, read allowed, write allowed) for a given register
        #[inline]
        pub const fn get_properties(&self) -> (u32, bool, bool) {
            match self {
                Self::Id => (*self as u32, true, true),
                Self::NumRedirectionEntries => (*self as u32, true, false),
                Self::ArbitrationPriority => (*self as u32, true, false),
            }
        }
    }

    bitfield::bitfield! {
        #[derive(Clone, Copy)]
        #[repr(transparent)]
        pub struct RedirectionEntry(u64);
        u8;
        pub interrupt_vector, set_interrupt_vector: 7, 0;
        delivery_mode_u3, set_delivery_mode_u3: 10, 8;
        destination_mode_bool, set_destination_mode_bool: 11;
        pub interrupt_pending, _: 12;
        polarity_bool, set_polarity_bool: 13;
        level_triggered_interrupt_status_bool, set_level_triggered_interrupt_status_bool: 14;
        trigger_mode_bool, set_trigger_mode_bool: 15;
        pub masked, set_masked: 16;
        pub destination, set_destination: 63, 56;
    }

    impl RedirectionEntry {
        pub fn from_u64(raw_entry: u64) -> Self {
            Self(raw_entry)
        }

        pub fn to_u64(&self) -> u64 {
            self.0
        }

        pub fn delivery_mode(&self) -> DeliveryMode {
            match self.delivery_mode_u3() {
                0 => DeliveryMode::Normal,
                1 => DeliveryMode::LowPriority,
                2 => DeliveryMode::SystemManagementInterrupt,
                3 => {
                    log::warn!("Unknown I/O APIC delivery mode constructed - 3");
                    DeliveryMode::Unknown1
                }
                4 => DeliveryMode::NonMaskableInterrupt,
                5 => DeliveryMode::Init,
                6 => {
                    log::warn!("Unknown I/O APIC delivery mode constructed - 6");
                    DeliveryMode::Unknown1
                }
                7 => DeliveryMode::External,
                _ => unreachable!(),
            }
        }

        pub fn set_delivery_mode(&mut self, value: DeliveryMode) {
            self.set_delivery_mode_u3(value as u8);
        }

        pub fn destination_mode(&self) -> DestinationMode {
            match self.destination_mode_bool() {
                false => DestinationMode::Physical,
                true => DestinationMode::Logical,
            }
        }

        pub fn set_destination_mode(&mut self, value: DestinationMode) {
            self.set_destination_mode_bool(value as usize == 1);
        }

        pub fn polarity(&self) -> Polarity {
            match self.polarity_bool() {
                false => Polarity::High,
                true => Polarity::Low,
            }
        }

        pub fn set_polarity(&mut self, value: Polarity) {
            self.set_polarity_bool(value as usize == 1);
        }

        pub fn level_triggered_interrupt_status(&self) -> LevelTriggeredInterruptStatus {
            match self.level_triggered_interrupt_status_bool() {
                false => LevelTriggeredInterruptStatus::EoiSent,
                true => LevelTriggeredInterruptStatus::InterruptReceived,
            }
        }

        pub fn set_level_triggered_interrupt_status(
            &mut self,
            value: LevelTriggeredInterruptStatus,
        ) {
            self.set_level_triggered_interrupt_status_bool(value as usize == 1);
        }

        pub fn trigger_mode(&self) -> TriggerMode {
            match self.trigger_mode_bool() {
                false => TriggerMode::EdgeSensitive,
                true => TriggerMode::LevelSensitive,
            }
        }

        pub fn set_trigger_mode(&mut self, value: TriggerMode) {
            self.set_trigger_mode_bool(value as usize == 1);
        }
    }

    #[derive(Clone, Copy, Debug)]
    #[repr(u8)]
    pub enum DeliveryMode {
        Normal = 0,
        LowPriority = 1,
        SystemManagementInterrupt = 2,
        Unknown1 = 3,
        NonMaskableInterrupt = 4,
        Init = 5,
        Unknown2 = 6,
        External = 7,
    }

    #[derive(Clone, Copy, Debug)]
    pub enum DestinationMode {
        Physical = 0,
        Logical = 1,
    }

    #[derive(Clone, Copy, Debug)]
    pub enum Polarity {
        High = 0,
        Low = 1,
    }

    #[derive(Clone, Copy, Debug)]
    pub enum LevelTriggeredInterruptStatus {
        EoiSent = 0,
        InterruptReceived = 1,
    }

    #[derive(Clone, Copy, Debug)]
    pub enum TriggerMode {
        EdgeSensitive = 0,
        LevelSensitive = 1,
    }
}
