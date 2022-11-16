//! Provides abstracted clock and timing functions over the x86_64 clocks.
//! Automatically adjusts based on which clocks are available.

const std = @import("std");

pub const pit = @import("clocks/pit.zig");
pub const apic_timer = @import("clocks/apic_timer.zig");
pub const cmos = @import("clocks/cmos.zig");
pub const rtc = @import("clocks/rtc.zig");
pub const tsc = @import("clocks/tsc.zig");

pub const Clock = enum {
    Pit,
    Cmos,
    Rtc,
    Apic,
    Hpet,
    Tsc,
    None,
};

const clock_field_map = std.ComptimeStringMap(Clock, .{
    .{ "pit", .Pit },
    .{ "cmos", .Cmos },
    .{ "rtc", .Rtc },
    .{ "apic", .Apic },
    .{ "hpet", .Hpet },
    .{ "tsc", .Tsc },
});

pub var calibration_timers = struct {
    hpet: bool = false,
    // Only ever true if the exact APIC timer tick rate is able to be found via CPUID
    apic: bool = false,
    pit: bool = false,
    rtc: bool = true,
    cmos: bool = true,
}{};

pub var timers = struct {
    apic: bool = false,
    hpet: bool = false,
    pit: bool = false,
}{};

pub var counters = struct {
    // True counters
    tsc: bool = false,
    hpet: bool = false,
    // Emulated counters
    apic: bool = false,
    pit: bool = false,
    rtc: bool = false,
}{};

pub var calibrationSleep: fn (startTimer: fn () void) u32 = dummyCalibrationSleep;

pub const InterruptType = enum {
    Sleep,
    ContextSwitch,
};

// TODO Change unit of time from milliseconds to microseconds

pub var setInterruptType: fn (interrupt_type: InterruptType) void = dummySetInterruptType;

pub var sleepMs: fn (time_in_ms: u32) void = dummySleepMs;

pub var startCountdown: fn (time_in_ms: u32) void = dummyStartCountdown;

pub var getCountdownRemainingTime: fn () u32 = dummyGetCountdownRemainingTime;

pub var getHasCountdownEnded: fn () bool = dummyGetHasCountdownEnded;

pub var stopCountdown: fn () void = dummyStopCountdown;

pub var acknowledgeCountdownInterrupt: fn () void = dummyAcknowledgeCountdownInterrupt;

fn dummyCalibrationSleep(_: fn () void) u32 {
    @panic("no function for calibrationSleep available");
}

fn dummySetInterruptType(_: InterruptType) void {
    @panic("no function for setInterruptType available");
}

fn dummySleepMs(_: u32) void {
    @panic("no function for sleepMs available");
}

fn dummyStartCountdown(_: u32) void {
    @panic("no function for startCountdown available");
}

fn dummyGetCountdownRemainingTime() u32 {
    @panic("no function for getCountdownRemainingTime available");
}

fn dummyGetHasCountdownEnded() bool {
    @panic("no function for getHasCountdownEnded available");
}

fn dummyStopCountdown() void {}

fn dummyAcknowledgeCountdownInterrupt() void {}

pub fn updateClockFunctions() void {
    calibrationSleep = switch (selectClock(calibration_timers)) {
        .Rtc => rtc.calibrationSleep,
        .Cmos => cmos.calibrationSleep,
        .None => dummyCalibrationSleep,
        else => @panic("clock manager dev bug: calibration timer unhandled"),
    };
    // Update countdown functions
    switch (selectClock(timers)) {
        .Apic => {
            setInterruptType = apic_timer.setInterruptType;
            sleepMs = apic_timer.sleepMs;
            startCountdown = apic_timer.startCountdown;
            getCountdownRemainingTime = apic_timer.getCountdownRemainingTime;
            getHasCountdownEnded = apic_timer.getHasCountdownEnded;
            stopCountdown = apic_timer.stopCountdown;
            acknowledgeCountdownInterrupt = apic_timer.acknowledgeCountdownInterrupt;
        },
        .None => {
            setInterruptType = dummySetInterruptType;
            sleepMs = dummySleepMs;
            startCountdown = dummyStartCountdown;
            getCountdownRemainingTime = dummyGetCountdownRemainingTime;
            getHasCountdownEnded = dummyGetHasCountdownEnded;
            stopCountdown = dummyStopCountdown;
            acknowledgeCountdownInterrupt = dummyAcknowledgeCountdownInterrupt;
        },
        else => @panic("clock manager bug: timer funcs unhandled"),
    }
}

inline fn selectClock(clock_list: anytype) Clock {
    const fields = @typeInfo(@TypeOf(clock_list)).Struct.fields;
    inline for (fields) |field| {
        const name = field.name;
        if (@field(clock_list, name)) {
            return comptime blk: {
                const clock = clock_field_map.get(name);
                break :blk clock orelse @compileError("unhandled clock type");
            };
        }
    }
    return .None;
}
