//! WAL frames use a 15-byte header: `WKWA` magic, type, LE payload length,
//! payload CRC and header CRC. Recovery validates headers before reading
//! payloads, then checks payload CRCs before batch reassembly.

const std = @import("std");
const crc = @import("../util/crc.zig");
const coding = @import("../util/coding.zig");

pub const magic = "WKWA";
pub const frame_header_len = 15;
/// Larger batches are split into FIRST/MIDDLE/LAST frames.
pub const max_payload_len: u16 = 32768;

pub const FrameType = enum(u8) { full = 1, first = 2, middle = 3, last = 4, synced = 5 };

pub fn frameType(raw: u8) error{WalCorrupted}!FrameType {
    return switch (raw) {
        1 => .full,
        2 => .first,
        3 => .middle,
        4 => .last,
        5 => .synced,
        else => error.WalCorrupted,
    };
}

pub fn encodeHeader(
    out: *[frame_header_len]u8,
    frame_type: FrameType,
    payload_len: u16,
    payload_crc: u32,
) void {
    @memcpy(out[0..4], magic);
    out[4] = @backingInt(frame_type);
    coding.putU16(out[5..7], payload_len);
    coding.putU32(out[7..11], payload_crc);
    coding.putU32(out[11..15], crc.crc32(out[0..11]));
}

pub const Header = struct {
    frame_type: FrameType,
    payload_len: u16,
    payload_crc: u32,
};

/// Every rejection is `error.WalCorrupted`: bad magic, unknown type, header
/// CRC mismatch, or a payload length outside `1..=32768`.
pub fn decodeHeader(raw: []const u8) error{WalCorrupted}!Header {
    if (raw.len < frame_header_len) return error.WalCorrupted;
    if (!std.mem.eql(u8, raw[0..4], magic)) return error.WalCorrupted;
    if (crc.crc32(raw[0..11]) != coding.getU32(raw[11..15])) return error.WalCorrupted;
    const len = coding.getU16(raw[5..7]);
    if (len == 0 or len > max_payload_len) return error.WalCorrupted;
    return .{
        .frame_type = try frameType(raw[4]),
        .payload_len = len,
        .payload_crc = coding.getU32(raw[7..11]),
    };
}

test "frame codec: roundtrip, then every header defect is WalCorrupted" {
    var hdr: [frame_header_len]u8 = undefined;
    const payload = "hello-payload";
    encodeHeader(&hdr, .full, payload.len, crc.crc32(payload));
    const h = try decodeHeader(&hdr);
    try std.testing.expectEqual(FrameType.full, h.frame_type);
    try std.testing.expectEqual(@as(u16, payload.len), h.payload_len);
    try std.testing.expectEqual(crc.crc32(payload), h.payload_crc);

    var bad = hdr;
    bad[0] ^= 0xFF; // magic
    try std.testing.expectError(error.WalCorrupted, decodeHeader(&bad));

    bad = hdr;
    bad[7] ^= 0xFF; // payload_crc field: header CRC must catch it
    try std.testing.expectError(error.WalCorrupted, decodeHeader(&bad));

    bad = hdr;
    bad[11] ^= 0xFF; // header_crc itself
    try std.testing.expectError(error.WalCorrupted, decodeHeader(&bad));

    encodeHeader(&bad, .full, 0, 0); // zero payload length
    try std.testing.expectError(error.WalCorrupted, decodeHeader(&bad));

    encodeHeader(&bad, .full, 32769, 0); // above the 32768 cap
    try std.testing.expectError(error.WalCorrupted, decodeHeader(&bad));

    encodeHeader(&bad, .full, 1, 0);
    bad[4] = 9; // unknown type — repaired header CRC so type is the only defect
    coding.putU32(bad[11..15], crc.crc32(bad[0..11]));
    try std.testing.expectError(error.WalCorrupted, decodeHeader(&bad));
}
