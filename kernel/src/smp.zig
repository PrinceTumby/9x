//! Multithreading synchronisation primitives

const std = @import("std");
const root = @import("root");
const build_options = @import("build_options");

pub const SpinLock = struct {
    state: State = .Unlocked,

    const State = enum(u8) {
        Unlocked,
        Locked,
    };
    
    pub const Held = struct {
        spinlock: *SpinLock,

        pub fn release(self: Held) void {
            releaseFn(self);
        }
    };

    const default_fns = if (build_options.multicore) locking else dummy;

    pub var releaseFn: fn(self: Held) void = default_fns.release;
    pub var isLockedFn: fn(self: *SpinLock) bool = default_fns.isLocked;
    pub var tryAcquireFn: fn (self: *SpinLock) ?Held = default_fns.tryAcquire;
    pub var acquireFn: fn (self: *SpinLock) Held = default_fns.acquire;
    pub var forceReleaseFn: fn (self: *SpinLock) void = default_fns.forceRelease;

    pub fn changeFns(multicore: bool) void {
        if (multicore) {
            releaseFn = locking.release;
            isLockedFn = locking.isLocked;
            tryAcquireFn = locking.tryAcquire;
            acquireFn = locking.acquire;
            forceReleaseFn = locking.forceRelease;
        } else {
            releaseFn = dummy.release;
            isLockedFn = dummy.isLocked;
            tryAcquireFn = dummy.tryAcquire;
            acquireFn = dummy.acquire;
            forceReleaseFn = dummy.forceRelease;
        }
    }

    pub fn init() SpinLock {
        return SpinLock{ .state = .Unlocked };
    }

    pub fn deinit(self: *SpinLock) void {
        self.* = undefined;
    }

    pub fn isLocked(self: *SpinLock) bool {
        return isLockedFn(self);
    }

    pub fn tryAcquire(self: *SpinLock) ?Held {
        return tryAcquireFn(self);
    }

    pub fn acquire(self: *SpinLock) Held {
        return acquireFn(self);
    }

    pub fn forceRelease(self: *SpinLock) void {
        return forceReleaseFn(self);
    }

    pub const locking = struct {
        pub fn release(self: Held) void {
            @atomicStore(State, &self.spinlock.state, .Unlocked, .Release);
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
    };

    pub const dummy = struct {
        pub fn release(self: Held) void {
            self.spinlock.state = .Unlocked;
        }

        pub fn isLocked(self: *SpinLock) bool {
            return self.state == .Locked;
        }

        pub fn tryAcquire(self: *SpinLock) ?Held {
            const old_value = self.state;
            if (old_value == .Locked) return null;
            self.state = .Locked;
            return Held{ .spinlock = self };
        }

        pub fn acquire(self: *SpinLock) Held {
            return self.tryAcquire() orelse @panic("SpinLock poisoned");
        }

        pub fn forceRelease(self: *SpinLock) void {
            self.state = .Unlocked;
        }
    };
};
