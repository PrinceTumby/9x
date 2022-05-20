//! Architecture specific handling of thread-local storage

const std = @import("std");
const root = @import("root");
const msr = @import("common.zig").msr;
const multicore_support = root.build_options.multicore_support;
const heap_allocator = root.heap.kernel_heap_allocator.allocator();

pub const ThreadLocalVariables = struct {
    self_pointer: *ThreadLocalVariables,
    local_apic: LocalApicTls = .{},
    event_interrupt_handler: EventInterruptHandler = .{},

    const apic = @import("apic.zig");
    const LocalApic = apic.LocalApic;

    pub const LocalApicTls = struct {
        apic: LocalApic = undefined,
        timer_ms_numerator: usize = 1,
        timer_ms_denominator: usize = 1,
        interrupt_received: bool = false,
    };

    pub const EventInterruptHandler = struct {
        func: fn(usize) void = undefined,
        arg: usize = undefined,
    };
};

fn getReturnType(comptime name: []const u8) type {
    for (@typeInfo(ThreadLocalVariables).Struct.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.field_type;
    } else @compileError("Thread local variable \"" ++ name ++ "\" does not exist");
}

pub usingnamespace if (multicore_support) struct {
    pub fn initTls() void {
        const ptr = heap_allocator.create(ThreadLocalVariables) catch @panic("out of memory");
        ptr.* = .{.self_pointer = ptr};
        msr.write(msr.gs_base, @ptrToInt(ptr));
    }

    // TODO Change to just return a pointer to the ThreadLocalVariables struct
    pub inline fn getThreadLocalVariable(comptime name: []const u8) *getReturnType(name) {
        const asm_string = comptime blk: {
            var buffer: [64]u8 = undefined;
            const offset = @offsetOf(ThreadLocalVariables, "self_pointer");
            break :blk std.fmt.bufPrint(&buffer, "movq %%gs:{}, %[out]", .{offset})
                catch |err| @compileError("asm string formatting error: " ++ @errorName(err));
        };
        return &@field(asm (
            asm_string
            : [out] "=r" (-> *ThreadLocalVariables)
        ), name);
    }
} else struct {
    var global_variables: ThreadLocalVariables = undefined;

    pub fn initTls() void {
        global_variables = .{.self_pointer = &global_variables};
    }

    pub inline fn getThreadLocalVariable(comptime name: []const u8) *getReturnType(name) {
        return &@field(global_variables, name);
    }
};
