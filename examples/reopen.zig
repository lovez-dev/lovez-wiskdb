const std = @import("std");
const wiskdb = @import("wiskdb");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out/example-reopen");
    const dir = try cwd.openDir(io, "out/example-reopen", .{ .iterate = true });
    defer dir.close(io);
    {
        var db = try wiskdb.Db.open(init.gpa, io, dir, .{});
        defer db.deinit();
        const value: [600]u8 = @splat('v');
        try db.put("large-value", &value);
        try db.put("durable", "reopen me");
        try db.close();
    }
    var db = try wiskdb.Db.open(init.gpa, io, dir, .{});
    defer db.deinit();
    const value = (try db.get("large-value")) orelse return error.MissingKey;
    defer init.gpa.free(value);
    const message = (try db.get("durable")) orelse return error.MissingKey;
    defer init.gpa.free(message);
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, message);
    try stdout.writeStreamingAll(io, "\n");
    if (value.len != 600) return error.InvalidValueLength;
    try db.close();
}
