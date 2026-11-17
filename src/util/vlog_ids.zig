//! Packed VLog id sets for flush, compaction and garbage collection.

const std = @import("std");
const varint = @import("varint.zig");

pub const Ref = enum { referenced, absent, unknown };

/// Inserts a unique id in sorted order for canonical packing.
pub fn insert(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u64), id: u64) error{OutOfMemory}!void {
    var lo: usize = 0;
    var hi: usize = list.items.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (list.items[mid] < id) lo = mid + 1 else hi = mid;
    }
    if (lo < list.items.len and list.items[lo] == id) return;
    try list.insert(allocator, lo, id);
}

/// Self-describing packed set: mode0 range, mode1 list, empty fixed as
/// mode1/count0; over 64 items collapses to the covering range.
pub fn pack(allocator: std.mem.Allocator, ids: []const u64) error{OutOfMemory}![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var scratch: [10]u8 = undefined;
    if (ids.len == 0) {
        try out.appendSlice(allocator, &.{ 1, 0 });
        return out.toOwnedSlice(allocator);
    }
    if (ids.len > 64) {
        try out.append(allocator, 0);
        const n1 = varint.putU64(&scratch, ids[0]) catch unreachable;
        try out.appendSlice(allocator, scratch[0..n1]);
        const n2 = varint.putU64(&scratch, ids[ids.len - 1]) catch unreachable;
        try out.appendSlice(allocator, scratch[0..n2]);
        return out.toOwnedSlice(allocator);
    }
    try out.append(allocator, 1);
    const nc = varint.putU32(&scratch, @intCast(ids.len)) catch unreachable;
    try out.appendSlice(allocator, scratch[0..nc]);
    const n0 = varint.putU64(&scratch, ids[0]) catch unreachable;
    try out.appendSlice(allocator, scratch[0..n0]);
    var prev = ids[0];
    for (ids[1..]) |id| {
        const nd = varint.putU64(&scratch, id - prev) catch unreachable;
        try out.appendSlice(allocator, scratch[0..nd]);
        prev = id;
    }
    return out.toOwnedSlice(allocator);
}

/// `unknown` (any structural doubt) always means keep: deletion must never
/// rest on a set that failed to parse.
pub fn reference(packed_bytes: []const u8, id: u64) Ref {
    if (packed_bytes.len == 0) return .unknown;
    const mode = packed_bytes[0];
    var pos: usize = 1;
    if (mode == 0) {
        const a = varint.getU64(packed_bytes[pos..]) catch return .unknown;
        pos += a.len;
        const b = varint.getU64(packed_bytes[pos..]) catch return .unknown;
        pos += b.len;
        if (pos != packed_bytes.len or a.value > b.value) return .unknown;
        return if (a.value <= id and id <= b.value) .referenced else .absent;
    }
    if (mode == 1) {
        const c = varint.getU32(packed_bytes[pos..]) catch return .unknown;
        pos += c.len;
        if (c.value == 0) return if (pos == packed_bytes.len) .absent else .unknown;
        const first = varint.getU64(packed_bytes[pos..]) catch return .unknown;
        pos += first.len;
        var cur = first.value;
        var found = cur == id;
        var i: u32 = 1;
        while (i < c.value) : (i += 1) {
            const d = varint.getU64(packed_bytes[pos..]) catch return .unknown;
            pos += d.len;
            cur = std.math.add(u64, cur, d.value) catch return .unknown;
            if (cur == id) found = true;
        }
        if (pos != packed_bytes.len) return .unknown;
        return if (found) .referenced else .absent;
    }
    return .unknown;
}

/// The exact id list for set differences. A range (or anything else
/// that is not a list) yields null: a caller may only subtract ids it
/// can actually enumerate — guessing would mint a deletion candidate
/// that was never proven unreferenced.
pub fn unpackExact(allocator: std.mem.Allocator, packed_bytes: []const u8) error{OutOfMemory}!?[]u64 {
    if (packed_bytes.len < 2 or packed_bytes[0] != 1) return null;
    var pos: usize = 1;
    const c = varint.getU32(packed_bytes[pos..]) catch return null;
    pos += c.len;
    var list: std.ArrayListUnmanaged(u64) = .empty;
    defer list.deinit(allocator); // null returns must free too; toOwnedSlice empties it first
    var i: u32 = 0;
    while (i < c.value) : (i += 1) {
        const v = varint.getU64(packed_bytes[pos..]) catch return null;
        pos += v.len;
        var id = v.value;
        if (i > 0) id = std.math.add(u64, list.items[i - 1], v.value) catch return null;
        try list.append(allocator, id);
    }
    if (pos != packed_bytes.len) return null;
    const slice = try list.toOwnedSlice(allocator);
    return slice;
}

test "pack and reference: members hit, outsiders miss, empty is a list" {
    const allocator = std.testing.allocator;
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    defer ids.deinit(allocator);
    try insert(allocator, &ids, 7);
    try insert(allocator, &ids, 3);
    try insert(allocator, &ids, 7); // duplicate ignored
    try std.testing.expectEqual(@as(usize, 2), ids.items.len);

    const pset = try pack(allocator, ids.items);
    defer allocator.free(pset);
    try std.testing.expectEqual(Ref.referenced, reference(pset, 3));
    try std.testing.expectEqual(Ref.referenced, reference(pset, 7));
    try std.testing.expectEqual(Ref.absent, reference(pset, 5));

    const empty = try pack(allocator, &.{});
    defer allocator.free(empty);
    try std.testing.expectEqual(Ref.absent, reference(empty, 1));
}

test "pack collapses past 64 ids into a covering range" {
    const allocator = std.testing.allocator;
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    defer ids.deinit(allocator);
    var i: u64 = 100;
    while (i < 200) : (i += 1) try insert(allocator, &ids, i);
    const pset = try pack(allocator, ids.items);
    defer allocator.free(pset);
    try std.testing.expectEqual(@as(u8, 0), pset[0]);
    try std.testing.expectEqual(Ref.referenced, reference(pset, 150));
    try std.testing.expectEqual(Ref.absent, reference(pset, 99));
}

test "unpackExact: lists decode, ranges and damage yield null" {
    const allocator = std.testing.allocator;
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    defer ids.deinit(allocator);
    try insert(allocator, &ids, 2);
    try insert(allocator, &ids, 9);
    const pset = try pack(allocator, ids.items);
    defer allocator.free(pset);
    const got = (try unpackExact(allocator, pset)).?;
    defer allocator.free(got);
    try std.testing.expectEqualSlices(u64, &.{ 2, 9 }, got);

    var range_ids: std.ArrayListUnmanaged(u64) = .empty;
    defer range_ids.deinit(allocator);
    var i: u64 = 0;
    while (i < 65) : (i += 1) try insert(allocator, &range_ids, i);
    const range_packed = try pack(allocator, range_ids.items);
    defer allocator.free(range_packed);
    try std.testing.expect((try unpackExact(allocator, range_packed)) == null);

    const bad = [_]u8{ 1, 9, 9, 9 }; // count says 3, payload runs out
    try std.testing.expect((try unpackExact(allocator, &bad)) == null);
}
