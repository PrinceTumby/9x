//! Multithreading synchronisation primitives

const builtin = @import("builtin");
const multicore_support = @import("root").build_options.multicore_support;

pub const SpinLock = if (multicore_support) struct {
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

    fn spin() void {
        var i: usize = 400;
        while (i != 0) : (i -= 1) {
            switch (builtin.cpu.arch) {
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
                    @tagName(builtin.cpu.arch)
                ),
            }
        }
    }
} else struct {
    pub const Held = struct {
        pub fn release(self: Held) void {
            _ = self;
        }
    };

    pub fn init() SpinLock {
        return SpinLock{};
    }

    pub fn deinit(self: *SpinLock) ?Held {
        self.* = undefined;
    }

    pub fn tryAcquire(self: *SpinLock) ?Held {
        _ = self;
        return Held{};
    }

    pub fn acquire(self: *SpinLock) Held {
        _ = self;
        return Held{};
    }
};
