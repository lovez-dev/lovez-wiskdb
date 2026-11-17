const std = @import("std");
const wiskdb = @import("wiskdb");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var db = try wiskdb.Open(init.gpa, io, "out/example-batch", .{ .create_if_missing = true, .db = .{ .durability = .sync } });
    defer db.deinit();

    const operations = [_]wiskdb.Op{
        .{ .put = .{ .key = "account:1", .value = "active" } },
        .{ .put = .{ .key = "account:2", .value = "pending" } },
        .{ .del = "account:3" },
    };
    try db.writeBatch(&operations);
    const account = (try db.get("account:2")) orelse return error.MissingKey;
    defer init.gpa.free(account);
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, account);
    try stdout.writeStreamingAll(io, "\n");
    try db.close();
}
