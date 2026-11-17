//! Public lifetime contracts: shutdown rejects work while caller-owned data survives.
const std = @import("std");
const wiskdb = @import("wiskdb");

test "contract: lifecycle: closed databases reject every operation and repeated close is harmless" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try wiskdb.Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async });
    defer db.deinit();
    try db.put("key", "value");
    try db.close();
    try std.testing.expectError(error.DbClosed, db.get("key"));
    try std.testing.expectError(error.DbClosed, db.put("key", "replacement"));
    try std.testing.expectError(error.DbClosed, db.delete("key"));
    try std.testing.expectError(error.DbClosed, db.writeBatch(&.{}));
    try std.testing.expectError(error.DbClosed, db.scan(null, null));
    try std.testing.expectError(error.DbClosed, db.scanWithOptions(.{ .limit = 1 }));
    try std.testing.expectError(error.DbClosed, db.sync());
    try std.testing.expectError(error.DbClosed, db.flush());
    try std.testing.expectError(error.DbClosed, db.collectGarbage());
    try db.close();

    // Db.open borrows this handle; releasing the database lock permits reopening.
    var reopened = try wiskdb.Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer reopened.deinit();
    const value = (try reopened.get("key")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("value", value);
}

test "contract: lifecycle: returned inline and external values remain owned after overwrite and close" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try wiskdb.Db.open(alloc, std.testing.io, tmp.dir, .{ .durability = .async, .value_threshold = 8 });
    defer db.deinit();
    try db.put("inline", "small");
    try db.put("external", "eight-or-more");
    const small = (try db.get("inline")).?;
    defer alloc.free(small);
    const large = (try db.get("external")).?;
    defer alloc.free(large);
    try db.put("inline", "new");
    try db.delete("external");
    try db.close();
    try std.testing.expectEqualStrings("small", small);
    try std.testing.expectEqualStrings("eight-or-more", large);
}
