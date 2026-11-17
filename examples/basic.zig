const std = @import("std");
const wiskdb = @import("wiskdb");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var db = try wiskdb.Open(init.gpa, io, "out/example-basic", .{ .create_if_missing = true, .db = .{ .durability = .sync } });
    defer db.deinit();

    try db.put("language", "Zig");
    const batch = [_]wiskdb.Op{
        .{ .put = .{ .key = "engine", .value = "wiskdb" } },
        .{ .put = .{ .key = "version", .value = "0.1" } },
    };
    try db.writeBatch(&batch);

    const value = (try db.get("language")) orelse return error.MissingKey;
    defer init.gpa.free(value);
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, value);
    try stdout.writeStreamingAll(io, "\n");

    try db.delete("language");
    if (try db.get("language")) |unexpected| {
        init.gpa.free(unexpected);
        return error.DeleteFailed;
    }
    try db.close();
}
