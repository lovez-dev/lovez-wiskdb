//! Crash-recovery fixture with seed, churn and verification modes.
const std = @import("std");
const wiskdb = @import("wiskdb");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 and args.len != 4) return error.ExpectedModeAndDirectory;
    const strict = args.len == 4 and std.mem.eql(u8, args[3], "strict");
    if (args.len == 4 and !strict) return error.UnknownOption;
    if (strict and !wiskdb.directory_sync_supported) return error.UnsupportedDirectorySync;
    const mode = args[1];
    const io = init.io;
    try std.Io.Dir.cwd().createDirPath(io, args[2]);
    if (strict) {
        const parent_path = std.fs.path.dirname(args[2]) orelse ".";
        const parent = try std.Io.Dir.cwd().openDir(io, parent_path, .{});
        defer parent.close(io);
        if (try wiskdb.syncDirectory(parent, io) != .synced) return error.UnsupportedDirectorySync;
    }
    const dir = try std.Io.Dir.cwd().openDir(io, args[2], .{ .iterate = true });
    defer dir.close(io);
    var db = try wiskdb.Db.open(init.gpa, io, dir, .{
        .require_directory_sync = strict,
        .durability = .sync,
        .write_buffer_size = 512,
        .max_sst_file_size = 1024,
        .l0_compaction_trigger = 2,
        .vlog_file_size = 1 << 20,
    });
    defer db.deinit();
    const value: [600]u8 = @splat('v');
    if (std.mem.eql(u8, mode, "probe")) {
        if (!strict) return error.StrictModeRequired;
        try db.put("survivor", &value);
        for (0..6) |_| try db.put("overwritten", &value);
        try db.delete("overwritten");
        try db.collectGarbage();
        try db.close();
        try std.Io.File.stdout().writeStreamingAll(io, "strict-directory-sync=enabled\n");
    } else if (std.mem.eql(u8, mode, "seed")) {
        for (0..16) |i| {
            var buf: [16]u8 = undefined;
            const key = try std.fmt.bufPrint(&buf, "base{d:0>2}", .{i});
            try db.put(key, &value);
        }
        try db.put("deleted", "old");
        try db.delete("deleted");
        try db.put("unflushed", "WAL-only value");
        try std.Io.File.stdout().writeStreamingAll(io, "ready\n");
        while (true) try std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_s }, .awake);
    } else if (std.mem.eql(u8, mode, "churn")) {
        try std.Io.File.stdout().writeStreamingAll(io, "ready\n");
        for (0..10000) |i| {
            var buf: [16]u8 = undefined;
            const key = try std.fmt.bufPrint(&buf, "hot{d}", .{i % 8});
            const payload: [16384]u8 = @splat(@as(u8, @intCast(i % 256)));
            try db.put(key, &payload);
            if (i % 32 == 31) try db.collectGarbage();
        }
    } else if (std.mem.eql(u8, mode, "verify")) {
        for (0..16) |i| {
            var buf: [16]u8 = undefined;
            const key = try std.fmt.bufPrint(&buf, "base{d:0>2}", .{i});
            const got = (try db.get(key)) orelse return error.MissingBaseline;
            defer init.gpa.free(got);
            if (!std.mem.eql(u8, got, &value)) return error.CorruptBaseline;
        }
        const wal_value = (try db.get("unflushed")) orelse return error.MissingWalValue;
        defer init.gpa.free(wal_value);
        if (!std.mem.eql(u8, wal_value, "WAL-only value")) return error.CorruptWalValue;
        if (try db.get("deleted")) |got| {
            init.gpa.free(got);
            return error.ResurrectedValue;
        }
        for (0..8) |i| {
            var buf: [16]u8 = undefined;
            const key = try std.fmt.bufPrint(&buf, "hot{d}", .{i});
            if (try db.get(key)) |got| {
                defer init.gpa.free(got);
                if (got.len != 16384) return error.TornValue;
                for (got) |byte| if (byte != got[0]) return error.TornValue;
            }
        }
        try db.close();
        try std.Io.File.stdout().writeStreamingAll(io, "verified\n");
    } else return error.UnknownMode;
}
