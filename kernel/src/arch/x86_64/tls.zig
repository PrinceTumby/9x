//! Architecture specific handling of thread-local storage

const std = @import("std");
const root = @import("root");
const common = @import("common.zig");
const asmSymbolFmt = root.zig_extensions.asmSymbolFmt;
const heap_allocator = root.heap.heap_allocator_ptr;
const Process = root.process.Process;
const KernelMainProcess = root.process.KernelMainProcess;
const VirtualPageMapper = root.arch.virtual_page_mapping.VirtualPageMapper;
const RegisterStore = common.process.RegisterStore;
const KernelMainRegisterStore = common.process.KernelMainRegisterStore;
const msr = common.msr;

pub const ThreadLocalVariables = struct {
    self_pointer: *ThreadLocalVariables,
    local_apic: LocalApicTls = .{},
    event_interrupt_handler: EventInterruptHandler = .{},
    current_process: Process = undefined,
    kernel_main_process: KernelMainProcess = .{},
    yield_info: YieldInfo = .{},

    const apic = @import("apic.zig");
    const LocalApic = apic.LocalApic;

    pub const LocalApicTls = struct {
        apic: LocalApic = undefined,
        timer_ms_numerator: usize = 1,
        timer_ms_denominator: usize = 1,
        interrupt_received: bool = false,
    };

    pub const EventInterruptHandler = struct {
        func: fn (usize) void = undefined,
        arg: usize = undefined,
    };

    pub const YieldInfo = extern struct {
        reason: Reason = .Time,
        // Only used if an exception ocurred
        exception_type: ExceptionType = undefined,
        error_code: u64 = 0,
        page_fault_address: u64 = 0,

        pub const Reason = enum(u64) {
            Time,
            YieldSystemCall,
            SystemCallRequest,
            ExitRequest,
            Exception,

            comptime {
                @setEvalBranchQuota(5000);
                inline for (@typeInfo(Reason).Enum.fields) |reason_type| {
                    asm(asmSymbolFmt("YieldInfo.Reason." ++ reason_type.name, reason_type.value));
                }
            }
        };

        pub const ExceptionType = enum(u64) {
            DivideByZero = 0,
            Debug = 1,
            NonMaskableInterrupt = 2,
            Breakpoint = 3,
            Overflow = 4,
            BoundRangeExceeded = 5,
            InvalidOpcode = 6,
            DeviceNotAvailable = 7,
            DoubleFault = 8,
            InvalidTss = 10,
            SegmentNotPresent = 11,
            StackSegmentFault = 12,
            GeneralProtectionFault = 13,
            PageFault = 14,
            x87FloatingPoint = 16,
            AlignmentCheck = 17,
            MachineCheck = 18,
            SimdFloatingPoint = 19,
            Virtualization = 20,
            ControlProtection = 21,
            HypervisorInjection = 28,
            VmmCommunication = 29,
            Security = 30,
            _,
        };
    };

    // Offset references for assembly, used for register loading and saving
    comptime {
        @setEvalBranchQuota(5000);
        asm(asmSymbolFmt(
            "ThreadLocalVariables.self_pointer",
            @byteOffsetOf(ThreadLocalVariables, "self_pointer"),
        ));
        asm(asmSymbolFmt(
            "ThreadLocalVariables.current_process.id",
            @byteOffsetOf(ThreadLocalVariables, "current_process") +
            @byteOffsetOf(Process, "id"),
        ));
        asm(asmSymbolFmt(
            "ThreadLocalVariables.current_process.registers.rax",
            @byteOffsetOf(ThreadLocalVariables, "current_process") +
            @byteOffsetOf(Process, "registers") +
            @byteOffsetOf(RegisterStore, "rax"),
        ));
        asm(asmSymbolFmt(
            "ThreadLocalVariables.current_process.page_mapper.page_table",
            @byteOffsetOf(ThreadLocalVariables, "current_process") +
            @byteOffsetOf(Process, "page_mapper") +
            @byteOffsetOf(VirtualPageMapper, "page_table"),
        ));
        asm(asmSymbolFmt(
            "ThreadLocalVariables.kernel_main_process.registers.rbx",
            @byteOffsetOf(ThreadLocalVariables, "kernel_main_process") +
            @byteOffsetOf(KernelMainProcess, "registers") +
            @byteOffsetOf(KernelMainRegisterStore, "rbx"),
        ));
        asm(asmSymbolFmt(
            "ThreadLocalVariables.kernel_main_process.registers.fs",
            @byteOffsetOf(ThreadLocalVariables, "kernel_main_process") +
            @byteOffsetOf(KernelMainProcess, "registers") +
            @byteOffsetOf(KernelMainRegisterStore, "fs"),
        ));
        asm(asmSymbolFmt(
            "ThreadLocalVariables.kernel_main_process.registers.vector_store",
            @byteOffsetOf(ThreadLocalVariables, "kernel_main_process") +
            @byteOffsetOf(KernelMainProcess, "registers") +
            @byteOffsetOf(KernelMainRegisterStore, "fxsave_area"),
        ));
        asm(asmSymbolFmt(
            "ThreadLocalVariables.yield_info.reason",
            @byteOffsetOf(ThreadLocalVariables, "yield_info") +
            @byteOffsetOf(YieldInfo, "reason"),
        ));
        asm(asmSymbolFmt(
            "ThreadLocalVariables.yield_info.exception_type",
            @byteOffsetOf(ThreadLocalVariables, "yield_info") +
            @byteOffsetOf(YieldInfo, "exception_type"),
        ));
    }
};

pub fn initTls() void {
    const ptr = heap_allocator.create(ThreadLocalVariables) catch @panic("out of memory");
    ptr.* = .{ .self_pointer = ptr };
    msr.write(msr.gs_base, @ptrToInt(ptr));
}

fn getReturnType(comptime name: []const u8) type {
    for (@typeInfo(ThreadLocalVariables).Struct.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.field_type;
    } else @compileError("Thread local variable \"" ++ name ++ "\" does not exist");
}

pub inline fn getThreadLocalVariables() *ThreadLocalVariables {
    comptime const asm_string = blk: {
        var buffer: [22]u8 = undefined;
        const offset = @byteOffsetOf(ThreadLocalVariables, "self_pointer");
        break :blk std.fmt.bufPrint(&buffer, "movq %%gs:{}, %[out]", .{offset})
            catch |err| @compileError("asm string formatting error: " ++ @errorName(err));
    };
    return asm (
        asm_string
        : [out] "=r" (-> *ThreadLocalVariables)
    );
}

// TODO Change to just return a pointer to the ThreadLocalVariables struct
pub inline fn getThreadLocalVariable(comptime name: []const u8) *getReturnType(name) {
    comptime const asm_string = blk: {
        var buffer: [22]u8 = undefined;
        const offset = @byteOffsetOf(ThreadLocalVariables, "self_pointer");
        break :blk std.fmt.bufPrint(&buffer, "movq %%gs:{}, %[out]", .{offset})
            catch |err| @compileError("asm string formatting error: " ++ @errorName(err));
    };
    return &@field(asm (
        asm_string
        : [out] "=r" (-> *ThreadLocalVariables)
    ), name);
}
