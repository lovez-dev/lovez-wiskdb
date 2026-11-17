//! Opt-in timing around existing mutexes. Counters share the measured mutex;
//! callers must hold it when taking a stats snapshot. No allocations or atomics.
const std = @import("std");

pub const Stats = struct {
    acquisitions: u64 = 0,
    wait_ns: u64 = 0,
    hold_ns: u64 = 0,
    max_wait_ns: u64 = 0,
    max_hold_ns: u64 = 0,
    wait_ge_1us: u64 = 0,
    wait_ge_10us: u64 = 0,
};

pub const Profile = struct {
    enabled: bool = false,
    counters: Stats = .{},

    pub fn lock(self: *Profile, mutex: *std.Io.Mutex, io: std.Io) Guard {
        const start = if (self.enabled) now(io) else 0;
        mutex.lockUncancelable(io);
        return .{ .profile = self, .mutex = mutex, .io = io, .start = start, .acquired = if (self.enabled) now(io) else 0 };
    }

    fn record(self: *Profile, wait: u64, hold: u64) void {
        self.counters.acquisitions += 1;
        self.counters.wait_ns += wait;
        self.counters.hold_ns += hold;
        self.counters.max_wait_ns = @max(self.counters.max_wait_ns, wait);
        self.counters.max_hold_ns = @max(self.counters.max_hold_ns, hold);
        self.counters.wait_ge_1us += @intFromBool(wait >= 1000);
        self.counters.wait_ge_10us += @intFromBool(wait >= 10000);
    }
};

pub const Guard = struct {
    profile: *Profile,
    mutex: *std.Io.Mutex,
    io: std.Io,
    start: i96,
    acquired: i96,

    pub fn unlock(self: *Guard) void {
        if (self.profile.enabled) {
            const end = now(self.io);
            self.profile.record(@intCast(@max(0, self.acquired - self.start)), @intCast(@max(0, end - self.acquired)));
        }
        self.mutex.unlock(self.io);
        self.* = undefined;
    }
};

fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

test "lock profile: totals maxima and threshold counts" {
    var profile = Profile{ .enabled = true };
    profile.record(500, 70);
    profile.record(1500, 90);
    profile.record(10000, 50);
    try std.testing.expectEqual(Stats{ .acquisitions = 3, .wait_ns = 12000, .hold_ns = 210, .max_wait_ns = 10000, .max_hold_ns = 90, .wait_ge_1us = 2, .wait_ge_10us = 1 }, profile.counters);
}

test "lock profile: disabled guards do not collect counters" {
    var mutex: std.Io.Mutex = .init;
    var profile = Profile{};
    var guard = profile.lock(&mutex, std.testing.io);
    guard.unlock();
    try std.testing.expectEqual(Stats{}, profile.counters);
    profile.enabled = true;
    guard = profile.lock(&mutex, std.testing.io);
    guard.unlock();
    try std.testing.expectEqual(@as(u64, 1), profile.counters.acquisitions);
}

test "lock profile: concurrent guards protect counters with the measured mutex" {
    const Context = struct {
        mutex: std.Io.Mutex = .init,
        profile: Profile = .{ .enabled = true },
        total: usize = 0,
        fn run(ctx: *@This()) void {
            for (0..500) |_| {
                var guard = ctx.profile.lock(&ctx.mutex, std.testing.io);
                ctx.total += 1;
                guard.unlock();
            }
        }
    };
    var ctx = Context{};
    const thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    Context.run(&ctx);
    thread.join();
    try std.testing.expectEqual(@as(usize, 1000), ctx.total);
    try std.testing.expectEqual(@as(u64, 1000), ctx.profile.counters.acquisitions);
}
