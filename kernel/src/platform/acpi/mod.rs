mod acpica_os_layer;
mod acpica_sys;

#[derive(Clone, Copy, Debug)]
pub struct AcpiError {
    pub code: AcpiErrorCode,
    pub exception: u16,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AcpiErrorCode {
    Environment = 0,
    Programmer = 1,
    AcpiTable = 2,
    Aml = 3,
    Control = 4,
    Unknown,
}

impl From<u16> for AcpiErrorCode {
    fn from(val: u16) -> Self {
        match val {
            0 => Self::Environment,
            1 => Self::Programmer,
            2 => Self::AcpiTable,
            3 => Self::Aml,
            4 => Self::Control,
            _ => Self::Unknown,
        }
    }
}

impl From<acpica_sys::Status> for Result<(), AcpiError> {
    fn from(status: acpica_sys::Status) -> Self {
        let code = AcpiErrorCode::from(status.code());
        let exception = status.exception();
        if code == AcpiErrorCode::Environment && exception == 0 {
            Ok(())
        } else {
            Err(AcpiError { code, exception })
        }
    }
}

/// Must only be called once.
pub unsafe fn init_subsystem(acpi_ptr: Option<core::ptr::NonNull<()>>) -> Result<(), AcpiError> {
    if let Some(acpi_ptr) = acpi_ptr {
        *acpica_os_layer::RSDP_ADDRESS.lock() = acpi_ptr.as_ptr() as usize;
    }
    unsafe { acpica_sys::subsystem::initialise().into() }
}

pub mod table {
    use super::*;

    /// Must only be called once, after `acpi::init_subsystem`.
    pub unsafe fn init_manager() -> Result<(), AcpiError> {
        unsafe { acpica_sys::table_manager::initialise(None, 16, false.into()).into() }
    }

    pub unsafe fn get<T: Table>() -> Result<&'static T, AcpiError> {
        unsafe {
            let mut table: *const () = core::ptr::null();
            <Result<(), AcpiError>>::from(acpica_sys::table_manager::get_table(
                &T::SIGNATURE,
                1,
                &mut table,
            ))?;
            Ok(&*(table as *const T))
        }
    }

    pub trait Table {
        const SIGNATURE: [u8; 4];
    }

    #[repr(C)]
    pub struct Madt {
        _signature: [u8; 4],
        length: u32,
        _revision: u8,
        _checksum: u8,
        _oem_id: [u8; 6],
        _oem_table_id: [u8; 8],
        _oem_revision: u32,
        _creator_id: u32,
        _creator_revision: u32,
        pub bsp_local_apic_address: u32,
        pub flags: u32,
    }

    impl Table for Madt {
        const SIGNATURE: [u8; 4] = *b"APIC";
    }

    impl Madt {
        pub unsafe fn entry_iter(&self) -> MadtEntryIterator {
            unsafe {
                MadtEntryIterator {
                    current_header: (self as *const Self).offset(1) as *const MadtEntryHeader,
                    end_address: (self as *const Self as usize) + self.length as usize - 1,
                }
            }
        }
    }

    #[derive(Clone, Copy, Debug)]
    pub enum MadtEntry {
        LocalApic {
            acpi_processor_id: u8,
            apic_id: u8,
            flags: u32,
        },
        IoApic {
            io_apic_id: u8,
            io_apic_address: u32,
            global_system_interrupt_base: u32,
        },
        InterruptSourceOverride {
            bus_source: u8,
            irq_source: u8,
            global_system_interrupt: u32,
            flags: u16,
        },
        Nmi {
            acpi_processor_id: u8,
            flags: u16,
            lint: u8,
        },
        LocalApicAddressOverride(u64),
    }

    pub struct MadtEntryIterator {
        current_header: *const MadtEntryHeader,
        end_address: usize,
    }

    impl Iterator for MadtEntryIterator {
        type Item = MadtEntry;

        fn next(&mut self) -> Option<Self::Item> {
            // Check if we've reached the end of the entries
            if self.current_header as usize >= self.end_address {
                return None;
            }
            let header = unsafe { &*self.current_header };
            // Bump header pointer by length
            let header_address = self.current_header as usize;
            let header_length = header.entry_length as usize;
            self.current_header = (header_address + header_length) as *const MadtEntryHeader;
            // Determine entry type, pull out data to enum
            match header.entry_type {
                MadtEntryType::LOCAL_APIC => {
                    let entry =
                        unsafe { &*(header as *const MadtEntryHeader as *const LocalApicEntry) };
                    Some(MadtEntry::LocalApic {
                        acpi_processor_id: entry.acpi_processor_id,
                        apic_id: entry.apic_id,
                        flags: entry.flags,
                    })
                }
                MadtEntryType::IO_APIC => {
                    let entry =
                        unsafe { &*(header as *const MadtEntryHeader as *const IoApicEntry) };
                    Some(MadtEntry::IoApic {
                        io_apic_id: entry.io_apic_id,
                        io_apic_address: entry.io_apic_address,
                        global_system_interrupt_base: entry.global_system_interrupt_base,
                    })
                }
                MadtEntryType::INTERRUPT_SOURCE_OVERRIDE => {
                    let entry = unsafe {
                        &*(header as *const MadtEntryHeader as *const InterruptSourceOverrideEntry)
                    };
                    Some(MadtEntry::InterruptSourceOverride {
                        bus_source: entry.bus_source,
                        irq_source: entry.irq_source,
                        global_system_interrupt: entry.global_system_interrupt,
                        flags: entry.flags,
                    })
                }
                MadtEntryType::NMI => {
                    let entry =
                        unsafe { &*(header as *const MadtEntryHeader as *const LocalApicNmiEntry) };
                    Some(MadtEntry::Nmi {
                        acpi_processor_id: entry.acpi_processor_id,
                        flags: entry.flags,
                        lint: entry.lint,
                    })
                }
                MadtEntryType::LOCAL_APIC_ADDRESS_OVERRIDE => {
                    let entry = unsafe {
                        &*(header as *const MadtEntryHeader as *const LocalApicAddressOverrideEntry)
                    };
                    Some(MadtEntry::LocalApicAddressOverride(
                        entry.local_apic_physical_address,
                    ))
                }
                // Skip over unknown entry types
                unknown => {
                    log::debug!("Unknown MADT entry type: {unknown:?}");
                    self.next()
                }
            }
        }
    }

    #[repr(transparent)]
    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    struct MadtEntryType(pub u8);

    impl MadtEntryType {
        pub const LOCAL_APIC: MadtEntryType = MadtEntryType(0);
        pub const IO_APIC: MadtEntryType = MadtEntryType(1);
        pub const INTERRUPT_SOURCE_OVERRIDE: MadtEntryType = MadtEntryType(2);
        pub const NMI: MadtEntryType = MadtEntryType(4);
        pub const LOCAL_APIC_ADDRESS_OVERRIDE: MadtEntryType = MadtEntryType(5);
    }

    #[repr(C, packed)]
    struct MadtEntryHeader {
        pub entry_type: MadtEntryType,
        pub entry_length: u8,
    }

    #[repr(C, packed)]
    struct LocalApicEntry {
        _header: MadtEntryHeader,
        pub acpi_processor_id: u8,
        pub apic_id: u8,
        pub flags: u32,
    }

    #[repr(C, packed)]
    struct IoApicEntry {
        _header: MadtEntryHeader,
        pub io_apic_id: u8,
        _reserved: u8,
        pub io_apic_address: u32,
        pub global_system_interrupt_base: u32,
    }

    #[repr(C, packed)]
    struct InterruptSourceOverrideEntry {
        _header: MadtEntryHeader,
        pub bus_source: u8,
        pub irq_source: u8,
        pub global_system_interrupt: u32,
        pub flags: u16,
    }

    #[repr(C, packed)]
    struct LocalApicNmiEntry {
        _header: MadtEntryHeader,
        pub acpi_processor_id: u8,
        pub flags: u16,
        pub lint: u8,
    }

    #[repr(C, packed)]
    struct LocalApicAddressOverrideEntry {
        _header: MadtEntryHeader,
        _reserved: u16,
        pub local_apic_physical_address: u64,
    }
}
