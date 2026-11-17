//! InternalKey layout: `user_key || BE(~seq): 8 || kind: 1`. Inverted sequences
//! sort newest first. Compare user keys separately so a shorter key's suffix
//! cannot affect user-key ordering.

const std = @import("std");
const coding = @import("coding.zig");

pub const suffix_len = 9;

pub const Kind = enum(u8) { put = 0, delete = 1 };

pub const View = struct {
    user: []const u8,
    seq: u64,
    kind: Kind,
};

pub const EncodeError = error{NoRoom};
pub const DecodeError = error{InvalidInternalKey};

pub inline fn encode(user: []const u8, seq: u64, kind: Kind, out: []u8) EncodeError!usize {
    const total = user.len + suffix_len;
    if (out.len < total) return error.NoRoom;
    @memcpy(out[0..user.len], user);
    coding.putBE64(out[user.len..][0..8], ~seq);
    out[user.len + 8] = @backingInt(kind);
    return total;
}

pub fn decode(key: []const u8) DecodeError!View {
    if (key.len < suffix_len) return error.InvalidInternalKey;
    const user = key[0 .. key.len - suffix_len];
    const suffix = key[user.len..];
    return .{
        .user = user,
        .seq = ~coding.getBE64(suffix[0..8]),
        .kind = switch (suffix[8]) {
            @backingInt(Kind.put) => .put,
            @backingInt(Kind.delete) => .delete,
            else => return error.InvalidInternalKey,
        },
    };
}

pub inline fn compare(a: []const u8, b: []const u8) std.math.Order {
    std.debug.assert(a.len >= suffix_len and b.len >= suffix_len);
    const a_user = a[0 .. a.len - suffix_len];
    const b_user = b[0 .. b.len - suffix_len];
    const user_order = std.mem.order(u8, a_user, b_user);
    if (user_order != .eq) return user_order;
    return std.mem.order(u8, a[a_user.len..], b[b_user.len..]);
}

/// Compare an encoded node key against a (user, seq, kind) target without
/// materializing the target's full bytes: a seek must not buffer a user key
/// (up to 64 KiB), and get() runs concurrently on many readers.
pub inline fn compareParts(a: []const u8, user: []const u8, seq: u64, kind: Kind) std.math.Order {
    std.debug.assert(a.len >= suffix_len);
    const a_user = a[0 .. a.len - suffix_len];
    const user_order = std.mem.order(u8, a_user, user);
    if (user_order != .eq) return user_order;
    var suffix: [suffix_len]u8 = undefined;
    coding.putBE64(suffix[0..8], ~seq);
    suffix[8] = @backingInt(kind);
    return std.mem.order(u8, a[a_user.len..], &suffix);
}

test "exact suffix bytes, round-trip, and rejection" {
    var buf: [64]u8 = undefined;

    // seq 0 -> ~seq all-ones; kind put -> 0. Layout proof, not just round-trip.
    const n = try encode("ab", 0, .put, &buf);
    try std.testing.expectEqual(@as(usize, 11), n);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 'a', 'b', 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 },
        buf[0..n],
    );

    const m = try encode("hello", 0x123456789ABCDEF0, .delete, &buf);
    const v = try decode(buf[0..m]);
    try std.testing.expectEqualStrings("hello", v.user);
    try std.testing.expectEqual(@as(u64, 0x123456789ABCDEF0), v.seq);
    try std.testing.expectEqual(Kind.delete, v.kind);

    try std.testing.expectError(error.NoRoom, encode("hello", 1, .put, buf[0..3]));
    try std.testing.expectError(error.InvalidInternalKey, decode(&.{ 1, 2, 3 }));
    buf[m - 1] = 2; // kind outside {put, delete}
    try std.testing.expectError(error.InvalidInternalKey, decode(buf[0..m]));
}

test "order: newest first, user boundary wins, kind breaks ties" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;

    const n5 = try encode("k", 5, .put, &a);
    const n10 = try encode("k", 10, .put, &b);
    try std.testing.expectEqual(std.math.Order.gt, compare(a[0..n5], b[0..n10]));

    // "ab" carries the largest possible suffix, "abc" the smallest — a naive
    // whole-key memcmp would order them by suffix; the boundary rule must not.
    const ns = try encode("ab", 0, .put, &a);
    const nl = try encode("abc", std.math.maxInt(u64), .put, &b);
    try std.testing.expectEqual(std.math.Order.lt, compare(a[0..ns], b[0..nl]));

    const np = try encode("k", 7, .put, &a);
    const nd = try encode("k", 7, .delete, &b);
    try std.testing.expectEqual(std.math.Order.lt, compare(a[0..np], b[0..nd]));
}

test "compareParts matches compare for every ordering dimension" {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const k1 = try encode("k", 10, .put, &b1);
    try std.testing.expectEqual(std.math.Order.eq, compareParts(b1[0..k1], "k", 10, .put));

    const k2 = try encode("kk", 1, .delete, &b2);
    try std.testing.expectEqual(std.math.Order.gt, compareParts(b2[0..k2], "k", 10, .delete));

    // same user, descending seq: seq 10 sorts before seq 5
    try std.testing.expectEqual(std.math.Order.lt, compareParts(b1[0..k1], "k", 5, .put));
    // same user and seq, kind breaks the tie: put < delete
    try std.testing.expectEqual(std.math.Order.lt, compareParts(b1[0..k1], "k", 10, .delete));
}
