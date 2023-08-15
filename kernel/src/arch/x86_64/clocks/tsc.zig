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
