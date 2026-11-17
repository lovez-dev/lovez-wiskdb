//! ValueLog entry codec: 36-byte fixed header + key + value + entry CRC +
//! pad to 8 bytes (`entry_total = align8(36 + K + V + 4)`). A vlog file has
//! no separate header — the first entry's magic doubles as the file magic.

const std = @import("std");
const crc = @import("../util/crc.zig");
const coding = @import("../util/coding.zig");

pub const magic = "WKVL";
pub const version: u16 = 1;
pub const header_len = 36;
pub const crc_len = 4;
pub const entry_align = 8;
/// bit2; bits 0/1 (DELETED/INLINE) always stay 0 — a vlog entry carries a
/// live value by definition, kept for bitmask parity with other stores.
pub const flag_has_expire: u8 = 1 << 2;

pub fn entryTotal(key_len: u32, val_len: u32) u64 {
    return std.mem.alignForward(u64, @as(u64, header_len) + key_len + val_len + crc_len, entry_align);
}

pub const Header = struct {
    seq: u64,
    expire_at: u64,
    key_len: u32,
    val_len: u32,
};

pub fn encodeHeader(out: *[header_len]u8, seq: u64, expire_at: u64, key_len: u32, val_len: u32) void {
    @memcpy(out[0..4], magic);
    coding.putU16(out[4..6], version);
    out[6] = if (expire_at != 0) flag_has_expire else 0;
    out[7] = 0; // reserved
    coding.putU64(out[8..16], seq);
    coding.putU64(out[16..24], expire_at);
    coding.putU32(out[24..28], key_len);
    coding.putU32(out[28..32], val_len);
    coding.putU32(out[32..36], crc.crc32(out[0..32]));
}

/// Strict decode: every structural inconsistency is `VLogCorrupted`, a
/// different version is `UnsupportedFormatVersion`.
pub fn decodeHeader(raw: []const u8) error{ VLogCorrupted, UnsupportedFormatVersion }!Header {
    if (raw.len < header_len) return error.VLogCorrupted;
    if (!std.mem.eql(u8, raw[0..4], magic)) return error.VLogCorrupted;
    // Integrity before semantics: a bit-rotted byte must read as corruption,
    // never masquerade as a version or flag mismatch.
    if (crc.crc32(raw[0..32]) != coding.getU32(raw[32..36])) return error.VLogCorrupted;
    if (coding.getU16(raw[4..6]) != version) return error.UnsupportedFormatVersion;
    const flags = raw[6];
    if (flags & ~flag_has_expire != 0) return error.VLogCorrupted; // DELETED/INLINE/unknown
    if (raw[7] != 0) return error.VLogCorrupted; // reserved
    const expire_at = coding.getU64(raw[16..24]);
    // The flag and the field must agree in both directions.
    if ((flags & flag_has_expire != 0) != (expire_at != 0)) return error.VLogCorrupted;

    return .{
        .seq = coding.getU64(raw[8..16]),
        .expire_at = expire_at,
        .key_len = coding.getU32(raw[24..28]),
        .val_len = coding.getU32(raw[28..32]),
    };
}

/// CRC32 over `key || value` without concatenating them into a buffer.
pub fn entryCrc(key: []const u8, value: []const u8) u32 {
    var h = crc.Crc32.init();
    h.update(key);
    h.update(value);
    return h.final();
}

test "entry header roundtrip; every structural defect is rejected" {
    var buf: [header_len]u8 = undefined;
    encodeHeader(&buf, 42, 0, 10, 20);
    var h = try decodeHeader(&buf);
    try std.testing.expectEqual(@as(u64, 42), h.seq);
    try std.testing.expectEqual(@as(u64, 0), h.expire_at);
    try std.testing.expectEqual(@as(u32, 10), h.key_len);
    try std.testing.expectEqual(@as(u32, 20), h.val_len);

    encodeHeader(&buf, 7, 12345, 1, 1);
    h = try decodeHeader(&buf);
    try std.testing.expectEqual(@as(u64, 12345), h.expire_at);

    var bad = buf;
    bad[0] ^= 0xFF; // magic
    try std.testing.expectError(error.VLogCorrupted, decodeHeader(&bad));

    bad = buf;
    bad[4] = 2; // version; repaired CRC so only the version differs
    coding.putU32(bad[32..36], crc.crc32(bad[0..32]));
    try std.testing.expectError(error.UnsupportedFormatVersion, decodeHeader(&bad));

    bad = buf;
    bad[6] |= 0x01; // DELETED must stay 0
    coding.putU32(bad[32..36], crc.crc32(bad[0..32]));
    try std.testing.expectError(error.VLogCorrupted, decodeHeader(&bad));

    bad = buf;
    bad[7] = 1; // reserved byte
    coding.putU32(bad[32..36], crc.crc32(bad[0..32]));
    try std.testing.expectError(error.VLogCorrupted, decodeHeader(&bad));

    encodeHeader(&bad, 1, 0, 1, 1);
    bad[6] |= flag_has_expire; // flag without a field
    coding.putU32(bad[32..36], crc.crc32(bad[0..32]));
    try std.testing.expectError(error.VLogCorrupted, decodeHeader(&bad));

    encodeHeader(&bad, 1, 9, 1, 1);
    bad[6] &= ~flag_has_expire; // field without the flag
    coding.putU32(bad[32..36], crc.crc32(bad[0..32]));
    try std.testing.expectError(error.VLogCorrupted, decodeHeader(&bad));

    bad = buf;
    bad[32] ^= 0xFF; // header_crc itself
    try std.testing.expectError(error.VLogCorrupted, decodeHeader(&bad));
}

test "entryTotal aligns to 8; entryCrc chains key then value" {
    try std.testing.expectEqual(@as(u64, 40), entryTotal(0, 0)); // 36+4, already aligned
    try std.testing.expectEqual(@as(u64, 48), entryTotal(1, 1)); // 42 -> 48
    try std.testing.expectEqual(@as(u64, 64), entryTotal(10, 14)); // 64, no pad

    const k = "key!!";
    const v = "value-bytes";
    var cat: [k.len + v.len]u8 = undefined;
    @memcpy(cat[0..k.len], k);
    @memcpy(cat[k.len..], v);
    try std.testing.expectEqual(crc.crc32(&cat), entryCrc(k, v));
}
