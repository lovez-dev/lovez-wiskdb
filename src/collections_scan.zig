const std = @import("std");
const Collections = @import("collections.zig").Collections;
const keys = @import("collections_key.zig");

pub const HashItem = struct { field: []const u8, value: []const u8 };
pub const ZItem = struct { member: []const u8, score: u64 };

/// Smallest key strictly greater than every key starting with `prefix`.
pub fn prefixEnd(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, prefix);
    errdefer allocator.free(out);
    var i = out.len;
    while (i > 0) {
        i -= 1;
        if (out[i] != 0xff) {
            out[i] += 1;
            return out;
        }
        out[i] = 0;
    }
    return error.InvalidPrefix;
}

pub fn hashScan(c: *Collections, name: []const u8) ![]HashItem {
    const prefix = try c.encodeKey('H', name, "");
    defer c.db.allocator.free(prefix);
    const end = try prefixEnd(c.db.allocator, prefix);
    defer c.db.allocator.free(end);
    const rows = try c.db.scan(prefix, end);
    defer c.db.freeScan(rows);
    var out: std.ArrayListUnmanaged(HashItem) = .empty;
    errdefer {
        for (out.items) |item| {
            c.db.allocator.free(item.field);
            c.db.allocator.free(item.value);
        }
        out.deinit(c.db.allocator);
    }
    for (rows) |row| {
        if (row.key.len < prefix.len) continue;
        const field = try c.db.allocator.dupe(u8, row.key[prefix.len..]);
        errdefer c.db.allocator.free(field);
        const value = try c.db.allocator.dupe(u8, row.value);
        errdefer c.db.allocator.free(value);
        try out.append(c.db.allocator, .{ .field = field, .value = value });
    }
    return out.toOwnedSlice(c.db.allocator);
}

pub fn freeHash(c: *Collections, items: []HashItem) void {
    for (items) |item| {
        c.db.allocator.free(item.field);
        c.db.allocator.free(item.value);
    }
    c.db.allocator.free(items);
}

pub const Cursor = struct { score: u64, member: []const u8 };

/// A cursor is exclusive; bounds are encoded before the scan starts so limit
/// stops storage iteration after the requested visible rows.
pub fn zsetQuery(c: *Collections, name: []const u8, min: ?u64, max: ?u64, cursor: ?Cursor, reverse: bool, limit: usize) ![]ZItem {
    const prefix = try c.encodeKey('S', name, "");
    defer c.db.allocator.free(prefix);
    const end = try prefixEnd(c.db.allocator, prefix);
    defer c.db.allocator.free(end);
    const allocator = c.db.allocator;
    const lower = try keys.scoreSuffix(allocator, prefix, min orelse 0, "", false);
    defer allocator.free(lower);
    const upper = if (max) |score| if (score < std.math.maxInt(u64)) try keys.scoreSuffix(allocator, prefix, score + 1, "", false) else try allocator.dupe(u8, end) else try allocator.dupe(u8, end);
    defer allocator.free(upper);
    var start: []const u8 = lower;
    var finish: []const u8 = upper;
    var cursor_key: ?[]u8 = null;
    defer if (cursor_key) |key| allocator.free(key);
    if (cursor) |cur| {
        const key = try keys.scoreSuffix(allocator, prefix, cur.score, cur.member, !reverse);
        cursor_key = key;
        if (reverse) {
            if (std.mem.order(u8, key, finish) == .lt) finish = key;
        } else {
            if (std.mem.order(u8, key, start) == .gt) start = key;
        }
    }
    const rows = try c.db.scanWithOptions(.{ .start = start, .end = finish, .reverse = reverse, .limit = limit });
    defer c.db.freeScan(rows);
    var out: std.ArrayListUnmanaged(ZItem) = .empty;
    errdefer {
        for (out.items) |item| c.db.allocator.free(item.member);
        out.deinit(c.db.allocator);
    }
    for (rows) |row| {
        if (row.key.len < prefix.len) return error.InvalidInternalKey;
        const decoded = try keys.decodeScore(row.key[prefix.len..]);
        const member = try c.db.allocator.dupe(u8, decoded.member);
        errdefer c.db.allocator.free(member);
        try out.append(c.db.allocator, .{ .member = member, .score = decoded.score });
    }
    return out.toOwnedSlice(c.db.allocator);
}

pub fn zsetRange(c: *Collections, name: []const u8, min: ?u64, max: ?u64) ![]ZItem {
    return zsetQuery(c, name, min, max, null, false, 0);
}

pub fn zsetRevRange(c: *Collections, name: []const u8, min: ?u64, max: ?u64) ![]ZItem {
    return zsetQuery(c, name, min, max, null, true, 0);
}

pub fn freeZ(c: *Collections, items: []ZItem) void {
    for (items) |item| c.db.allocator.free(item.member);
    c.db.allocator.free(items);
}

test "collections scans: every caller allocation failure cleans up" {
    const Db = @import("db.zig").Db;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    var c = Collections.init(&db, "oom");
    try c.hashSet("h", "a", "first");
    try c.hashSet("h", "b", "second");
    try c.zsetAdd("z", "a", 1);
    try c.zsetAdd("z", "b", 2);
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, target: *Collections, zset: bool) !void {
            const saved = target.db.allocator;
            target.db.allocator = allocator;
            defer target.db.allocator = saved;
            if (zset) {
                const items = try zsetRange(target, "z", null, null);
                defer freeZ(target, items);
                try std.testing.expectEqual(@as(usize, 2), items.len);
            } else {
                const items = try hashScan(target, "h");
                defer freeHash(target, items);
                try std.testing.expectEqual(@as(usize, 2), items.len);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{ &c, false });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{ &c, true });
}

test "zset bounded query: tied scores, binary cursor, tombstones and limits" {
    const Db = @import("db.zig").Db;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    var c = Collections.init(&db, "bounds");
    try c.zsetAdd("z", "", 7);
    try c.zsetAdd("z", "a", 7);
    const a_zero = &.{ 'a', 0 };
    try c.zsetAdd("z", a_zero, 7);
    try c.zsetAdd("z", "b", 7);
    try c.zsetAdd("z", "gone", 8);
    try c.zsetAdd("z", "max", std.math.maxInt(u64));
    try db.flush();
    try c.zsetAdd("z", "gone", 2);
    const asc = try zsetQuery(&c, "z", 7, 7, .{ .score = 7, .member = "a" }, false, 1);
    defer freeZ(&c, asc);
    try std.testing.expectEqual(@as(usize, 1), asc.len);
    try std.testing.expectEqualStrings(a_zero, asc[0].member);
    const desc = try zsetQuery(&c, "z", 7, 8, .{ .score = 7, .member = a_zero }, true, 2);
    defer freeZ(&c, desc);
    try std.testing.expectEqual(@as(usize, 2), desc.len);
    try std.testing.expectEqualStrings("a", desc[0].member);
    try std.testing.expectEqualStrings("", desc[1].member);
    const high = try zsetQuery(&c, "z", null, null, null, true, 2);
    defer freeZ(&c, high);
    try std.testing.expectEqual(std.math.maxInt(u64), high[0].score);
    try std.testing.expectEqualStrings("b", high[1].member);
    const empty = try zsetQuery(&c, "z", 9, 7, null, true, 1);
    defer freeZ(&c, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const outside = try zsetQuery(&c, "z", 7, 7, .{ .score = 1, .member = "" }, true, 1);
    defer freeZ(&c, outside);
    try std.testing.expectEqual(@as(usize, 0), outside.len);
}
