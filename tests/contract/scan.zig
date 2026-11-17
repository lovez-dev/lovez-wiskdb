//! Binary bounds are byte-ordered and half-open in both scan directions.
const std = @import("std");
const wiskdb = @import("wiskdb");

fn expectBinaryBounds(db: *wiskdb.Db) !void {
    const forward = try db.scan("\x00", "\xff");
    defer db.freeScan(forward);
    try std.testing.expectEqual(@as(usize, 2), forward.len);
    try std.testing.expectEqualStrings("\x00", forward[0].key);
    try std.testing.expectEqualStrings("\x00\x01", forward[1].key);
    try std.testing.expectEqualStrings("updated", forward[0].value);
    const reverse = try db.scanWithOptions(.{ .start = "\x00", .end = "\xff", .reverse = true, .limit = 1 });
    defer db.freeScan(reverse);
    try std.testing.expectEqual(@as(usize, 1), reverse.len);
    try std.testing.expectEqualStrings("\x00\x01", reverse[0].key);
}

test "contract: scan: binary bounds and reverse limits exclude tombstones across storage generations" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try wiskdb.Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async });
        defer db.deinit();
        for ([_][]const u8{ "", "\x00", "\x00\x00", "\x00\x01", "\xff" }) |key| try db.put(key, "original");
        try db.flush();
        try db.put("\x00", "updated");
        try db.delete("\x00\x00");
        try expectBinaryBounds(&db);
        try db.flush();
        try expectBinaryBounds(&db);
        try db.close();
    }
    var reopened = try wiskdb.Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer reopened.deinit();
    try expectBinaryBounds(&reopened);
}

test "contract: scan: empty and inverted ranges return owned empty results and zero limit is unlimited" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try wiskdb.Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async });
    defer db.deinit();
    try db.put("", "empty-key");
    try db.put("a", "value");
    for ([_]bool{ false, true }) |reverse| {
        const empty = try db.scanWithOptions(.{ .start = "a", .end = "a", .reverse = reverse });
        defer db.freeScan(empty);
        try std.testing.expectEqual(@as(usize, 0), empty.len);
        const inverted = try db.scanWithOptions(.{ .start = "z", .end = "a", .reverse = reverse });
        defer db.freeScan(inverted);
        try std.testing.expectEqual(@as(usize, 0), inverted.len);
        const all = try db.scanWithOptions(.{ .reverse = reverse, .limit = 0 });
        defer db.freeScan(all);
        try std.testing.expectEqual(@as(usize, 2), all.len);
        try std.testing.expectEqualStrings("", all[if (reverse) 1 else 0].key);
    }
}
