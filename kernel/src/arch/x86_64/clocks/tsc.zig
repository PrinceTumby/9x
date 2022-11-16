const std = @import("std");
const clock_manager = @import("../clock_manager.zig");
const tls = @import("../tls.zig");

const logger = std.log.scoped(.x86_64_tsc);

pub inline fn readCounter() u64 {
    var eax: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("rdtscp"
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx)
        :
        : "ecx"
    );
    return @as(u64, eax) | (@as(u64, edx) << 32);
}

fn calibrateStartTimer() void {
    tls.getThreadLocalVariable("timestamp_counter").countdown_end = readCounter();
}

pub fn calibrate() void {
    const tsc_tls = tls.getThreadLocalVariable("timestamp_counter");
    const time_slept = clock_manager.calibrationSleep(calibrateStartTimer);
    const end_ticks = readCounter();
    tsc_tls.us_numerator = end_ticks - tsc_tls.countdown_end;
    tsc_tls.us_denominator = time_slept;
    logger.debug("TSC Calibration: {}/{}", .{ tsc_tls.us_numerator, tsc_tls.us_denominator });
}

pub fn startCountdown(time_in_ms: u32) void {
    const time_in_us = @as(usize, time_in_ms) * 1000;
    // Calculate number of TSC ticks
    const tsc_tls = tls.getThreadLocalVariable("timestamp_counter");
    const local_apic = local_apic_tls.apic;
    tsc_tls.countdown_end = (tsc_tls.us_numerator * time_in_us) / tsc_tls.us_numerator;
}

pub fn getCountdownRemainingTime() u32 {
    // Read current count, convert ticks to microseconds, then to milliseconds
    const time_in_tsc_ticks = readCounter();
    const deadline_time = tls.getThreadLocalVariable("timestamp_counter").countdown_end;
    const current_time = readCounter();
    if (current_time >= deadline_time) return 0;
    return @truncate(u32, ((deadline_time - current_time) * denominator) / numerator / 1000);
}

pub fn getHasCountdownEnded() bool {
    const time_in_tsc_ticks = readCounter();
    const deadline_time = tls.getThreadLocalVariable("timestamp_counter").countdown_end;
    const current_time = readCounter();
    return current_time >= deadline_time;
}
