const std = @import("std");
const wiskdb = @import("wiskdb");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    var db = try wiskdb.Open(allocator, io, "out/example-collections", .{
        .create_if_missing = true,
        .db = .{ .durability = .sync },
    });
    defer db.deinit();

    var collections = wiskdb.Collections.init(&db, "example");
    try collections.hashSet("users", "alice", "Alice");
    try collections.hashSet("users", "bob", "Bob");
    const hash = try collections.hashScan("users");
    defer collections.freeHash(hash);

    try collections.zsetAdd("scores", "alice", 100);
    try collections.zsetAdd("scores", "bob", 90);
    try collections.zsetAdd("scores", "carol", 100);
    const ranked = try collections.zsetRange("scores", null, null);
    defer collections.freeZ(ranked);
    const top = try collections.zsetQuery("scores", null, null, null, true, 2);
    defer collections.freeZ(top);

    const stdout = std.Io.File.stdout();
    var buffer: [128]u8 = undefined;
    for (ranked) |item| {
        const line = try std.fmt.bufPrint(&buffer, "{s}={d}\n", .{ item.member, item.score });
        try stdout.writeStreamingAll(io, line);
    }
    try stdout.writeStreamingAll(io, "top:\n");
    for (top) |item| {
        const line = try std.fmt.bufPrint(&buffer, "{s}={d}\n", .{ item.member, item.score });
        try stdout.writeStreamingAll(io, line);
    }
    const report = try collections.verifyZset("scores");
    if (report.missing + report.stale + report.malformed != 0) {
        _ = try collections.rebuildZset("scores");
    }
    // Rebuild refuses malformed member scores with error.InvalidScore.
    try db.close();
}
