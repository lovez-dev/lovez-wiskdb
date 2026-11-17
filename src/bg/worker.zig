//! Runs queued and timed jobs serially on one thread. Jobs synchronize their
//! shared state; worker lock and condition waits cannot be canceled.

const std = @import("std");
const disk = @import("../io/io.zig");

pub const Job = struct {
    run: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    cond: std.Io.Condition = std.Io.Condition.init,
    queue: std.ArrayListUnmanaged(Job) = .empty,
    running: bool = false,
    stopping: bool = false,
    thread: ?std.Thread = null,
    timer: ?Job = null,
    timer_ns: u64 = 0,
    deadline: ?std.Io.Clock.Timestamp = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Worker {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn start(self: *Worker) std.Thread.SpawnError!void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    pub fn submit(self: *Worker, job: Job) error{ OutOfMemory, WorkerStopped }!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.WorkerStopped;
        try self.queue.append(self.allocator, job);
        self.cond.broadcast(self.io); // wake worker and idle-waiters alike: they share one cond
    }

    pub fn setTimer(self: *Worker, job: Job, interval_ns: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.timer = job;
        self.timer_ns = interval_ns;
        self.deadline = .fromNow(self.io, .{ .clock = .awake, .raw = .{ .nanoseconds = interval_ns } });
        self.cond.broadcast(self.io);
    }

    pub fn clearTimer(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.timer = null;
        self.deadline = null;
        self.cond.broadcast(self.io);
    }

    /// Barrier: returns once the queue is empty and no job is in flight.
    pub fn waitIdle(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.queue.items.len != 0 or self.running) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    /// Abandons whatever is still queued — close() calls this only
    /// after the final flush, when nothing worth keeping is pending.
    pub fn stop(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.queue.clearRetainingCapacity();
    }

    pub fn deinit(self: *Worker) void {
        if (self.thread != null) self.stop();
        self.queue.deinit(self.allocator);
    }
};

fn threadMain(self: *Worker) void {
    while (true) {
        self.mutex.lockUncancelable(self.io);
        var timer_due = false;
        while (!self.stopping) {
            if (self.deadline) |deadline| {
                timer_due = deadline.untilNow(self.io).raw.nanoseconds >= 0;
                if (timer_due) break;
            }
            if (self.queue.items.len != 0) break;
            if (self.deadline) |deadline| {
                self.cond.waitTimeout(self.io, &self.mutex, .{ .deadline = deadline }) catch {};
            } else {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
        }
        if (self.stopping) {
            self.mutex.unlock(self.io);
            return;
        }
        const take_timer = timer_due and self.queue.items.len == 0;
        const job = if (take_timer) self.timer.? else self.queue.orderedRemove(0);
        if (take_timer) self.deadline = .fromNow(self.io, .{ .clock = .awake, .raw = .{ .nanoseconds = self.timer_ns } });
        self.running = true;
        self.mutex.unlock(self.io);

        job.run(job.ctx);

        self.mutex.lockUncancelable(self.io);
        self.running = false;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
    }
}
// ========================= tests =========================

const Log = struct {
    buf: [8]u8 = undefined,
    len: usize = 0,
    active: std.atomic.Value(u32) = .init(0),
};

const LogJob = struct { log: *Log, id: u8 };

fn logRun(raw: *anyopaque) void {
    const j: *LogJob = @ptrCast(@alignCast(raw));
    const prev = j.log.active.fetchAdd(1, .monotonic);
    std.debug.assert(prev == 0); // serial means never two in flight
    j.log.buf[j.log.len] = j.id;
    j.log.len += 1;
    _ = j.log.active.fetchSub(1, .monotonic);
}

test "worker: jobs run serially and in submission order" {
    var w = Worker.init(std.testing.allocator, std.testing.io);
    defer w.deinit();
    try w.start();

    var log = Log{};
    var jobs: [8]LogJob = undefined;
    for (&jobs, 0..) |*j, i| {
        j.* = .{ .log = &log, .id = @intCast(i) };
        try w.submit(.{ .run = logRun, .ctx = j });
    }
    w.waitIdle();
    try std.testing.expectEqual(@as(usize, 8), log.len);
    for (0..8) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), log.buf[i]);
    w.stop();
}

const Counter = struct { n: usize = 0 };

fn countRun(raw: *anyopaque) void {
    const c: *Counter = @ptrCast(@alignCast(raw));
    c.n += 1;
}

test "worker: waitIdle is a barrier; submit after stop is refused" {
    var w = Worker.init(std.testing.allocator, std.testing.io);
    defer w.deinit();
    try w.start();

    var c = Counter{};
    for (0..4) |_| try w.submit(.{ .run = countRun, .ctx = &c });
    w.waitIdle();
    try std.testing.expectEqual(@as(usize, 4), c.n);

    w.stop();
    try std.testing.expectError(error.WorkerStopped, w.submit(.{ .run = countRun, .ctx = &c }));
}
