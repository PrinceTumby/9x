const root = @import("root");
const idt = @import("idt.zig");
const Process = root.process.Process;
const KernelMainProcess = root.process.KernelMainProcess;
const InterruptFrame = idt.InterruptFrame;

const asm_funcs = struct {
    extern fn taskSwitchKernelMainToUserSysret(process: *Process) usize;

    extern fn taskSwitchKernelMainToUserIret(process: *Process) usize;
};

pub inline fn returnToUserProcessFromSyscall(process: *Process) void {
    asm volatile ("" ::: "rsi", "rflags", "memory");
    _ = asm_funcs.taskSwitchKernelMainToUserSysret(process);
}

pub inline fn resumeUserProcess(process: *Process) void {
    asm volatile ("" ::: "rsi", "rflags", "memory");
    _ = asm_funcs.taskSwitchKernelMainToUserIret(process);
}

pub extern fn timerContextSwitchHandler(_: *const InterruptFrame) callconv(.Interrupt) void;
