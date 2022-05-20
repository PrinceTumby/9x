pub const acpica = @import("acpi/acpica.zig");

comptime {_ = @import("acpi/acpica.zig");}

const std = @import("std");
const root = @import("root");
const logging = root.logging;
const logger = std.log.scoped(.acpi);

pub const Rsdp = packed struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,
    length: u32,
    xsdt_address: u64,
    extended_checksum: u8,
    reserved: [3]u8,

    pub fn getXsdtPointer(self: *const Rsdp) *AcpiTableHeader {
        return @intToPtr(*AcpiTableHeader, self.xsdt_address);
    }
};

pub const AcpiTableHeader = packed struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

pub fn findTable(xsdt: *const AcpiTableHeader, comptime Table: type) ?*Table {
    const pointers = @intToPtr([*]align(4) const u64, @ptrToInt(xsdt) + 36);
    const pointers_slice = pointers[0 .. (xsdt.length - @sizeOf(AcpiTableHeader)) / 8];
    for (pointers_slice) |*pointer| {
        const table_pointer = @intToPtr(*AcpiTableHeader, pointer.*);
        logger.debug("table found:", .{});
        logger.debug("address {x}", .{pointer.*});
        // logging.logString(.debug, .acpi, "signature ", &table_pointer.signature);
        logger.debug("signature {s}", .{&table_pointer.signature});
        if (std.mem.eql(u8, &table_pointer.signature, Table.table_signature)) {
            return @ptrCast(*Table, table_pointer);
        }
    }
    return null;
}

// ACPI Tables

pub const Madt = packed struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
    bsp_local_apic_address: u32,
    flags: u32,

    pub const table_signature = "APIC";

    pub const EntryHeader = packed struct {
        entry_type: EntryType,
        entry_length: u8,
    };

    pub const EntryType = enum(u8) {
        LocalApic = 0,
        IoApic = 1,
        InterruptSourceOverride = 2,
        Nmi = 4,
        LocalApicAddressOverride = 5,
        _,
    };

    pub const entry = struct {
        pub const LocalApicEntry = packed struct {
            entry_type: EntryType = .LocalApic,
            entry_length: u8,
            acpi_processor_id: u8,
            apic_id: u8,
            flags: u32,
        };
        pub const IoApicEntry = packed struct {
            entry_type: EntryType = .IoApic,
            entry_length: u8,
            io_apic_id: u8,
            reserved: u8,
            io_apic_address: u32,
            global_system_interrupt_base: u32,
        };
        pub const InterruptSourceOverrideEntry = packed struct {
            entry_type: EntryType = .InterruptSourceOverride,
            entry_length: u8,
            bus_source: u8,
            irq_source: u8,
            global_system_interrupt: u32,
            flags: u16,
        };
        pub const NmiEntry = packed struct {
            entry_type: EntryType = .Nmi,
            entry_length: u8,
            acpi_processor_id: u8,
            flags: u16,
            lint: u8,
        };
        pub const LocalApicAddressOverrideEntry = packed struct {
            entry_type: EntryType = .LocalApicAddressOverride,
            entry_length: u8,
            reserved: u16,
            local_apic_physical_address: u64,
        };
    };

    pub fn getEndAddress(self: *const Madt) usize {
        // return @ptrToInt(self) + self.header.length;
        return @ptrToInt(self) + self.length;
    }
};

pub const Fadt = packed struct {
    // Standard ACPI header fields
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
    // FADT fields
    firmware_ctrl: u32,
    dsdt: u32,
    reserved: u8,
    preferred_power_management_profile: u8,
    sci_interrupt: u16,
    smi_command_port: u32,
    acpi_enable: u8,
    acpi_disable: u8,
    s4bios_req: u8,
    pstate_control: u8,
    pm1a_event_block: u32,
    pm1b_event_block: u32,
    pm1a_control_block: u32,
    pm1b_control_block: u32,
    pm2_control_block: u32,
    pm_timer_block: u32,
    gpe0_block: u32,
    gpe1_block: u32,
    pm1_event_length: u8,
    pm1_control_length: u8,
    pm2_control_length: u8,
    pm_timer_length: u8,
    gpe0_length: u8,
    gpe1_length: u8,
    gpe1_base: u8,
    cstate_control: u8,
    worst_c2_latency: u16,
    worst_c3_latency: u16,
    flush_size: u16,
    flush_stride: u16,
    duty_offset: u8,
    duty_width: u8,
    day_alarm: u8,
    month_alarm: u8,
    century: u8,
    arch_flags: u16,
    reserved_2: u8,
    flags: u32,
    reset_reg: GenericAddress,
    reset_value: u8,
    reserved_3: [3]u8,
    x_firmware_control: u64,
    x_dsdt: u64,
    x_pm1a_event_block: GenericAddress,
    x_pm1b_event_block: GenericAddress,
    x_pm1a_control_block: GenericAddress,
    x_pm1b_control_block: GenericAddress,
    x_pm2_control_block: GenericAddress,
    x_pm_timer_block: GenericAddress,
    x_gpe0_block: GenericAddress,
    x_gpe1_block: GenericAddress,

    pub const table_signature = "FACP";

    pub const GenericAddress = packed struct {
        address_space: AddressSpace,
        bit_width: u8,
        bit_offset: u8,
        access_size: AccessSize,
        address: u64,

        pub const AddressSpace = enum(u8) {
            SystemMemory = 0,
            SystemIo = 1,
            PciConfigurationSpace = 2,
            EmbeddedController = 3,
            SystemManagementBus = 4,
            SystemCmos = 5,
            PciDeviceBarTarget = 6,
            Ipmi = 7,
            Gpio = 8,
            GenericSerialBus = 9,
            PlatformCommunicationChannel = 10,
            _,
        };

        pub const AccessSize = enum(u8) {
            WidthByte = 1,
            Width16 = 2,
            Width32 = 3,
            Width64 = 4,
            _,
        };
    };

    pub const arch_flag_values = struct {
        /// Indicates that the motherboard supports user-visible devices
        /// on the LPC or ISA bus.
        pub const legacy_devices_present: u16 = 1;
        /// Indicates whether an 8042 compatible PS/2 controller is present.
        pub const ps2_8042_present: u16 = 1 << 1;
        /// If set, the OSPM must not probe for VGA hardware, which could cause
        /// machine check on this system. If clear, indicates VGA hardware is
        /// safe to probe.
        pub const vga_not_present: u16 = 1 << 2;
        /// If set, Message Signaled Interrupts must not be enabled on this
        /// system.
        pub const msi_not_supported: u16 = 1 << 3;
        /// If set, OSPM ASPM control must not be enabled on this system.
        pub const pcie_aspm_controls: u16 = 1 << 4;
        /// If set, the CMOS RTC is either not implemented, or does not exist
        /// at the standard addresses. The OSPM can use the Control Method Time
        /// and Alarm Namespace devices instead.
        pub const cmos_rtc_not_present: u16 = 1 << 5;
    };
};
