const std = @import("std");
const cmos = @import("cmos.zig");
const idt = @import("../idt.zig");
const interrupts = @import("../interrupts.zig");
const tls = @import("../tls.zig");

const logger = std.log.scoped(.x86_64_rtc);

var interrupt_received: bool = false;

pub fn sleepHandlerApic(_interrupt_frame: *const idt.InterruptFrame) callconv(.Interrupt) void {
    const local_apic = tls.getThreadLocalVariable("local_apic");
    interrupt_received = true;
    local_apic.apic.signalEoi();
}

/// Calls `startTimer`, sleeps for an arbitrary amount of time, then returns the
/// number of microseconds slept. Used for calibrating other clocks at startup.
/// The RTC must not be mapped to an IRQ or be in use.
pub fn calibrationSleep(startTimer: fn() void) u32 {
    // Ensure interrupts are disabled (paranoid check, but interrupts must NEVER happen
    // during RTC setup)
    asm volatile ("cli");
    // Map RTC IRQ temporarily
    interrupts.mapLegacyIrq(8, sleepHandlerApic) catch @panic("out of vectors");
    defer interrupts.unmapLegacyIrq(8);
    // Output divider of 12 generates interrupts at 16Hz (nice factor of 1_000_000)
    const rate = 12;
    // Read old values from A and B registers, disable NMI
    const previous_a = cmos.readByte(true, cmos.registers.status_register_a);
    const previous_b = cmos.readByte(true, cmos.registers.status_register_b);
    // Compute new A register value
    // Take top 4 bits of old value, add bottom 4 rate bits
    const new_a = (previous_a & 0xF0) | rate;
    // Compute new B register value
    const new_b_interrupt = previous_b | 0x40;
    // Compute B register value for disabling interrupts
    const new_b_no_interrupt = previous_b & 0xB0;
    // Reset interrupt received indicator
    interrupt_received = false;
    // Write out rate to A register
    cmos.writeByte(true, cmos.registers.status_register_a, new_a);
    // Enable periodic interrupts on B register
    cmos.writeByte(true, cmos.registers.status_register_b, new_b_interrupt);
    // Flush C register
    _ = cmos.readByte(true, cmos.registers.status_register_c);
    // Wait for next timer IRQ
    while (!interrupt_received) {
        asm volatile ("sti; hlt; cli");
    }
    // Start timer calibration
    startTimer();
    // Flush C register, required every time timer IRQ is received
    _ = cmos.readByte(true, cmos.registers.status_register_c);
    // Reset interrupt received indicator
    interrupt_received = false;
    // Wait until timer indicates end of sleep period
    while (!interrupt_received) {
        asm volatile ("sti; hlt; cli");
    }
    // Disable timer IRQs
    cmos.writeByte(true, cmos.registers.status_register_b, new_b_no_interrupt);
    // Flush C register again, enable NMI
    _ = cmos.readByte(true, cmos.registers.status_register_c);
    // Reset interrupt received indicator again
    interrupt_received = false;
    // Return number of ticks slept for
    const frequency = 32768 >> (rate - 1);
    return 1_000_000 / frequency;
}
