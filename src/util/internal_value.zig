//! InternalValue bytes shared by live writes, WAL replay, SSTs and VLog GC.
//! All fields are little-endian. The optional expiry precedes inline payload;
//! decoding borrows its input, and encoding only writes caller-owned storage.

const std = @import("std");
const coding = @import("coding.zig");

pub const header_len = 21;
pub const expiry_header_len = 29;
pub const deleted: u8 = 0b001;
pub const inline_value: u8 = 0b010;
pub const has_expiry: u8 = 0b100;
pub const DecodeError = error{InvalidInternalValue};
pub const EncodeError = DecodeError || error{NoRoom};

pub const Header = struct {
    flags: u8 = 0,
    value_len: u32 = 0,
    file_id: u64 = 0,
    offset: u32 = 0,
    value_crc: u32 = 0,
    expire_at: ?u64 = null,

    pub fn isDeleted(self: Header) bool {
        return self.flags & deleted != 0;
    }

    pub fn isInline(self: Header) bool {
        return self.flags & inline_value != 0;
    }

    pub fn headerLen(self: Header) usize {
        return if (self.flags & has_expiry != 0) expiry_header_len else header_len;
    }

    pub fn encodedLen(self: Header) usize {
        return self.headerLen() + if (self.isInline()) @as(usize, self.value_len) else 0;
    }

    /// Writes only the header, so inline payload can be copied into its final
    /// owner directly. The caller supplies the payload separately.
    pub fn encode(self: Header, out: []u8) error{NoRoom}![]u8 {
        const len = self.headerLen();
        if (out.len < len) return error.NoRoom;
        out[0] = self.flags;
        coding.putU32(out[1..5], self.value_len);
        coding.putU64(out[5..13], self.file_id);
        coding.putU32(out[13..17], self.offset);
        coding.putU32(out[17..21], self.value_crc);
        if (self.flags & has_expiry != 0) coding.putU64(out[21..29], self.expire_at orelse 0);
        return out[0..len];
    }

    /// Checks header bounds only. A zero VLog id is structurally representable;
    /// callers reading an external value validate that reference separately.
    pub fn decode(bytes: []const u8) DecodeError!Header {
        if (bytes.len < header_len) return error.InvalidInternalValue;
        const flags = bytes[0];
        if (flags & has_expiry != 0 and bytes.len < expiry_header_len) return error.InvalidInternalValue;
        return .{
            .flags = flags,
            .value_len = coding.getU32(bytes[1..5]),
            .file_id = coding.getU64(bytes[5..13]),
            .offset = coding.getU32(bytes[13..17]),
            .value_crc = coding.getU32(bytes[17..21]),
            .expire_at = if (flags & has_expiry != 0) coding.getU64(bytes[21..29]) else null,
        };
    }
};

pub const View = struct {
    header: Header,
    inline_bytes: []const u8,

    /// Validates the inline length; trailing bytes are ignored.
    pub fn decode(bytes: []const u8) DecodeError!View {
        const header = try Header.decode(bytes);
        const start = header.headerLen();
        if (header.isInline() and header.value_len > bytes.len - start) return error.InvalidInternalValue;
        return .{
            .header = header,
            .inline_bytes = if (header.isInline()) bytes[start..][0..header.value_len] else &.{},
        };
    }
};

/// Preserves all flag bits. Only inline values consume inline_bytes; the expiry
/// flag controls its header slot.
pub fn encode(header: Header, inline_bytes: []const u8, out: []u8) EncodeError![]u8 {
    if (header.isInline() and inline_bytes.len < header.value_len) return error.InvalidInternalValue;
    const len = header.encodedLen();
    if (out.len < len) return error.NoRoom;
    _ = try header.encode(out);
    if (header.isInline()) @memcpy(out[header.headerLen()..len], inline_bytes[0..header.value_len]);
    return out[0..len];
}

test "internal value: exact inline pointer and tombstone bytes preserve the format" {
    var buffer: [64]u8 = undefined;
    const small = try encode(.{ .flags = inline_value, .value_len = 2, .value_crc = 0x12345678 }, "ok", &buffer);
    const expected = [_]u8{ 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x78, 0x56, 0x34, 0x12, 'o', 'k' };
    try std.testing.expectEqualSlices(u8, &expected, small);
    try std.testing.expectEqualStrings("ok", (try View.decode(small)).inline_bytes);
    const pointer = try encode(.{ .value_len = 7, .file_id = 0x0807060504030201, .offset = 0x0c0b0a09, .value_crc = 0x100f0e0d }, "", &buffer);
    const pointer_expected = [_]u8{ 0, 7, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    try std.testing.expectEqualSlices(u8, &pointer_expected, pointer);
    const tombstone = try encode(.{ .flags = deleted }, "", &buffer);
    try std.testing.expectEqual(@as(usize, header_len), tombstone.len);
    try std.testing.expect((try Header.decode(tombstone)).isDeleted());
    for (tombstone[1..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "internal value: expiry precedes inline bytes and survives pointer relocation" {
    var buffer: [64]u8 = undefined;
    const encoded = try encode(.{ .flags = inline_value | has_expiry, .value_len = 3, .expire_at = 0x0807060504030201 }, "ttl", &buffer);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, encoded[21..29]);
    const view = try View.decode(encoded);
    try std.testing.expectEqual(@as(?u64, 0x0807060504030201), view.header.expire_at);
    try std.testing.expectEqualStrings("ttl", view.inline_bytes);
    var header = view.header;
    header.flags &= ~inline_value;
    header.file_id = 9;
    header.offset = 32;
    const pointer = try encode(header, "", &buffer);
    try std.testing.expectEqual(@as(usize, expiry_header_len), pointer.len);
    const relocated = try Header.decode(pointer);
    try std.testing.expectEqual(header, relocated);
}

test "internal value: bounds checks retain zero references and unknown flags" {
    var buffer: [64]u8 = @splat(0);
    try std.testing.expectError(error.InvalidInternalValue, Header.decode(buffer[0..20]));
    buffer[0] = has_expiry;
    try std.testing.expectError(error.InvalidInternalValue, Header.decode(buffer[0..28]));
    buffer[0] = inline_value;
    coding.putU32(buffer[1..5], 4);
    try std.testing.expectError(error.InvalidInternalValue, View.decode(buffer[0..24]));
    try std.testing.expectError(error.NoRoom, encode(.{ .flags = inline_value, .value_len = 4 }, "data", buffer[0..24]));
    try std.testing.expectError(error.InvalidInternalValue, encode(.{ .flags = inline_value, .value_len = 4 }, "bad", &buffer));
    const empty = try encode(.{ .flags = 0x80 }, "", &buffer);
    const header = try Header.decode(empty);
    try std.testing.expectEqual(@as(u8, 0x80), header.flags);
    try std.testing.expectEqual(@as(u64, 0), header.file_id);
}

test "internal value: header-only encoding preserves extremes and reserved flags" {
    var buffer: [expiry_header_len + 4]u8 = @splat(0xaa);
    const zero = try (Header{}).encode(&buffer);
    try std.testing.expectEqual(@as(usize, header_len), zero.len);
    for (zero) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (buffer[header_len..]) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
    const maximum = Header{
        .flags = 0xff,
        .value_len = std.math.maxInt(u32),
        .file_id = std.math.maxInt(u64),
        .offset = std.math.maxInt(u32),
        .value_crc = std.math.maxInt(u32),
        .expire_at = std.math.maxInt(u64),
    };
    const encoded = try maximum.encode(&buffer);
    try std.testing.expectEqual(@as(usize, expiry_header_len), encoded.len);
    for (encoded) |byte| try std.testing.expectEqual(@as(u8, 0xff), byte);
    try std.testing.expectEqual(maximum, try Header.decode(encoded));
    for (buffer[expiry_header_len..]) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
    @memset(&buffer, 0xaa);
    try std.testing.expectError(error.NoRoom, maximum.encode(buffer[0 .. expiry_header_len - 1]));
    for (buffer) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
    const no_expiry = try (Header{ .flags = has_expiry }).encode(&buffer);
    try std.testing.expectEqual(@as(?u64, 0), (try Header.decode(no_expiry)).expire_at);
}

test "internal value: full encoding validates before writing any header bytes" {
    var buffer: [expiry_header_len]u8 = @splat(0xaa);
    const header = Header{ .flags = inline_value | has_expiry, .value_len = 4 };
    try std.testing.expectError(error.InvalidInternalValue, encode(header, "bad", buffer[0..0]));
    try std.testing.expectError(error.NoRoom, encode(header, "data", &buffer));
    for (buffer) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
}
