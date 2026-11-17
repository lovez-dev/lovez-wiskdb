//! Unsigned LEB128 with minimal-length encoding and bounded slice decoding.

const std = @import("std");

pub const PutError = error{NoRoom};
pub const DecodeError = error{ VarintTruncated, VarintOverflow };

pub const Decoded = struct {
    value: u64,
    len: usize,
};

/// Encode `v` into `buf`; returns bytes written. `buf` must hold up to 10 bytes.
pub fn putU64(buf: []u8, v: u64) PutError!usize {
    var i: usize = 0;
    var val = v;
    while (val >= 0x80) : (i += 1) {
        if (i >= buf.len) {
            @branchHint(.unlikely);
            return error.NoRoom;
        }
        buf[i] = @as(u8, @truncate(val)) | 0x80;
        val >>= 7;
    }
    if (i >= buf.len) {
        @branchHint(.unlikely);
        return error.NoRoom;
    }
    buf[i] = @truncate(val);
    return i + 1;
}

pub inline fn putU32(buf: []u8, v: u32) PutError!usize {
    return putU64(buf, v);
}

pub inline fn getU64(buf: []const u8) DecodeError!Decoded {
    return get(u64, buf);
}

/// Rejects encodings exceeding five bytes or four payload bits in the fifth.
pub inline fn getU32(buf: []const u8) DecodeError!Decoded {
    return get(u32, buf);
}

fn get(comptime T: type, buf: []const u8) DecodeError!Decoded {
    const bits = @bitSizeOf(T);
    const max_bytes = (bits + 6) / 7;
    const last_payload_bits = bits - 7 * (max_bytes - 1);
    var value: u64 = 0;
    var shift: u7 = 0;
    var i: usize = 0;
    while (true) {
        if (i >= buf.len) {
            @branchHint(.unlikely);
            return error.VarintTruncated;
        }
        if (i >= max_bytes) {
            @branchHint(.unlikely);
            return error.VarintOverflow;
        }
        const byte = buf[i];
        i += 1;
        const payload: u64 = byte & 0x7f;
        if (i == max_bytes and (byte & 0x80 != 0 or payload >> @intCast(last_payload_bits) != 0)) {
            @branchHint(.unlikely);
            return error.VarintOverflow;
        }
        value |= payload << @intCast(shift);
        if (byte & 0x80 == 0) return .{ .value = value, .len = i };
        shift += 7;
    }
}

test "round-trip and minimal byte length" {
    var buf: [16]u8 = undefined;
    inline for (.{ @as(u64, 0), 1, 127, 128, 300, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF }) |v| {
        const n = try putU64(&buf, v);
        const d = try getU64(buf[0..n]);
        try std.testing.expectEqual(v, d.value);
        try std.testing.expectEqual(n, d.len);
    }
    try std.testing.expectEqual(@as(usize, 1), try putU64(&buf, 127));
    try std.testing.expectEqual(@as(usize, 2), try putU64(&buf, 128));
    try std.testing.expectEqual(@as(usize, 5), try putU32(&buf, 0xFFFFFFFF));
    try std.testing.expectEqual(@as(usize, 10), try putU64(&buf, 0xFFFFFFFFFFFFFFFF));
}

test "malformed input is rejected, never guessed" {
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.VarintTruncated, getU64(&.{}));
    try std.testing.expectError(error.VarintTruncated, getU64(&.{0x80}));
    // 10th byte payload above 1 bit, or a still-continuing 10th byte.
    try std.testing.expectError(error.VarintOverflow, getU64(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 }));
    try std.testing.expectError(error.VarintOverflow, getU64(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x81 }));
    // u32 target wider than 4 payload bits in its 5th byte.
    try std.testing.expectError(error.VarintOverflow, getU32(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x1F }));
    // Overlong but numerically small (6 bytes where 5 suffice) is still invalid.
    try std.testing.expectError(error.VarintOverflow, getU32(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }));
    try std.testing.expectError(error.NoRoom, putU64(buf[0..1], 128));
}
