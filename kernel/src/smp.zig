//! Multithreading synchronisation primitives

const std = @import("std");
const root = @import("root");
const build_options = @import("build_options");

pub const SpinLock = if (build_options.multicore) struct {
    state: State = .Unlocked,

    const State = enum(u8) {
        Unlocked,
        Locked,
    };

    pub const Held = struct {
        spinlock: *SpinLock,

        pub fn release(self: Held) void {
            @atomicStore(State, &self.spinlock.state, .Unlocked, .Release);
        }
    };

    pub fn init() SpinLock {
        return SpinLock{ .state = .Unlocked };
    }

    pub fn deinit(self: *SpinLock) ?Held {
        self.* = undefined;
    }

    pub fn isLocked(self: *SpinLock) bool {
        return @atomicLoad(State, &self.state, .Acquire) == .Locked;
    }

    pub fn tryAcquire(self: *SpinLock) ?Held {
        return switch (@atomicRmw(State, &self.state, .Xchg, .Locked, .Acquire)) {
            .Unlocked => Held{ .spinlock = self },
            .Locked => null,
        };
    }

    pub fn acquire(self: *SpinLock) Held {
        while (true) {
            return self.tryAcquire() orelse {
                spin();
                continue;
            };
        }
    }

    /// Used to force a poisoned lock to be released
    pub fn forceRelease(self: *SpinLock) void {
        @atomicStore(State, &self.state, .Unlocked, .Release);
    }

    fn spin() void {
        var i: usize = 400;
        while (i != 0) : (i -= 1) {
            switch (std.builtin.arch) {
                .i386, .x86_64 => asm volatile ("pause"
                    :
                    :
                    : "memory"
                ),
                .arm, .aarch64 => asm volatile ("yield"
                    :
                    :
                    : "memory"
                ),
                // TODO Implement better spinlock waiting for RISC-V
                .riscv32, .riscv64 => asm volatile ("nop"
                    :
                    :
                    : "memory"
                ),
                else => @compileError(
                    "No spinlock pause instruction programmed for " ++
                    @tagName(std.builtin.arch)
                ),
            }
        }
    }
} else struct {
    pub const Held = struct {
        pub fn release(_self: Held) void {}
    };

    pub fn init() SpinLock {
        return SpinLock{};
    }

    pub fn deinit(_self: *SpinLock) ?Held {
        self.* = undefined;
    }

    pub fn tryAcquire(_self: *SpinLock) ?Held {
        return Held{};
    }

    pub fn acquire(_self: *SpinLock) Held {
        return Held{};
    }
};
