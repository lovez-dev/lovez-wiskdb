//! Public API checks across MemTables, compaction, value-log GC and reopen.
//! The model stores logical values independently of the engine's file layout.

const std = @import("std");
const wiskdb = @import("wiskdb");

const key_count = 32;
const external_size = 48 * 1024;
const Expected = struct { present: bool = false, length: usize = 0, byte: u8 = 0 };

fn expectBytes(expected: Expected, actual: []const u8) !void {
    try std.testing.expectEqual(expected.length, actual.len);
    for (actual) |byte| try std.testing.expectEqual(expected.byte, byte);
}

fn expectModel(db: *wiskdb.Db, model: *const [key_count]Expected) !void {
    var visible: usize = 0;
    for (model, 0..) |expected, i| {
        const key: [2]u8 = .{ 0x80, @intCast(i) };
        const value = try db.get(&key);
        defer if (value) |bytes| std.testing.allocator.free(bytes);
        if (expected.present) {
            visible += 1;
            try expectBytes(expected, value orelse return error.MissingModelValue);
        } else try std.testing.expect(value == null);
    }
    const rows = try db.scan(null, null);
    defer db.freeScan(rows);
    try std.testing.expectEqual(visible, rows.len);
    var next: usize = 0;
    for (model, 0..) |expected, i| {
        if (!expected.present) continue;
        const key: [2]u8 = .{ 0x80, @intCast(i) };
        try std.testing.expectEqualSlices(u8, &key, rows[next].key);
        try expectBytes(expected, rows[next].value);
        next += 1;
    }
    const reverse = try db.scanWithOptions(.{ .reverse = true, .limit = 5 });
    defer db.freeScan(reverse);
    try std.testing.expectEqual(@min(visible, 5), reverse.len);
    for (reverse, 0..) |row, i| {
        try std.testing.expectEqualSlices(u8, rows[rows.len - 1 - i].key, row.key);
        try std.testing.expectEqualSlices(u8, rows[rows.len - 1 - i].value, row.value);
    }
}

test "integration: model survives value separation compaction GC and repeated reopen" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const options: wiskdb.Options = .{
        .durability = .async,
        .automatic_gc = false,
        .write_buffer_size = 8 * 1024 * 1024,
        .vlog_file_size = 1024 * 1024,
        .l0_compaction_trigger = 2,
        .max_sst_file_size = 64 * 1024,
        .gc_garbage_ratio = 0.25,
        .table_cache_size = 1,
        .block_cache_size = 1024,
        .block_cache_shards = 4,
    };
    var model: [key_count]Expected = @splat(.{});
    {
        var db = try wiskdb.Db.open(allocator, io, tmp.dir, options);
        defer db.deinit();
        var payload: [external_size]u8 = undefined;
        // Repeated replacements exceed the 1 MiB VLog threshold. Flushing
        // each generation also makes the configured compaction trigger fire.
        for (0..5) |generation| {
            for (&model, 0..) |*expected, i| {
                const key: [2]u8 = .{ 0x80, @intCast(i) };
                if ((i + generation) % 5 == 0) {
                    try db.delete(&key);
                    expected.* = .{};
                } else {
                    const length: usize = if ((i + generation) % 2 == 0) external_size else 7;
                    const byte: u8 = @intCast(1 + i + generation * key_count);
                    @memset(payload[0..length], byte);
                    try db.put(&key, payload[0..length]);
                    expected.* = .{ .present = true, .length = length, .byte = byte };
                }
            }
            try expectModel(&db, &model);
            try db.flush();
            try expectModel(&db, &model);
        }
        try db.sync();
        try db.collectGarbage();
        try expectModel(&db, &model);
        try db.close();
        try std.testing.expectEqual(@as(usize, 0), db.stat().allocated_bytes);
    }
    // The second pass exercises recovery after maintenance on a recovered DB,
    // rather than relying only on the first process lifetime's cache contents.
    for (0..2) |_| {
        var db = try wiskdb.Db.open(allocator, io, tmp.dir, options);
        defer db.deinit();
        try expectModel(&db, &model);
        try db.collectGarbage();
        try expectModel(&db, &model);
        try db.close();
        try std.testing.expectEqual(@as(usize, 0), db.stat().allocated_bytes);
    }
}

fn expectCollections(db: *wiskdb.Db) !void {
    var c = wiskdb.Collections.init(db, "app\x00");
    var other = wiskdb.Collections.init(db, "other");
    const report = try c.verifyZset("rank");
    try std.testing.expectEqual(@as(usize, 4), report.members);
    try std.testing.expectEqual(@as(usize, 0), report.missing + report.stale + report.malformed);
    const expected_members = [_][]const u8{ "", "\x00", "a", "z" };
    const expected_scores = [_]u64{ 0, 7, 7, std.math.maxInt(u64) };
    const ranks = try c.zsetRange("rank", null, null);
    defer c.freeZ(ranks);
    try std.testing.expectEqual(expected_members.len, ranks.len);
    for (ranks, expected_members, expected_scores) |actual, member, score| {
        try std.testing.expectEqualSlices(u8, member, actual.member);
        try std.testing.expectEqual(score, actual.score);
    }
    const page = try c.zsetQuery("rank", null, null, .{ .score = 7, .member = "a" }, true, 2);
    defer c.freeZ(page);
    try std.testing.expectEqual(@as(usize, 2), page.len);
    try std.testing.expectEqualSlices(u8, "\x00", page[0].member);
    try std.testing.expectEqualSlices(u8, "", page[1].member);
    try std.testing.expect((try c.zsetScore("rank", "removed")) == null);
    try std.testing.expectEqual(@as(?u64, 99), try other.zsetScore("rank", "removed"));
    const value = (try c.hashGet("hash", "large")) orelse return error.MissingHashValue;
    defer std.testing.allocator.free(value);
    try expectBytes(.{ .present = true, .length = 2048, .byte = 0xab }, value);
    try std.testing.expect((try c.hashGet("hash", "deleted")) == null);
    const fields = try c.hashScan("hash");
    defer c.freeHash(fields);
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("large", fields[0].field);
}

test "integration: collection indexes and tombstones survive maintenance and reopen" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const options: wiskdb.Options = .{ .durability = .async, .automatic_gc = false, .l0_compaction_trigger = 2 };
    {
        var db = try wiskdb.Db.open(std.testing.allocator, std.testing.io, tmp.dir, options);
        defer db.deinit();
        var c = wiskdb.Collections.init(&db, "app\x00");
        var other = wiskdb.Collections.init(&db, "other");
        try c.zsetAdd("rank", "", 0);
        try c.zsetAdd("rank", "\x00", 8);
        try c.zsetAdd("rank", "a", 7);
        try c.zsetAdd("rank", "z", std.math.maxInt(u64));
        try c.zsetAdd("rank", "removed", 9);
        try other.zsetAdd("rank", "removed", 99);
        try c.hashSet("hash", "large", "old-inline");
        try c.hashSet("hash", "deleted", "old");
        try db.flush();
        _ = try c.zsetIncr("rank", "\x00", -1);
        try c.zsetRemove("rank", "removed");
        const large: [2048]u8 = @splat(0xab);
        try c.hashSet("hash", "large", &large);
        try c.hashDelete("hash", "deleted");
        try db.flush();
        try db.collectGarbage();
        try expectCollections(&db);
        try db.close();
    }
    var db = try wiskdb.Db.open(std.testing.allocator, std.testing.io, tmp.dir, options);
    defer db.deinit();
    try expectCollections(&db);
    try db.collectGarbage();
    try expectCollections(&db);
    try db.close();
    try std.testing.expectEqual(@as(usize, 0), db.stat().allocated_bytes);
}
