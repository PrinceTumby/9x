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
    timestamp_counter: TimestampCounterTls = .{},
    event_interrupt_handler: EventInterruptHandler = .{},
    current_process: Process = undefined,
    current_process_heap_ptr: *Process = undefined,
    kernel_main_process: KernelMainProcess = .{},
    yield_info: YieldInfo = .{},

    const apic = @import("apic.zig");
    const LocalApic = apic.LocalApic;

    pub const LocalApicTls = struct {
        apic: LocalApic = undefined,
        interrupt_idt_index: usize = undefined,
        timer_us_numerator: usize = 1,
        timer_us_denominator: usize = 1,
        interrupt_received: bool = false,
    };

    pub const TimestampCounterTls = struct {
        us_numerator: usize = 1,
        us_denominator: usize = 1,
        countdown_end: usize = undefined,
    };

    pub const EventInterruptHandler = struct {
        func: fn (usize) void = undefined,
        arg: usize = undefined,
    };

    pub const YieldInfo = extern struct {
        reason: Reason = .timeout,
        // Only used if an exception ocurred
        exception_type: ExceptionType = undefined,
        exception_error_code: u64 = 0,
        page_fault_address: u64 = 0,

        pub const Reason = enum(u64) {
            timeout,
            yield_system_call,
            system_call_request,
            exitrequest,
            exception,

            comptime {
                @setEvalBranchQuota(5000);
                inline for (@typeInfo(Reason).Enum.fields) |reason_type| {
                    asm (asmSymbolFmt("YieldInfo.Reason." ++ reason_type.name, reason_type.value));
                }
            }
        };

        pub const ExceptionType = enum(u64) {
            divide_by_zero = 0,
            debug = 1,
            non_maskable_interrupt = 2,
            breakpoint = 3,
            overflow = 4,
            bound_range_exceeded = 5,
            invalid_opcode = 6,
            device_not_available = 7,
            double_fault = 8,
            invalid_tss = 10,
            segment_not_present = 11,
            stack_segment_fault = 12,
            general_protection_fault = 13,
            page_fault = 14,
            x87_floating_point = 16,
            alignment_check = 17,
            machine_check = 18,
            simd_floating_point = 19,
            virtualization = 20,
            control_protection = 21,
            hypervisor_injection = 28,
            vmm_communication = 29,
            security = 30,
            _,

            comptime {
                @setEvalBranchQuota(10000);
                inline for (@typeInfo(ExceptionType).Enum.fields) |exception| {
                    asm (asmSymbolFmt("ExceptionType." ++ exception.name, exception.value));
                }
            }
        };
    };

    // Offset references for assembly, used for register loading and saving
    // Must kept up to date with:
    // - root.process.Process
    // - root.process.KernelMainProcess
    comptime {
        @setEvalBranchQuota(5000);
        asm (asmSymbolFmt(
                "ThreadLocalVariables.self_pointer",
                @byteOffsetOf(ThreadLocalVariables, "self_pointer"),
            ));
        asm (asmSymbolFmt(
                "ThreadLocalVariables.current_process.id",
                @byteOffsetOf(ThreadLocalVariables, "current_process") +
                    @byteOffsetOf(Process, "id"),
            ));
        asm (asmSymbolFmt(
                "ThreadLocalVariables.current_process.registers.rax",
                @byteOffsetOf(ThreadLocalVariables, "current_process") +
                    @byteOffsetOf(Process, "registers") +
                    @byteOffsetOf(RegisterStore, "rax"),
            ));
        asm (asmSymbolFmt(
                "ThreadLocalVariables.current_process.page_mapper.page_table",
                @byteOffsetOf(ThreadLocalVariables, "current_process") +
                    @byteOffsetOf(Process, "page_mapper") +
                    @byteOffsetOf(VirtualPageMapper, "page_table"),
            ));
        asm (asmSymbolFmt(
                "ThreadLocalVariables.current_process.registers.vector_store",
                @byteOffsetOf(ThreadLocalVariables, "current_process") +
                    @byteOffsetOf(Process, "registers") +
                    @byteOffsetOf(RegisterStore, "fxsave_area"),
            ));
        asm (asmSymbolFmt(
                "ThreadLocalVariables.kernel_main_process.registers.rbx",
                @byteOffsetOf(ThreadLocalVariables, "kernel_main_process") +
                    @byteOffsetOf(KernelMainProcess, "registers") +
                    @byteOffsetOf(KernelMainRegisterStore, "rbx"),
            ));
        asm (asmSymbolFmt(
                "ThreadLocalVariables.kernel_main_process.registers.fs",
                @byteOffsetOf(ThreadLocalVariables, "kernel_main_process") +
                    @byteOffsetOf(KernelMainProcess, "registers") +
                    @byteOffsetOf(KernelMainRegisterStore, "fs"),
            ));
        asm (asmSymbolFmt(
                "ThreadLocalVariables.kernel_main_process.registers.vector_store",
                @byteOffsetOf(ThreadLocalVariables, "kernel_main_process") +
                    @byteOffsetOf(KernelMainProcess, "registers") +
                    @byteOffsetOf(KernelMainRegisterStore, "fxsave_area"),
            ));
        asm (asmSymbolFmt(
                "ThreadLocalVariables.yield_info.reason",
                @byteOffsetOf(ThreadLocalVariables, "yield_info") +
                    @byteOffsetOf(YieldInfo, "reason"),
            ));
        asm (asmSymbolFmt(
                "ThreadLocalVariables.yield_info.exception_type",
                @byteOffsetOf(ThreadLocalVariables, "yield_info") +
                    @byteOffsetOf(YieldInfo, "exception_type"),
            ));
        asm (asmSymbolFmt(
                "ThreadLocalVariables.yield_info.exception_error_code",
                @byteOffsetOf(ThreadLocalVariables, "yield_info") +
                    @byteOffsetOf(YieldInfo, "exception_error_code"),
            ));
        asm (asmSymbolFmt(
                "ThreadLocalVariables.yield_info.page_fault_address",
                @byteOffsetOf(ThreadLocalVariables, "yield_info") +
                    @byteOffsetOf(YieldInfo, "page_fault_address"),
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
        break :blk std.fmt.bufPrint(&buffer, "movq %%gs:{}, %[out]", .{offset}) catch |err| {
            @compileError("asm string formatting error: " ++ @errorName(err));
        };
    };
    return asm (asm_string
        : [out] "=r" (-> *ThreadLocalVariables)
    );
}

// TODO Change to just return a pointer to the ThreadLocalVariables struct
pub inline fn getThreadLocalVariable(comptime name: []const u8) *getReturnType(name) {
    comptime const asm_string = blk: {
        var buffer: [22]u8 = undefined;
        const offset = @byteOffsetOf(ThreadLocalVariables, "self_pointer");
        break :blk std.fmt.bufPrint(&buffer, "movq %%gs:{}, %[out]", .{offset}) catch |err| {
            @compileError("asm string formatting error: " ++ @errorName(err));
        };
    };
    return &@field(asm (asm_string
        : [out] "=r" (-> *ThreadLocalVariables)
    ), name);
}
