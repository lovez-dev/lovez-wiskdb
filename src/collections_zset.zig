const std = @import("std");
const Collections = @import("collections.zig").Collections;
const keys = @import("collections_key.zig");

pub fn score(c: *Collections, name: []const u8, member: []const u8) !?u64 {
    const key = try c.encodeKey('M', name, member);
    defer c.db.allocator.free(key);
    const value = (try c.db.get(key)) orelse return null;
    defer c.db.allocator.free(value);
    if (value.len != 8) return error.InvalidScore;
    return std.mem.readInt(u64, value[0..8], .big);
}

fn index(c: *Collections, name: []const u8, member: []const u8, value: u64) ![]u8 {
    return keys.scoreKey(c.db.allocator, c.namespace, name, member, value);
}

/// Caller holds the namespace lock across reading old and submitting this batch.
fn updateKnown(c: *Collections, name: []const u8, member: []const u8, old: ?u64, value: ?u64) !void {
    if (old == value) return;
    const key = try c.encodeKey('M', name, member);
    defer c.db.allocator.free(key);
    const previous = if (old) |s| try index(c, name, member, s) else null;
    defer if (previous) |p| c.db.allocator.free(p);
    const next = if (value) |s| try index(c, name, member, s) else null;
    defer if (next) |p| c.db.allocator.free(p);
    var ops: [3]@import("db.zig").Op = undefined;
    var n: usize = 0;
    if (previous) |p| {
        ops[n] = .{ .del = p };
        n += 1;
    }
    var bytes: [8]u8 = undefined;
    if (value) |s| {
        std.mem.writeInt(u64, &bytes, s, .big);
        ops[n] = .{ .put = .{ .key = key, .value = &bytes } };
        n += 1;
        ops[n] = .{ .put = .{ .key = next.?, .value = "" } };
        n += 1;
    } else {
        ops[n] = .{ .del = key };
        n += 1;
    }
    try c.db.writeBatch(ops[0..n]);
}

pub fn update(c: *Collections, name: []const u8, member: []const u8, value: ?u64) !void {
    c.mutex.lockUncancelable(c.db.io);
    defer c.mutex.unlock(c.db.io);
    try updateKnown(c, name, member, try score(c, name, member), value);
}

/// Atomic score increment under the namespace lock; missing member starts at 0.
pub fn incr(c: *Collections, name: []const u8, member: []const u8, delta: i64) !u64 {
    c.mutex.lockUncancelable(c.db.io);
    defer c.mutex.unlock(c.db.io);
    const old = try score(c, name, member);
    const sum = @as(i128, @intCast(old orelse 0)) + @as(i128, delta);
    if (sum < 0 or sum > std.math.maxInt(u64)) return error.ScoreOverflow;
    const next: u64 = @intCast(sum);
    try updateKnown(c, name, member, old, next);
    return next;
}

test "zset increment: single lookup and distinct missing versus zero score" {
    const Db = @import("db.zig").Db;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .profile_read_locks = true, .automatic_gc = false });
    defer db.deinit();
    var c = Collections.init(&db, "\x00\xff");
    const before = db.readLockStats().view_capture.acquisitions;
    try std.testing.expectEqual(@as(u64, 0), try incr(&c, "z", "\xff\x00", 0));
    try std.testing.expectEqual(before + 1, db.readLockStats().view_capture.acquisitions);
    try std.testing.expectEqual(@as(?u64, 0), try score(&c, "z", "\xff\x00"));
    const created = db.last_seq.load(.acquire);
    const read_before = db.readLockStats().view_capture.acquisitions;
    try std.testing.expectEqual(@as(u64, 0), try incr(&c, "z", "\xff\x00", 0));
    try std.testing.expectEqual(read_before + 1, db.readLockStats().view_capture.acquisitions);
    try std.testing.expectEqual(created, db.last_seq.load(.acquire));
    const report = try c.verifyZset("z");
    try std.testing.expectEqual(@as(usize, 1), report.members);
    try std.testing.expectEqual(@as(usize, 0), report.missing + report.stale + report.malformed);
    const increment_before = db.readLockStats().view_capture.acquisitions;
    try std.testing.expectEqual(@as(u64, 9), try incr(&c, "z", "\xff\x00", 9));
    try std.testing.expectEqual(increment_before + 1, db.readLockStats().view_capture.acquisitions);
    const rows = try c.zsetRange("z", null, null);
    defer c.freeZ(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(u64, 9), rows[0].score);
    try std.testing.expectEqualSlices(u8, "\xff\x00", rows[0].member);
}
