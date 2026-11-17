const std = @import("std");
const Db = @import("db.zig").Db;

test "memory stats exclude caller results and drain on close" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async });
    defer db.deinit();
    try db.put("key", "value");
    const before = db.stat();
    try std.testing.expect(before.allocated_bytes > 0);
    const value = (try db.get("key")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqual(before.allocated_bytes, db.stat().allocated_bytes);
    try std.testing.expectEqualStrings("value", value);
    try db.close();
    try std.testing.expectEqual(@as(usize, 0), db.stat().allocated_bytes);
    try std.testing.expect(db.stat().peak_allocated_bytes > 0);
    try db.close();
}
