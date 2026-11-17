//! Fixed-width little-endian integers and big-endian u64 keys.

const std = @import("std");

pub inline fn getU16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .little);
}

test "big-endian pair writes the high byte first" {
    var buf: [8]u8 = undefined;
    putBE64(&buf, 0x0102030405060708);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &buf);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), getBE64(&buf));
}
pub inline fn putU16(b: *[2]u8, v: u16) void {
    std.mem.writeInt(u16, b, v, .little);
}

pub inline fn getU32(b: *const [4]u8) u32 {
    return std.mem.readInt(u32, b, .little);
}
pub inline fn putU32(b: *[4]u8, v: u32) void {
    std.mem.writeInt(u32, b, v, .little);
}

pub inline fn getU64(b: *const [8]u8) u64 {
    return std.mem.readInt(u64, b, .little);
}
pub inline fn putU64(b: *[8]u8, v: u64) void {
    std.mem.writeInt(u64, b, v, .little);
}

pub inline fn getBE64(b: *const [8]u8) u64 {
    return std.mem.readInt(u64, b, .big);
}

pub inline fn putBE64(b: *[8]u8, v: u64) void {
    std.mem.writeInt(u64, b, v, .big);
}

test "round-trip preserves values and byte order is little-endian" {
    var buf: [8]u8 = undefined;

    putU16(buf[0..2], 0x0201);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, buf[0..2]);
    try std.testing.expectEqual(@as(u16, 0x0201), getU16(buf[0..2]));

    putU32(buf[0..4], 0x04030201);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03, 0x04 }, buf[0..4]);
    try std.testing.expectEqual(@as(u32, 0x04030201), getU32(buf[0..4]));

    putU64(&buf, 0x0807060504030201);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &buf);
    try std.testing.expectEqual(@as(u64, 0x0807060504030201), getU64(&buf));
}
