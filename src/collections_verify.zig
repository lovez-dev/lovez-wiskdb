const std = @import("std");
const Collections = @import("collections.zig").Collections;
const Op = @import("db.zig").Op;
const keys = @import("collections_key.zig");

pub const Report = struct { members: usize = 0, missing: usize = 0, stale: usize = 0, malformed: usize = 0 };

/// Inspect both indexes at one snapshot. Repair trusts only valid member scores.
pub fn run(c: *Collections, name: []const u8, repair: bool) !Report {
    c.mutex.lockUncancelable(c.db.io);
    defer c.mutex.unlock(c.db.io);
    const alloc = c.db.allocator;
    const mp = try c.encodeKey('M', name, "");
    defer alloc.free(mp);
    const sp = try c.encodeKey('S', name, "");
    defer alloc.free(sp);
    const end = try @import("collections_scan.zig").prefixEnd(alloc, sp);
    defer alloc.free(end);
    const rows = try c.db.scan(mp, end);
    defer c.db.freeScan(rows);
    var expected: std.StringHashMapUnmanaged(bool) = .empty;
    defer {
        var key_iter = expected.keyIterator();
        while (key_iter.next()) |key| alloc.free(key.*);
        expected.deinit(alloc);
    }
    var ops: std.ArrayListUnmanaged(Op) = .empty;
    defer ops.deinit(alloc);
    var report = Report{};
    var invalid_members = false;
    for (rows) |row| {
        if (!std.mem.startsWith(u8, row.key, mp)) continue;
        if (row.value.len != 8) {
            report.malformed += 1;
            invalid_members = true;
            continue;
        }
        report.members += 1;
        const key = try keys.scoreSuffix(alloc, sp, std.mem.readInt(u64, row.value[0..8], .big), row.key[mp.len..], false);
        errdefer alloc.free(key);
        try expected.put(alloc, key, false);
    }
    for (rows) |row| {
        if (!std.mem.startsWith(u8, row.key, sp)) continue;
        if (repair) try ops.append(alloc, .{ .del = row.key });
        if (row.key.len < sp.len + 8 or row.value.len != 0) {
            report.malformed += 1;
            continue;
        }
        if (expected.getPtr(row.key)) |found| found.* = true else report.stale += 1;
    }
    var entries = expected.iterator();
    while (entries.next()) |entry| {
        if (!entry.value_ptr.*) report.missing += 1;
        if (repair) try ops.append(alloc, .{ .put = .{ .key = entry.key_ptr.*, .value = "" } });
    }
    if (repair) {
        if (invalid_members) return error.InvalidScore;
        if (ops.items.len > 0) try c.db.writeBatch(ops.items);
    }
    return report;
}

test "zset verify and rebuild: caller allocation failures preserve indexes" {
    const Db = @import("db.zig").Db;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    var c = Collections.init(&db, "repair-oom");
    try c.zsetAdd("rank", "a", 7);
    var suffix: [9]u8 = undefined;
    std.mem.writeInt(u64, suffix[0..8], 7, .big);
    suffix[8] = 'a';
    const valid = try c.encodeKey('S', "rank", &suffix);
    defer db.allocator.free(valid);
    const stale = try c.encodeKey('S', "rank", "bad");
    defer db.allocator.free(stale);
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, target: *Collections, good: []const u8, bad: []const u8, repair: bool) !void {
            // Restore the same damaged fixture before each injected failure.
            try target.db.delete(good);
            try target.db.put(bad, "");
            const saved = target.db.allocator;
            target.db.allocator = allocator;
            const result = blk: {
                defer target.db.allocator = saved;
                break :blk @import("collections_verify.zig").run(target, "rank", repair);
            };
            if (result) |report| {
                try std.testing.expectEqual(@as(usize, 1), report.missing);
                try std.testing.expectEqual(@as(usize, 1), report.malformed);
                const after = try target.verifyZset("rank");
                try std.testing.expectEqual(@as(usize, if (repair) 0 else 1), after.missing);
                try std.testing.expectEqual(@as(usize, if (repair) 0 else 1), after.malformed);
            } else |err| {
                const still_bad = (try target.db.get(bad)) orelse return error.IndexChanged;
                defer saved.free(still_bad);
                const unexpected = try target.db.get(good);
                if (unexpected) |value| {
                    saved.free(value);
                    return error.IndexChanged;
                }
                try std.testing.expectEqual(@as(?u64, 7), try target.zsetScore("rank", "a"));
                return err;
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{ &c, valid, stale, false });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{ &c, valid, stale, true });
}
