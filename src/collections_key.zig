//! Persisted collection keys use big-endian lengths and scores. Returned keys
//! are allocator-owned; decoded score members borrow the input key body.
const std = @import("std");

fn prefixLen(namespace: []const u8, name: []const u8) usize {
    return 17 + namespace.len + name.len;
}

fn writePrefix(out: []u8, namespace: []const u8, kind: u8, name: []const u8) void {
    std.mem.writeInt(u64, out[0..8], namespace.len, .big);
    @memcpy(out[8..][0..namespace.len], namespace);
    const offset = 8 + namespace.len;
    out[offset] = kind;
    std.mem.writeInt(u64, out[offset + 1 ..][0..8], name.len, .big);
    @memcpy(out[offset + 9 ..][0..name.len], name);
}

pub fn encode(allocator: std.mem.Allocator, namespace: []const u8, kind: u8, name: []const u8, field: []const u8) ![]u8 {
    const n = prefixLen(namespace, name);
    const out = try allocator.alloc(u8, n + field.len);
    writePrefix(out, namespace, kind, name);
    @memcpy(out[n..], field);
    return out;
}

pub fn scoreKey(allocator: std.mem.Allocator, namespace: []const u8, name: []const u8, member: []const u8, score: u64) ![]u8 {
    const n = prefixLen(namespace, name);
    const out = try allocator.alloc(u8, n + 8 + member.len);
    writePrefix(out, namespace, 'S', name);
    writeScore(out[n..], score, member);
    return out;
}

fn writeScore(out: []u8, score: u64, member: []const u8) void {
    std.mem.writeInt(u64, out[0..8], score, .big);
    @memcpy(out[8..][0..member.len], member);
}

/// A forward cursor appends zero to exclude only the exact member, while
/// retaining members whose bytes extend it. Reverse scans use an exclusive end.
pub fn scoreSuffix(allocator: std.mem.Allocator, prefix: []const u8, score: u64, member: []const u8, after: bool) ![]u8 {
    const out = try allocator.alloc(u8, prefix.len + 8 + member.len + @intFromBool(after));
    @memcpy(out[0..prefix.len], prefix);
    writeScore(out[prefix.len..], score, member);
    if (after) out[out.len - 1] = 0;
    return out;
}

pub const ScoreMember = struct { score: u64, member: []const u8 };

pub fn decodeScore(body: []const u8) !ScoreMember {
    if (body.len < 8) return error.InvalidInternalKey;
    return .{ .score = std.mem.readInt(u64, body[0..8], .big), .member = body[8..] };
}

test "collection keys: exact persisted bytes and binary components" {
    const allocator = std.testing.allocator;
    const key = try encode(allocator, "\x00\xff", 'H', "n\x00", "\xff\x00");
    defer allocator.free(key);
    try std.testing.expectEqualSlices(u8, "\x00\x00\x00\x00\x00\x00\x00\x02\x00\xffH\x00\x00\x00\x00\x00\x00\x00\x02n\x00\xff\x00", key);
    const scored = try scoreKey(allocator, "", "", "\x00\xff", 0x0102030405060708);
    defer allocator.free(scored);
    try std.testing.expectEqualSlices(u8, "\x00\x00\x00\x00\x00\x00\x00\x00S\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\x00\xff", scored);
    const decoded = try decodeScore(scored[17..]);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), decoded.score);
    try std.testing.expectEqualSlices(u8, "\x00\xff", decoded.member);
    try std.testing.expectError(error.InvalidInternalKey, decodeScore("short"));
}

test "collection keys: score index needs one allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const key = try scoreKey(failing.allocator(), "namespace", "name", "member", std.math.maxInt(u64));
    defer failing.allocator().free(key);
    const body = try decodeScore(key[prefixLen("namespace", "name")..]);
    try std.testing.expectEqual(std.math.maxInt(u64), body.score);
    try std.testing.expectEqualStrings("member", body.member);
}
