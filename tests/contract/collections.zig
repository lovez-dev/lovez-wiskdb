//! Collections preserve the previous value and indexes when numeric updates fail.
const std = @import("std");
const wiskdb = @import("wiskdb");

test "contract: hash: overflow underflow and invalid counter encoding leave values unchanged" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try wiskdb.Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async });
    defer db.deinit();
    var c = wiskdb.Collections.init(&db, "counter-errors");
    var maximum: [8]u8 = @splat(0xff);
    try c.hashSet("h", "max", &maximum);
    try std.testing.expectError(error.ValueOverflow, c.hashIncr("h", "max", 1));
    try std.testing.expectEqual(std.math.maxInt(u64), try c.hashIncr("h", "max", 0));
    try std.testing.expectError(error.ValueOverflow, c.hashIncr("h", "missing", -1));
    try std.testing.expect(!(try c.hashHas("h", "missing")));
    try c.hashSet("h", "text", "not-an-integer");
    try std.testing.expectError(error.InvalidValue, c.hashIncr("h", "text", 1));
    const original = (try c.hashGet("h", "text")).?;
    defer std.testing.allocator.free(original);
    try std.testing.expectEqualStrings("not-an-integer", original);
}

test "contract: zset: rejected score increments preserve both indexes including the maximum score" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try wiskdb.Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async });
    defer db.deinit();
    var c = wiskdb.Collections.init(&db, "score-errors");
    try c.zsetAdd("z", "max", std.math.maxInt(u64));
    try std.testing.expectError(error.ScoreOverflow, c.zsetIncr("z", "max", 1));
    try std.testing.expectError(error.ScoreOverflow, c.zsetIncr("z", "missing", -1));
    try std.testing.expect((try c.zsetScore("z", "missing")) == null);
    try db.flush();
    const rows = try c.zsetRange("z", std.math.maxInt(u64), std.math.maxInt(u64));
    defer c.freeZ(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("max", rows[0].member);
    try std.testing.expectEqual(std.math.maxInt(u64), rows[0].score);
    const report = try c.verifyZset("z");
    try std.testing.expectEqual(@as(usize, 1), report.members);
    try std.testing.expectEqual(@as(usize, 0), report.missing + report.stale + report.malformed);
}

test "contract: zset: exclusive cursors distinguish an empty member and binary extensions in both directions" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try wiskdb.Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async });
    defer db.deinit();
    var c = wiskdb.Collections.init(&db, "binary-cursors");
    const members = [_][]const u8{ "", "\x00", "\x00\x00", "\xff" };
    for (members) |member| try c.zsetAdd("z", member, 0);
    try db.flush();
    for ([_]bool{ false, true }) |reverse| {
        for (0..members.len - 1) |i| {
            const current = if (reverse) members.len - 1 - i else i;
            const next = if (reverse) current - 1 else current + 1;
            const rows = try c.zsetQuery("z", 0, 0, .{ .score = 0, .member = members[current] }, reverse, 1);
            defer c.freeZ(rows);
            try std.testing.expectEqual(@as(usize, 1), rows.len);
            try std.testing.expectEqualStrings(members[next], rows[0].member);
        }
        const last = if (reverse) members[0] else members[members.len - 1];
        const exhausted = try c.zsetQuery("z", null, null, .{ .score = 0, .member = last }, reverse, 1);
        defer c.freeZ(exhausted);
        try std.testing.expectEqual(@as(usize, 0), exhausted.len);
    }
}
