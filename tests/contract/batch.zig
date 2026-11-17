//! Batch order and rejection are checked through reads, flushes and reopening.
const std = @import("std");
const wiskdb = @import("wiskdb");

fn expectFinal(db: *wiskdb.Db) !void {
    const value = (try db.get("repeat")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("last", value);
    try std.testing.expect((try db.get("deleted")) == null);
    const rows = try db.scan(null, null);
    defer db.freeScan(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("repeat", rows[0].key);
}

test "contract: batch: repeated keys follow operation order through flush and reopen" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try wiskdb.Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async });
        defer db.deinit();
        try db.put("deleted", "older");
        try db.flush();
        try db.writeBatch(&.{
            .{ .put = .{ .key = "repeat", .value = "first" } },
            .{ .del = "repeat" },
            .{ .put = .{ .key = "deleted", .value = "temporary" } },
            .{ .put = .{ .key = "repeat", .value = "last" } },
            .{ .del = "deleted" },
        });
        try db.writeBatch(&.{});
        try expectFinal(&db);
        try db.flush();
        try expectFinal(&db);
        try db.close();
    }
    var reopened = try wiskdb.Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer reopened.deinit();
    try expectFinal(&reopened);
}

test "contract: batch: an oversized inline batch rejects earlier operations and permits later writes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try wiskdb.Db.open(alloc, std.testing.io, tmp.dir, .{
        .durability = .async,
        .value_threshold = 3 * 1024 * 1024,
    });
    defer db.deinit();
    try db.put("existing", "original");
    const too_large = try alloc.alloc(u8, 2 * 1024 * 1024);
    defer alloc.free(too_large);
    @memset(too_large, 'x');
    try std.testing.expectError(error.BatchTooLarge, db.writeBatch(&.{
        .{ .put = .{ .key = "existing", .value = "uncommitted" } },
        .{ .put = .{ .key = "oversized", .value = too_large } },
    }));
    const original = (try db.get("existing")).?;
    defer alloc.free(original);
    try std.testing.expectEqualStrings("original", original);
    try std.testing.expect((try db.get("oversized")) == null);
    try db.put("later", "accepted");
    const later = (try db.get("later")).?;
    defer alloc.free(later);
    try std.testing.expectEqualStrings("accepted", later);
    try db.flush();
}
