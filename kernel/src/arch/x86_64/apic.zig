const std = @import("std");
const root = @import("root");
const assertEqual = root.misc.assertEqual;
const page_allocator = @import("page_allocation.zig").page_allocator_ptr;
const heap_allocator = root.heap.heap_allocator_ptr;
const logging = root.logging;
const logger = std.log.scoped(.x86_64_apic);

pub const LocalApic = struct {
    base_address: usize,

    pub const Register = struct {
        offset: usize,
        read_allowed: bool,
        write_allowed: bool,
    };

    pub const registers = struct {
        pub const LapicIdRegister = Register{
            .offset = 0x20,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const LapicVersionRegister = Register{
            .offset = 0x30,
            .read_allowed = true,
            .write_allowed = false,
        };
        pub const TaskPriorityRegister = Register{
            .offset = 0x80,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const ArbitrationPriorityRegister = Register{
            .offset = 0x90,
            .read_allowed = true,
            .write_allowed = false,
        };
        pub const ProcessorPriorityRegister = Register{
            .offset = 0xA0,
            .read_allowed = true,
            .write_allowed = false,
        };
        pub const EoiRegister = Register{
            .offset = 0xB0,
            .read_allowed = false,
            .write_allowed = true,
        };
        pub const RemoteReadRegister = Register{
            .offset = 0xC0,
            .read_allowed = true,
            .write_allowed = false,
        };
        pub const LogicalDestinationRegister = Register{
            .offset = 0xD0,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const DestinationFormatRegister = Register{
            .offset = 0xE0,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const SpuriousInterruptVectorRegister = Register{
            .offset = 0xF0,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const ErrorStatusRegister = Register{
            .offset = 0x280,
            .read_allowed = true,
            .write_allowed = false,
        };
        pub const LvtCmciRegister = Register{
            .offset = 0x2F0,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const LvtTimerRegister = Register{
            .offset = 0x320,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const LvtThermalSensorRegister = Register{
            .offset = 0x330,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const LvtPerformanceMonitoringCountersRegister = Register{
            .offset = 0x340,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const LvtLint0Register = Register{
            .offset = 0x350,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const LvtLint1Register = Register{
            .offset = 0x360,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const LvtErrorRegister = Register{
            .offset = 0x370,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const InitialCountRegister = Register{
            .offset = 0x380,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const CurrentCountRegister = Register{
            .offset = 0x390,
            .read_allowed = true,
            .write_allowed = false,
        };
        pub const DivideConfigurationRegister = Register{
            .offset = 0x3E0,
            .read_allowed = true,
            .write_allowed = true,
        };
    };

    pub const TimerLvt = packed struct {
        interrupt_vector: u8,
        reserved_1: u4 = 0,
        interrupt_pending: bool = false,
        reserved_2: u3 = 0,
        mask: bool = false,
        timer_mode: TimerMode,
        reserved_3: u13 = 0,

        pub const TimerMode = packed enum(u2) {
            OneShot = 0,
            Periodic = 1,
            TscDeadline = 2,
            Reserved = 3,
        };

        pub fn fromU32(raw: u32) TimerLvt {
            return @bitCast(TimerLvt, raw);
        }

        pub fn toU32(self: TimerLvt) u32 {
            return @bitCast(u32, self);
        }

        comptime {
            assertEqual(@sizeOf(@This()), 4);
            assertEqual(@bitSizeOf(@This()), 32);
        }
    };

    pub fn init(base_address: usize) LocalApic {
        page_allocator.offsetMapMem(base_address, base_address, 0x3, 0x1000)
            catch @panic("out of memory");
        return LocalApic{ .base_address = base_address };
    }

    pub inline fn readRegister(self: *const LocalApic, comptime register: Register) u32 {
        if (!register.read_allowed) @compileError(
            "Register does not allow being read from"
        );
        return @intToPtr(*volatile u32, self.base_address + register.offset).*;
    }

    pub inline fn writeRegister(self: *const LocalApic, comptime register: Register, value: u32) void {
        if (!register.write_allowed) @compileError(
            "Register does not allow being written to"
        );
        @intToPtr(*volatile u32, self.base_address + register.offset).* = value;
    }

    pub inline fn signalEoi(self: *const LocalApic) void {
        self.writeRegister(registers.EoiRegister, 0);
    }

    pub fn enableBspLocalApic(self: *const LocalApic) void {
        asm volatile (
            \\// -- Disable PIC --
            \\// Start PIC initialisation sequence
            \\movb $0x11, %%al
            \\outb %%al, $0x20
            \\outb %%al, $0xA0
            \\// Master PIC vector offset
            \\movb $0x20, %%al
            \\outb %%al, $0x21
            \\// Slave PIC vector offset
            \\movb $0x28, %%al
            \\outb %%al, $0xA1
            \\// Inform Master PIC of Slave PIC at IRQ2
            \\movb $0x04, %%al
            \\outb %%al, $0x21
            \\// Tell Slave PIC cascade identity
            \\movb $0x02, %%al
            \\outb %%al, $0xA1
            \\// Set 8086 mode
            \\movb $0x01, %%al
            \\outb %%al, $0x21
            \\outb %%al, $0xA1
            \\// Mask all interrupts
            \\movb $0xFF, %%al
            \\outb %%al, $0xA1
            \\outb %%al, $0x21
            \\// -- Enable Local APIC --
            \\movl $0x1B, %%ecx
            \\rdmsr
            \\orl $0x800, %%eax
            \\wrmsr
            :
            :
            : "memory", "eax", "ecx", "edx"
        );
        // Remap APIC Spurious Interrupt Vector Register to 0xFF and enable
        self.writeRegister(registers.SpuriousInterruptVectorRegister, 0x1FF);
    }
};

pub const IoApic = struct {
    base_address: usize,
    id: u32,
    global_system_interrupt_base: u32,
    num_redirection_entries: u16 = 0,

    pub const Register = struct {
        offset: usize,
        read_allowed: bool,
        write_allowed: bool,
    };

    pub const registers = struct {
        pub const IoApicIdRegister = Register{
            .offset = 0x0,
            .read_allowed = true,
            .write_allowed = true,
        };
        pub const NumRedirectionEntriesRegister = Register{
            .offset = 0x1,
            .read_allowed = true,
            .write_allowed = false,
        };
        pub const ArbitrationPriorityRegister = Register{
            .offset = 0x2,
            .read_allowed = true,
            .write_allowed = false,
        };
    };

    pub const RedirectionEntry = struct {
        interrupt_vector: u8,
        delivery_mode: DeliveryMode,
        destination_mode: DestinationMode,
        /// Set by the IO APIC if an interrupt is waiting to be sent. Read only
        interrupt_pending: bool = false,
        polarity: Polarity,
        level_triggered_interrupt_status: LevelTriggeredInterruptStatus = .EoiSent,
        trigger_mode: TriggerMode,
        interrupt_mask: bool,
        reserved: u39 = 0,
        destination_field: u8,

        pub const DeliveryMode = packed enum(u3) {
            Normal = 0,
            LowPriority = 1,
            SystemManagementInterrupt = 2,
            NonMaskableInterrupt = 4,
            Init = 5,
            External = 7,
            _,
        };

        pub const DestinationMode = packed enum(u1) {
            Physical = 0,
            Logical = 1,
        };

        pub const Polarity = packed enum(u1) {
            High = 0,
            Low = 1,
        };

        pub const LevelTriggeredInterruptStatus = packed enum(u1) {
            EoiSent = 0,
            InterruptReceived = 1,
        };

        pub const TriggerMode = packed enum(u1) {
            EdgeSensitive = 0,
            LevelSensitive = 1,
        };

        pub fn fromU64(value: u64) RedirectionEntry {
            return RedirectionEntry{
                .interrupt_vector = @truncate(u8, value & 0xFF),
                .delivery_mode = @intToEnum(DeliveryMode, @truncate(u3, (value & 0x700) >> 8)),
                .destination_mode = @intToEnum(
                    DestinationMode,
                    @truncate(u1, (value & 0x800) >> 11),
                ),
                .polarity = @intToEnum(Polarity, @truncate(u1, (value & 0x2000) >> 13)),
                .level_triggered_interrupt_status = @intToEnum(
                    LevelTriggeredInterruptStatus,
                    @truncate(u1, (value & 0x4000) >> 14),
                ),
                .trigger_mode = @intToEnum(TriggerMode, @truncate(u1, (value & 0x8000) >> 15)),
                .interrupt_mask = (value & 0x10000) >> 16 == 1,
                .destination_field = @truncate(u8, (value & 0x1FE0000) >> 56),
            };
        }

        pub fn toU64(self: RedirectionEntry) u64 {
            var value: u64 = 0;
            value |= self.interrupt_vector;
            value |= @as(u64, @enumToInt(self.delivery_mode)) << 8;
            value |= @as(u64, @enumToInt(self.destination_mode)) << 11;
            value |= @as(u64, if (self.interrupt_pending) 1 else 0) << 12;
            value |= @as(u64, @enumToInt(self.polarity)) << 13;
            value |= @as(u64, @enumToInt(self.level_triggered_interrupt_status)) << 14;
            value |= @as(u64, @enumToInt(self.trigger_mode)) << 15;
            value |= @as(u64, if (self.interrupt_mask) 1 else 0) << 16;
            value |= @as(u64, self.destination_field) << 56;
            return value;
        }
    };

    pub fn init(base_address: usize, id: u32, global_system_interrupt_base: u32) IoApic {
        page_allocator.offsetMapMem(base_address, base_address, 0x3, 0x1000)
            catch @panic("out of memory");
        var io_apic = IoApic{
            .base_address = base_address,
            .id = id,
            .global_system_interrupt_base = global_system_interrupt_base,
        };
        const num_entries = @truncate(
            u16,
            io_apic.readRegister(registers.NumRedirectionEntriesRegister),
        );
        logger.debug("redirection entries: {}", .{num_entries});
        io_apic.num_redirection_entries = num_entries;
        return io_apic;
    }

    pub fn readRegister(self: *const IoApic, comptime register: Register) u32 {
        if (!register.read_allowed) @compileError(
            "Register does not allow being read from"
        );
        // Write register index to selection register
        @intToPtr(*volatile u32, self.base_address).* = register.offset;
        // Read value from register window
        return @intToPtr(*volatile u32, self.base_address + 0x10).*;
    }

    pub fn writeRegister(self: *const IoApic, comptime register: Register, value: u32) void {
        if (!register.write_allowed) @compileError(
            "Register does not allow being written to"
        );
        // Write register index to selection register
        @intToPtr(*volatile u32, self.base_address).* = register.offset;
        // Write value to register window
        @intToPtr(*volatile u32, self.base_address + 0x10).* = value;
    }

    pub fn readRedirectionEntry(self: *const IoApic, entry_i: u8) RedirectionEntry {
        const index = entry_i * 2 + 0x10;
        if (index > 0x3F) @panic("redirection entry out of range");
        // Read first half of entry
        @intToPtr(*volatile u32, self.base_address).* = index;
        const lower = @intToPtr(*volatile u32, self.base_address + 0x10).*;
        // Read second half of entry
        @intToPtr(*volatile u32, self.base_address).* = index + 1;
        const upper = @intToPtr(*volatile u32, self.base_address + 0x10).*;
        return RedirectionEntry.fromU64((@as(u64, upper) << 32) + @as(u64, lower));
    }

    pub fn writeRedirectionEntry(self: *const IoApic, entry_i: u8, entry: RedirectionEntry) void {
        const index = entry_i * 2 + 0x10;
        if (index > 0x3F) @panic("redirection entry out of range");
        const value = entry.toU64();
        // Write first half of entry
        @intToPtr(*volatile u32, self.base_address).* = index;
        @intToPtr(*volatile u32, self.base_address + 0x10).* = @truncate(u32, value);
        // Write second half of entry
        @intToPtr(*volatile u32, self.base_address).* = index + 1;
        @intToPtr(*volatile u32, self.base_address + 0x10).* = @truncate(u32, value >> 32);
    }
};
