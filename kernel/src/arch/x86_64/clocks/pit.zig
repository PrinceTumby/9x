const root = @import("root");
const SpinLock = root.smp.SpinLock;
const apic = @import("../apic.zig");
const idt = @import("../idt.zig");
const interrupts = @import("../interrupts.zig");
const tls = @import("../tls.zig");

var lock = SpinLock.init();
var interrupt_received: bool = false;

pub fn sleepHandlerApic(
    _interrupt_frame: *const idt.InterruptFrame,
) callconv(.Interrupt) void {
    const local_apic = tls.getThreadLocalVariable("local_apic");
    interrupt_received = true;
    local_apic.apic.signalEoi();
}

pub fn eventHandlerApic(
    _interrupt_frame: *const idt.InterruptFrame,
) callconv(.Interrupt) void {
    const local_apic = tls.getThreadLocalVariable("local_apic");
    const interrupt_event_handler = tls.getThreadLocalVariable("interrupt_event_handler");
    interrupt_event_handler.func(interrupt_event_handler.arg);
    local_apic.apic.signalEoi();
}

/// Calls `start_func`, waits an arbitrary amount of time, then calls `end_func`.
/// The amount of time slept is then returned. Useful for calibrating other clocks.
/// The PIT must not be mapped to an IRQ and should not currently be in use.
pub fn calibrateOther(start_func: fn() void, end_func: fn() void) usize {
    // Prepare PIT
    asm volatile ("cli");
    interrupts.mapLegacyIrq(0, sleepHandlerApic) catch @panic("out of vectors");
    defer interrupts.unmapLegacyIrq(0);
    const sleep_time_ms = 100;
    const held = prepareSleep();
    // Call start func, sleep, call end func
    sleepMsWithFn(held, sleep_time_ms, start_func);
    end_func();
}

/// A sleep handler must be mapped to IRQ 0 before calling.
pub fn prepareSleep() SpinLock.Held {
    const held = lock.acquire();
    // Set PIT one-shot mode on IRQ 0
    asm volatile ("outb %[command], $0x43"
        :
        : [command] "{al}" (@as(u8, 0x30))
    );
    // Setting PIT mode seems to trigger an interrupt, so this flushes it
    while (!interrupt_received) {
        asm volatile ("sti; hlt; cli");
    }
    return held;
}

/// Sleeps for the number of milliseconds requested.
/// `prepareSleep` must be called first to obtain `held`.
/// Consumes `held`.
pub fn sleepMs(held: SpinLock.Held, time_in_ms: u8) void {
    // Calculate number of PIT ticks
    const time_in_pit_ticks = @truncate(u16, (@as(u32, time_in_ms) * 1193182) / 1000);
    // Request interrupt in requested number of ticks
    asm volatile (
        \\cli
        \\movb %[time_low], %%al
        \\outb %%al, $0x40
        \\movb %[time_high], %%al
        \\outb %%al, $0x40
        :
        : [time_low] "r" (@truncate(u8, time_in_pit_ticks)),
          [time_high] "r" (@truncate(u8, time_in_pit_ticks >> 8))
    );
    interrupt_received = false;
    // Wait for timer interrupt
    while (!interrupt_received) {
        asm volatile ("sti; hlt; cli");
    }
    interrupt_received = false;
    held.release();
}

/// Calls `func` with `arg` then sleeps for the number of milliseconds requested.
/// Useful for calibrating timers, as the setup is done before `func` is run.
pub fn sleepMsWithFn(
    held: SpinLock.Held,
    time_in_ms: u8,
    func: fn () void,
) void {
    // Calculate number of PIT ticks
    const time_in_pit_ticks = @truncate(u16, (@as(u32, time_in_ms) * 1193182) / 1000);
    // Request interrupt in requested number of ticks
    asm volatile (
        \\cli
        \\movb %[time_low], %%al
        \\outb %%al, $0x40
        \\movb %[time_high], %%al
        \\outb %%al, $0x40
        :
        : [time_low] "r" (@truncate(u8, time_in_pit_ticks)),
          [time_high] "r" (@truncate(u8, time_in_pit_ticks >> 8))
    );
    interrupt_received = false;
    // Run requested function before sleeping
    func(arg);
    // Wait for timer interrupt
    while (!interrupt_received) {
        asm volatile ("sti; hlt; cli");
    }
    interrupt_received = false;
    held.release();
}
