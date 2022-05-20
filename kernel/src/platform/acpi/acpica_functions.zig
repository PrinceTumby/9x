const acpi = @import("../acpi.zig");
const AcpiTableHeader = acpi.AcpiTableHeader;
const types = @import("acpica_types.zig");
const AcpiStatus = types.AcpiStatus;
const AcpiBoolean = types.AcpiBoolean;
const AcpiTableDesc = types.AcpiTableDesc;

// TODO Add descriptions and fix signatures

/// ACPICA subsystem initialisation and control
pub const subsystem = struct {
    // ACPICA function declarations
    extern fn AcpiInitializeSubsystem() u32;

    // Function wrappers

    /// Initializes the entire ACPICA subsystem, including OS services layer. Must be called
    /// before any of the other Acpi* interfaces are called (with the exception of the table
    /// manager interfaces, which can be called at any time).
    pub fn initialiseSubsystem() AcpiStatus {
        return @bitCast(AcpiStatus, AcpiInitializeSubsystem());
    }
};

pub const table_manager = struct {
    // ACPICA function declarations
    extern fn AcpiInitializeTables(
        initial_table_array: ?*AcpiTableDesc,
        initial_table_count: u32,
        allow_resize: AcpiBoolean,
    ) u32;
    extern fn AcpiReallocateRootTable() u32;
    extern fn AcpiFindRootPointer(table_address: usize) u32;
    extern fn AcpiInstallTable(address: u64, is_address_physical: AcpiBoolean) u32;
    extern fn AcpiLoadTables() u32;
    extern fn AcpiLoadTable(table: *c_void) u32;
    extern fn AcpiUnloadParentTable(object: *c_void) u32;
    extern fn AcpiGetTableHeader(
        signature: *const [4]u8,
        instance: u32,
        out_table_header: *AcpiTableHeader,
    ) u32;
    extern fn AcpiGetTable(
        signature: *const [4]u8,
        instance: u32,
        out_table: **c_void,
    ) u32;
    extern fn AcpiGetTableByIndex(table_index: u32, out_table: *?*AcpiTableHeader) u32;
    extern fn AcpiInstallTableHandler(handler: *c_void, context: *c_void) u32;
    extern fn AcpiRemoveTableHandler(handler: *c_void) u32;

    // Function wrappers

    pub fn initialiseTables(
        initial_table_array: ?*AcpiTableDesc,
        initial_table_count: u32,
        allow_resize: bool,
    ) AcpiStatus {
        return @bitCast(AcpiStatus, AcpiInitializeTables(
            initial_table_array,
            initial_table_count,
            AcpiBoolean.fromBool(allow_resize),
        ));
    }

    pub fn loadTables() AcpiStatus {
        return @bitCast(AcpiStatus, AcpiLoadTables());
    }

    pub fn getTable(
        comptime Table: type,
        /// One-based
        instance: u32,
        out_ptr: **Table,
    ) AcpiStatus {
        return @bitCast(AcpiStatus, AcpiGetTable(
            Table.table_signature,
            instance,
            @ptrCast(**c_void, out_ptr),
        ));
    }
};
