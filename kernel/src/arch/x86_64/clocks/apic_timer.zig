const clock_manager = @import("../clock_manager.zig");
const tls = @import("../tls.zig");
const interrupts = @import("../interrupts.zig");
const LocalApic = @import("../apic.zig").LocalApic;
const idt = @import("../idt.zig");

pub fn sleepHandler(_: idt.InterruptFrame) callconv(.Interrupt) void {
    const local_apic_tls = tls.getThreadLocalVariable("local_apic");
    local_apic_tls.interrupt_received = true;
    local_apic_tls.apic.signalEoi();
}

pub fn eventHandler(_: idt.InterruptFrame) callconv(.Interrupt) void {
    const local_apic_tls = tls.getThreadLocalVariable("local_apic");
    const event_interrupt_handler = tls.getThreadLocalVariable("event_interrupt_handler");
    event_interrupt_handler.func(event_interrupt_handler.arg);
    local_apic_tls.apic.signalEoi();
}

pub var repeat_ticks: u32 = 0;

pub fn repeatHandler(_: idt.InterruptFrame) callconv(.Interrupt) void {
    const local_apic_tls = tls.getThreadLocalVariable("local_apic");
    const local_apic = local_apic_tls.apic;
    const root = @import("root");
    if (root.fb.buffer_dirty) root.fb.paint();
    local_apic.writeRegister(LocalApic.registers.InitialCountRegister, repeat_ticks);
    local_apic.signalEoi();
    // @import("std").log.scoped(.apic_timer).debug("APIC Timer interrupt!", .{});
}

pub fn initRepeat(timer_in_ms: u32) void {
    const local_apic_tls = tls.getThreadLocalVariable("local_apic");
    const local_apic = local_apic_tls.apic;
    // Install repeat handler in timer
    const LvtTimerRegister = LocalApic.registers.LvtTimerRegister;
    const timer_lvt = LocalApic.TimerLvt.fromU32(local_apic.readRegister(LvtTimerRegister));
    interrupts.setGenericStackHandler(
        &interrupts.kernel_idt.apic_interrupts[timer_lvt.interrupt_vector - 128],
        repeatHandler,
    );
    // Setup counter with apic ticks
    const numerator = local_apic_tls.timer_ms_numerator;
    const denominator = local_apic_tls.timer_ms_denominator;
    const time_in_apic_ticks = @truncate(u32, (numerator * timer_in_ms) / denominator);
    repeat_ticks = time_in_apic_ticks;
    local_apic.writeRegister(LocalApic.registers.InitialCountRegister, time_in_apic_ticks);
    @import("root").fb.manual_painting = false;
}

fn startTimer() void {
    const local_apic = tls.getThreadLocalVariable("local_apic").apic;
    local_apic.writeRegister(LocalApic.registers.InitialCountRegister, 0xFFFFFFFF);
}

pub fn calibrate() void {
    const local_apic_tls = tls.getThreadLocalVariable("local_apic");
    const local_apic = local_apic_tls.apic;
    // Divide by 16
    local_apic.writeRegister(LocalApic.registers.DivideConfigurationRegister, 0b011);
    // Calibrate timer
    local_apic.writeRegister(LocalApic.registers.InitialCountRegister, 0xFFFFFFFF);
    const time_slept = clock_manager.calibrationSleep(startTimer);
    const end_ticks = local_apic.readRegister(LocalApic.registers.CurrentCountRegister);
    const num_ticks: usize = 0xFFFFFFFF - end_ticks;
    local_apic_tls.timer_ms_numerator = num_ticks;
    local_apic_tls.timer_ms_denominator = time_slept / 1000;
}

pub fn map() !void {
    const entry_index = try interrupts.apic.findAndReserveEntry();
    const local_apic = tls.getThreadLocalVariable("local_apic").apic;
    // Enable APIC one-shot timer interrupts
    const LvtTimerRegister = LocalApic.registers.LvtTimerRegister;
    interrupts.setGenericStackHandler(
        &interrupts.kernel_idt.apic_interrupts[entry_index],
        sleepHandler,
    );
    var timer_lvt = LocalApic.TimerLvt.fromU32(local_apic.readRegister(LvtTimerRegister));
    timer_lvt.interrupt_vector = 128 + @as(u8, entry_index);
    timer_lvt.mask = true;
    timer_lvt.interrupt_pending = false;
    timer_lvt.timer_mode = .OneShot;
    local_apic.writeRegister(LvtTimerRegister, LocalApic.TimerLvt.toU32(timer_lvt));
    local_apic.writeRegister(LocalApic.registers.DivideConfigurationRegister, 0b011);
    local_apic.writeRegister(LocalApic.registers.InitialCountRegister, 0xFFFFFFFF);
    clock_manager.timers.apic = true;
}

/// Sleeps for the number of milliseconds requested.
pub fn sleepMs(time_in_ms: u32) void {
    // Calculate number of APIC timer ticks
    const local_apic_tls = tls.getThreadLocalVariable("local_apic");
    const local_apic = local_apic_tls.apic;
    const numerator = local_apic_tls.timer_ms_numerator;
    const denominator = local_apic_tls.timer_ms_denominator;
    const time_in_apic_ticks = @truncate(u32, (numerator * time_in_ms) / denominator);
    // Enable timer interrupts, set one shot mode
    const LvtTimerRegister = LocalApic.registers.LvtTimerRegister;
    var timer_lvt = LocalApic.TimerLvt.fromU32(local_apic.readRegister(LvtTimerRegister));
    timer_lvt.mask = false;
    timer_lvt.timer_mode = .OneShot;
    local_apic.writeRegister(LvtTimerRegister, LocalApic.TimerLvt.toU32(timer_lvt));
    // Request interrupt in requested number of ticks
    local_apic_tls.interrupt_received = false;
    local_apic.writeRegister(LocalApic.registers.InitialCountRegister, time_in_apic_ticks);
    // Wait for timer interrupt
    while (!local_apic_tls.interrupt_received) {
        asm volatile ("sti; hlt; cli");
    }
    local_apic_tls.interrupt_received = false;
}

// Countdown functions

pub fn startCountdown(time_in_ms: u32) void {
    // Calculate number of APIC timer ticks
    const local_apic_tls = tls.getThreadLocalVariable("local_apic");
    const local_apic = local_apic_tls.apic;
    const numerator = local_apic_tls.timer_ms_numerator;
    const denominator = local_apic_tls.timer_ms_denominator;
    const time_in_apic_ticks = @truncate(u32, (numerator * time_in_ms) / denominator);
    // Enable timer interrupts, set one shot mode
    const LvtTimerRegister = LocalApic.registers.LvtTimerRegister;
    var timer_lvt = LocalApic.TimerLvt.fromU32(local_apic.readRegister(LvtTimerRegister));
    timer_lvt.mask = false;
    timer_lvt.timer_mode = .OneShot;
    local_apic.writeRegister(LvtTimerRegister, LocalApic.TimerLvt.toU32(timer_lvt));
    // Request interrupt in requested number of ticks
    local_apic_tls.interrupt_received = false;
    local_apic.writeRegister(LocalApic.registers.InitialCountRegister, time_in_apic_ticks);
}

pub fn getCountdownRemainingTime() u32 {
    // Read current count, convert ticks to milliseconds
    const local_apic_tls = tls.getThreadLocalVariable("local_apic");
    const local_apic = local_apic_tls.apic;
    const numerator = local_apic_tls.timer_ms_numerator;
    const denominator = local_apic_tls.timer_ms_denominator;
    const time_in_apic_ticks = local_apic.readRegister(LocalApic.registers.CurrentCountRegister);
    return @truncate(u32, (time_in_apic_ticks * denominator) / numerator);
}

pub fn getHasCountdownEnded() bool {
    const local_apic_tls = tls.getThreadLocalVariable("local_apic");
    return local_apic_tls.interrupt_received;
}

pub fn stopCountdown() void {
    // Disable timer interrupts
    const local_apic_tls = tls.getThreadLocalVariable("local_apic");
    const local_apic = local_apic_tls.apic;
    const LvtTimerRegister = LocalApic.registers.LvtTimerRegister;
    var timer_lvt = LocalApic.TimerLvt.fromU32(local_apic.readRegister(LvtTimerRegister));
    timer_lvt.mask = true;
    local_apic.writeRegister(LvtTimerRegister, LocalApic.TimerLvt.toU32(timer_lvt));
}
