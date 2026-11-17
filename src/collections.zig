//! Hash and sorted-set operations over reserved, length-prefixed database keys.
//! One shared instance serializes mutations within its namespace; raw database
//! writes and separate instances do not participate in that lock.

const std = @import("std");
const Db = @import("db.zig").Db;

/// Reserve namespace for this wrapper; share one instance per namespace.
/// Db and namespace must outlive this value. Returned values use db.allocator.
/// Keep this instance at a stable address while calls are running. Names, fields
/// and members are arbitrary bytes; operations borrow their inputs until return.
pub const Collections = struct {
    db: *Db,
    namespace: []const u8,
    mutex: std.Io.Mutex = .init,

    pub fn init(db: *Db, namespace: []const u8) Collections {
        return .{ .db = db, .namespace = namespace };
    }

    /// Caller-owned encoded key, freed with db.allocator. Length prefixes keep
    /// binary namespaces/names distinct; H, M and S identify hash/member/score keys.
    /// Reserve these keys for this wrapper to preserve collection invariants.
    pub fn encodeKey(self: *Collections, kind: u8, name: []const u8, field: []const u8) ![]u8 {
        return @import("collections_key.zig").encode(self.db.allocator, self.namespace, kind, name, field);
    }

    /// Replace a field, serialized with increments/deletes through this instance.
    pub fn hashSet(self: *Collections, name: []const u8, field: []const u8, value: []const u8) !void {
        self.mutex.lockUncancelable(self.db.io);
        defer self.mutex.unlock(self.db.io);
        try self.hashSetUnlocked(name, field, value);
    }

    /// Caller holds mutex; hashIncr must keep its read and replacement together.
    fn hashSetUnlocked(self: *Collections, name: []const u8, field: []const u8, value: []const u8) !void {
        const encoded = try self.encodeKey('H', name, field);
        defer self.db.allocator.free(encoded);
        try self.db.put(encoded, value);
    }

    /// Caller-owned value or null; free a present value with db.allocator.
    pub fn hashGet(self: *Collections, name: []const u8, field: []const u8) !?[]const u8 {
        const encoded = try self.encodeKey('H', name, field);
        defer self.db.allocator.free(encoded);
        return self.db.get(encoded);
    }

    pub fn hashDelete(self: *Collections, name: []const u8, field: []const u8) !void {
        self.mutex.lockUncancelable(self.db.io);
        defer self.mutex.unlock(self.db.io);
        const encoded = try self.encodeKey('H', name, field);
        defer self.db.allocator.free(encoded);
        try self.db.delete(encoded);
    }
    pub fn hashHas(self: *Collections, name: []const u8, field: []const u8) !bool {
        const value = try self.hashGet(name, field);
        if (value) |v| self.db.allocator.free(v);
        return value != null;
    }
    /// Atomically add delta under this instance's lock; a missing field starts
    /// at zero. Counters are eight-byte big-endian u64 values. Invalid lengths
    /// return InvalidValue; underflow/overflow returns ValueOverflow without a write.
    pub fn hashIncr(self: *Collections, name: []const u8, field: []const u8, delta: i64) !u64 {
        self.mutex.lockUncancelable(self.db.io);
        defer self.mutex.unlock(self.db.io);
        const current = try self.hashGet(name, field);
        const old: u64 = if (current) |raw| blk: {
            defer self.db.allocator.free(raw);
            if (raw.len != 8) return error.InvalidValue;
            break :blk std.mem.readInt(u64, raw[0..8], .big);
        } else 0;
        const sum = @as(i128, @intCast(old)) + @as(i128, delta);
        if (sum < 0 or sum > std.math.maxInt(u64)) return error.ValueOverflow;
        const next: u64 = @intCast(sum);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, next, .big);
        try self.hashSetUnlocked(name, field, &bytes);
        return next;
    }
    /// Atomically increment a u64 score; a missing member starts at zero.
    /// Underflow/overflow returns ScoreOverflow without submitting an update.
    pub fn zsetIncr(self: *Collections, name: []const u8, member: []const u8, delta: i64) !u64 {
        return @import("collections_zset.zig").incr(self, name, member, delta);
    }
    /// Replace a member's score and sorting index together in one database batch.
    pub fn zsetAdd(self: *Collections, name: []const u8, member: []const u8, score: u64) !void {
        return @import("collections_zset.zig").update(self, name, member, score);
    }
    pub fn zsetScore(self: *Collections, name: []const u8, member: []const u8) !?u64 {
        return @import("collections_zset.zig").score(self, name, member);
    }
    pub fn zsetRemove(self: *Collections, name: []const u8, member: []const u8) !void {
        return @import("collections_zset.zig").update(self, name, member, null);
    }
    pub const ZsetReport = @import("collections_verify.zig").Report;
    /// Reports missing/stale/malformed indexes at one snapshot.
    pub fn verifyZset(self: *Collections, name: []const u8) !ZsetReport {
        return @import("collections_verify.zig").run(self, name, false);
    }
    /// Rebuild sorting indexes in one batch; return the pre-repair report.
    /// Both indexes are materialized in memory, and large repairs can exceed the
    /// batch-size limit. Malformed member scores return InvalidScore without repair.
    pub fn rebuildZset(self: *Collections, name: []const u8) !ZsetReport {
        return @import("collections_verify.zig").run(self, name, true);
    }
    pub const HashItem = @import("collections_scan.zig").HashItem;
    pub const ZCursor = @import("collections_scan.zig").Cursor;
    pub const ZItem = @import("collections_scan.zig").ZItem;
    /// Owned fields in byte order at one snapshot; release with freeHash.
    pub fn hashScan(self: *Collections, name: []const u8) ![]HashItem {
        return @import("collections_scan.zig").hashScan(self, name);
    }
    pub fn freeHash(self: *Collections, items: []HashItem) void {
        @import("collections_scan.zig").freeHash(self, items);
    }
    /// Owned members ordered by (score, member), reversed when requested. Score
    /// bounds are inclusive; null is unbounded. Cursor is exclusive, limit zero
    /// is unlimited. Each call captures a new snapshot; release with freeZ.
    pub fn zsetQuery(self: *Collections, name: []const u8, min: ?u64, max: ?u64, cursor: ?ZCursor, reverse: bool, limit: usize) ![]ZItem {
        return @import("collections_scan.zig").zsetQuery(self, name, min, max, cursor, reverse, limit);
    }
    pub fn zsetRevRange(self: *Collections, name: []const u8, min: ?u64, max: ?u64) ![]ZItem {
        return @import("collections_scan.zig").zsetRevRange(self, name, min, max);
    }
    pub fn zsetRange(self: *Collections, name: []const u8, min: ?u64, max: ?u64) ![]ZItem {
        return @import("collections_scan.zig").zsetRange(self, name, min, max);
    }
    pub fn freeZ(self: *Collections, items: []ZItem) void {
        @import("collections_scan.zig").freeZ(self, items);
    }
};

test "zset rebuild: reopen preserves repairs and isolates collections" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
        defer db.deinit();
        var c = Collections.init(&db, "repair");
        var other = Collections.init(&db, "other");
        try c.zsetAdd("rank", "alice", 10);
        try c.zsetAdd("else", "bob", 20);
        try other.zsetAdd("rank", "carol", 30);
        const broken = try c.encodeKey('S', "rank", "bad");
        defer db.allocator.free(broken);
        try db.put(broken, "");
        _ = try c.rebuildZset("rank");
        try db.close();
    }
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    var c = Collections.init(&db, "repair");
    var other = Collections.init(&db, "other");
    const report = try c.verifyZset("rank");
    try std.testing.expectEqual(@as(usize, 1), report.members);
    try std.testing.expectEqual(@as(usize, 0), report.missing + report.stale + report.malformed);
    const rows = try c.zsetRange("rank", null, null);
    defer c.freeZ(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("alice", rows[0].member);
    try std.testing.expectEqual(@as(u64, 10), rows[0].score);
    const same_namespace = try c.verifyZset("else");
    const other_namespace = try other.verifyZset("rank");
    try std.testing.expectEqual(@as(usize, 1), same_namespace.members);
    try std.testing.expectEqual(@as(usize, 1), other_namespace.members);
    try std.testing.expectEqual(@as(usize, 0), same_namespace.missing + other_namespace.missing);
}

test "zset verify: detect, rebuild and reject corrupt member scores" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    var c = Collections.init(&db, "verify");
    try c.zsetAdd("rank", "alice", 10);
    var suffix: [13]u8 = undefined;
    std.mem.writeInt(u64, suffix[0..8], 10, .big);
    @memcpy(suffix[8..], "alice");
    const valid = try c.encodeKey('S', "rank", &suffix);
    defer db.allocator.free(valid);
    try db.delete(valid);
    std.mem.writeInt(u64, suffix[0..8], 9, .big);
    const stale = try c.encodeKey('S', "rank", &suffix);
    defer db.allocator.free(stale);
    try db.put(stale, "");
    const malformed = try c.encodeKey('S', "rank", "bad");
    defer db.allocator.free(malformed);
    try db.put(malformed, "bad");
    const report = try c.verifyZset("rank");
    try std.testing.expectEqual(@as(usize, 1), report.missing);
    try std.testing.expectEqual(@as(usize, 1), report.stale);
    try std.testing.expectEqual(@as(usize, 1), report.malformed);
    _ = try c.rebuildZset("rank");
    try db.flush();
    const clean = try c.verifyZset("rank");
    try std.testing.expectEqual(@as(usize, 0), clean.missing + clean.stale + clean.malformed);
    const member = try c.encodeKey('M', "rank", "alice");
    defer db.allocator.free(member);
    try db.put(member, "bad");
    try std.testing.expectError(error.InvalidScore, c.rebuildZset("rank"));
    const preserved = (try db.get(valid)) orelse return error.TestUnexpectedResult;
    defer db.allocator.free(preserved);
}

test "collections: has and numeric increment for hash and zset" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    var c = Collections.init(&db, "ns");
    try std.testing.expect(!(try c.hashHas("h", "n")));
    try std.testing.expectEqual(@as(u64, 5), try c.hashIncr("h", "n", 5));
    try std.testing.expectEqual(@as(u64, 3), try c.hashIncr("h", "n", -2));
    try std.testing.expect(try c.hashHas("h", "n"));
    try std.testing.expectError(error.ValueOverflow, c.hashIncr("h", "n", -4));
    try std.testing.expectEqual(@as(u64, 7), try c.zsetIncr("z", "m", 7));
    try std.testing.expectEqual(@as(u64, 4), try c.zsetIncr("z", "m", -3));
    try std.testing.expectEqual(@as(?u64, 4), try c.zsetScore("z", "m"));
    try std.testing.expectError(error.ScoreOverflow, c.zsetIncr("z", "m", -5));
}

test "hash: concurrent set and delete serialize with increments" {
    const CounterReadGate = struct {
        parent: std.mem.Allocator,
        paused: std.atomic.Value(bool) = .init(false),
        resume_op: std.atomic.Value(bool) = .init(false),

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.parent.rawAlloc(len, alignment, ra);
        }
        fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.parent.rawResize(memory, alignment, len, ra);
        }
        fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.parent.rawRemap(memory, alignment, len, ra);
        }
        fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            // hashIncr releases its owned counter after decoding the old value,
            // before submitting its replacement. Encoded keys are longer than 8.
            if (memory.len == 8 and !self.paused.swap(true, .acq_rel)) {
                while (!self.resume_op.load(.acquire)) std.atomic.spinLoopHint();
            }
            self.parent.rawFree(memory, alignment, ra);
        }
    };
    const Operation = struct {
        c: *Collections,
        kind: enum { increment, set, delete },
        result: ?u64 = null,
        failure: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            self.apply() catch |err| {
                self.failure = err;
            };
        }
        fn apply(self: *@This()) !void {
            switch (self.kind) {
                .increment => self.result = try self.c.hashIncr("h", "n", 1),
                .delete => try self.c.hashDelete("h", "n"),
                .set => {
                    var bytes: [8]u8 = undefined;
                    std.mem.writeInt(u64, &bytes, 100, .big);
                    try self.c.hashSet("h", "n", &bytes);
                },
            }
        }
    };
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer db.deinit();
    var c = Collections.init(&db, "concurrent-hash");
    for ([_]bool{ false, true }) |remove| {
        var initial: [8]u8 = undefined;
        std.mem.writeInt(u64, &initial, 5, .big);
        try c.hashSet("h", "n", &initial);
        const saved_allocator = db.allocator;
        var gate = CounterReadGate{ .parent = saved_allocator };
        db.allocator = gate.allocator();
        defer db.allocator = saved_allocator;
        var increment = Operation{ .c = &c, .kind = .increment };
        var mutation = Operation{ .c = &c, .kind = if (remove) .delete else .set };
        var blocked = false;
        {
            const increment_thread = try std.Thread.spawn(.{}, Operation.run, .{&increment});
            defer {
                gate.resume_op.store(true, .release);
                increment_thread.join();
            }
            while (!gate.paused.load(.acquire) and !increment.done.load(.acquire)) std.atomic.spinLoopHint();
            if (!gate.paused.load(.acquire)) return error.CounterReadNotObserved;
            const mutation_thread = try std.Thread.spawn(.{}, Operation.run, .{&mutation});
            defer {
                gate.resume_op.store(true, .release);
                mutation_thread.join();
            }
            // Wait for an actual lock attempt, not a scheduler delay. With the
            // old missing mutation lock, done wins and the regression fails.
            while (c.mutex.state.load(.acquire) != .contended and !mutation.done.load(.acquire)) std.atomic.spinLoopHint();
            blocked = c.mutex.state.load(.acquire) == .contended and !mutation.done.load(.acquire);
        }
        if (increment.failure) |err| return err;
        if (mutation.failure) |err| return err;
        try std.testing.expect(blocked);
        try std.testing.expectEqual(@as(?u64, 6), increment.result);
        const raw = try c.hashGet("h", "n");
        defer if (raw) |bytes| db.allocator.free(bytes);
        const final: ?u64 = if (raw) |bytes| std.mem.readInt(u64, bytes[0..8], .big) else null;
        try std.testing.expectEqual(if (remove) @as(?u64, null) else @as(?u64, 100), final);
    }
}

test "collections scan: hash fields and zset score ordering with stale index removal" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    var c = Collections.init(&db, "ns");
    try c.hashSet("h", "b", "2");
    try c.hashSet("h", "a", "1");
    try c.hashSet("other", "c", "3");
    const hs = try c.hashScan("h");
    defer c.freeHash(hs);
    try std.testing.expectEqual(@as(usize, 2), hs.len);
    try std.testing.expectEqualStrings("a", hs[0].field);
    try std.testing.expectEqualStrings("1", hs[0].value);
    try c.zsetAdd("z", "a", 20);
    try c.zsetAdd("z", "b", 10);
    try c.zsetAdd("z", "c", 10);
    try c.zsetAdd("z", "b", 30);
    try c.zsetRemove("z", "a");
    const zs = try c.zsetRange("z", null, null);
    defer c.freeZ(zs);
    try std.testing.expectEqual(@as(usize, 2), zs.len);
    try std.testing.expectEqualStrings("c", zs[0].member);
    try std.testing.expectEqual(@as(u64, 10), zs[0].score);
    try std.testing.expectEqualStrings("b", zs[1].member);
    try std.testing.expectEqual(@as(u64, 30), zs[1].score);
    const bounded = try c.zsetRange("z", 20, 40);
    defer c.freeZ(bounded);
    try std.testing.expectEqual(@as(usize, 1), bounded.len);
    const page = try c.zsetQuery("z", null, null, .{ .score = 10, .member = "c" }, false, 1);
    defer c.freeZ(page);
    try std.testing.expectEqual(@as(usize, 1), page.len);
    try std.testing.expectEqualStrings("b", page[0].member);
    const rev = try c.zsetRevRange("z", null, null);
    defer c.freeZ(rev);
    try std.testing.expectEqualStrings("b", rev[0].member);
    try std.testing.expectEqualStrings("c", rev[1].member);
}

test "hash: binary boundaries, empty values, deletion and reopen" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try Db.open(alloc, std.testing.io, tmp.dir, .{});
        defer db.deinit();
        var c = Collections.init(&db, "test\x00");
        try c.hashSet("a", "bc", "first");
        try c.zsetAdd("rank", "alice", 10);
        try c.zsetAdd("rank", "alice", 20);
        try c.zsetAdd("rank", "gone", 0);
        try c.zsetRemove("rank", "gone");
        try c.hashSet("ab", "c", "");
        try c.hashDelete("a", "bc");
        try db.close();
    }
    var db = try Db.open(alloc, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    var c = Collections.init(&db, "test\x00");
    try std.testing.expect((try c.hashGet("a", "bc")) == null);
    try std.testing.expectEqual(@as(?u64, 20), try c.zsetScore("rank", "alice"));
    try std.testing.expect((try c.zsetScore("rank", "gone")) == null);
    const value = (try c.hashGet("ab", "c")) orelse return error.TestUnexpectedResult;
    defer alloc.free(value);
    try std.testing.expectEqualStrings("", value);
    var other = Collections.init(&db, "other");
    try std.testing.expect((try other.hashGet("ab", "c")) == null);
}
