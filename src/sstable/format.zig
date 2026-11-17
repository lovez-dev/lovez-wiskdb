//! SSTable block trailers (`data || type || crc32`), varint BlockHandles
//! and the 48-byte footer with file-bound checks.

const std = @import("std");
const crc = @import("../util/crc.zig");
const coding = @import("../util/coding.zig");
const varint = @import("../util/varint.zig");

pub const magic = "WKST";
pub const format_version: u16 = 1;
pub const footer_len = 48;
pub const trailer_len = 5;
pub const block_type_none: u8 = 0;
pub const block_type_deflate: u8 = 1;
pub const restart_interval = 16;
pub const default_block_size: u32 = 4096;
// Persisted format identifiers stay stable across project renames.
pub const metaindex_bloom_key = "wiskdb.bloom.v1";
pub const metaindex_props_key = "wiskdb.props.v1";

pub const BlockHandle = struct {
    offset: u64,
    /// Excludes the 5-byte trailer; readers access `size + trailer_len`.
    size: u64,
};

/// varint64 pair as stored in Index / MetaIndex values.
pub fn encodeHandle(handle: BlockHandle, buf: []u8) varint.PutError!usize {
    const n = try varint.putU64(buf, handle.offset);
    const m = try varint.putU64(buf[n..], handle.size);
    return n + m;
}

pub fn decodeHandle(buf: []const u8) error{SSTableCorrupted}!BlockHandle {
    const off = varint.getU64(buf) catch return error.SSTableCorrupted;
    const size = varint.getU64(buf[off.len..]) catch return error.SSTableCorrupted;
    return .{ .offset = off.value, .size = size.value };
}

fn blockCrc(data: []const u8, block_type: u8) u32 {
    var h = crc.Crc32.init();
    h.update(data);
    h.update(&.{block_type});
    return h.final();
}

/// The fixed 5-byte tail every block carries.
pub fn writeTrailer(out: *[trailer_len]u8, data: []const u8, block_type: u8) void {
    out[0] = block_type;
    coding.putU32(out[1..5], blockCrc(data, block_type));
}

/// Validate `data || type || crc32`; return the type byte or `BlockCorrupted`.
pub fn verifyTrailer(full_block: []const u8) error{BlockCorrupted}!u8 {
    if (full_block.len < trailer_len) return error.BlockCorrupted;
    const data = full_block[0 .. full_block.len - trailer_len];
    const block_type = full_block[full_block.len - trailer_len];
    const stored = coding.getU32(full_block[full_block.len - 4 ..][0..4]);
    if (blockCrc(data, block_type) != stored) return error.BlockCorrupted;
    return block_type;
}

pub const Footer = struct {
    index: BlockHandle,
    metaindex: BlockHandle,
};

pub fn encodeFooter(out: *[footer_len]u8, footer: Footer) void {
    @memcpy(out[0..4], magic);
    coding.putU16(out[4..6], format_version);
    out[6] = 0; // little endian
    out[7] = 0; // reserved
    coding.putU64(out[8..16], footer.index.offset);
    coding.putU64(out[16..24], footer.index.size);
    coding.putU64(out[24..32], footer.metaindex.offset);
    coding.putU64(out[32..40], footer.metaindex.size);
    @memset(out[40..48], 0); // reserved for a checksum extension
}

/// Every field defect and every out-of-bounds handle is `SSTableCorrupted`.
/// The bounds pass runs with the field checks so a tampered metaindex cannot
/// steer a read at an arbitrary offset: each handle must end at least
/// `trailer_len` bytes before the footer itself.
pub fn decodeFooter(raw: []const u8, file_size: u64) error{SSTableCorrupted}!Footer {
    if (raw.len < footer_len) return error.SSTableCorrupted;
    if (!std.mem.eql(u8, raw[0..4], magic)) return error.SSTableCorrupted;
    if (coding.getU16(raw[4..6]) != format_version) return error.SSTableCorrupted;
    if (raw[6] != 0) return error.SSTableCorrupted; // endian
    if (raw[7] != 0) return error.SSTableCorrupted; // reserved
    for (raw[40..48]) |b| if (b != 0) return error.SSTableCorrupted;
    if (file_size < footer_len + trailer_len) return error.SSTableCorrupted;
    const limit = file_size - footer_len;

    const index = BlockHandle{
        .offset = coding.getU64(raw[8..16]),
        .size = coding.getU64(raw[16..24]),
    };
    const metaindex = BlockHandle{
        .offset = coding.getU64(raw[24..32]),
        .size = coding.getU64(raw[32..40]),
    };
    if (!withinBounds(index, limit)) return error.SSTableCorrupted;
    if (!withinBounds(metaindex, limit)) return error.SSTableCorrupted;
    return .{ .index = index, .metaindex = metaindex };
}

fn withinBounds(h: BlockHandle, limit: u64) bool {
    const end = std.math.add(u64, h.offset, h.size) catch return false;
    if (end > limit) return false;
    return end <= limit - trailer_len; // limit >= trailer_len, checked above
}

test "block trailer round-trip and payload bit flip" {
    const data = "hello block";
    var full: [64]u8 = undefined;
    @memcpy(full[0..data.len], data);
    writeTrailer(full[data.len..][0..trailer_len], data, block_type_none);
    const view = full[0 .. data.len + trailer_len];
    try std.testing.expectEqual(block_type_none, try verifyTrailer(view));
    full[2] ^= 0x1;
    try std.testing.expectError(error.BlockCorrupted, verifyTrailer(view));
}

test "block handle varint pair round-trip and truncation" {
    var buf: [32]u8 = undefined;
    const h = BlockHandle{ .offset = 300, .size = 40000 };
    const n = try encodeHandle(h, &buf);
    const back = try decodeHandle(buf[0..n]);
    try std.testing.expectEqual(h.offset, back.offset);
    try std.testing.expectEqual(h.size, back.size);
    try std.testing.expectError(error.SSTableCorrupted, decodeHandle(buf[0 .. n - 1]));
}

test "footer field and bounds rejection" {
    var raw: [footer_len]u8 = undefined;
    encodeFooter(&raw, .{
        .index = .{ .offset = 10, .size = 20 },
        .metaindex = .{ .offset = 40, .size = 30 },
    });
    const f = try decodeFooter(&raw, 1000);
    try std.testing.expectEqual(@as(u64, 10), f.index.offset);
    try std.testing.expectEqual(@as(u64, 30), f.metaindex.size);
    // index ends at 30; a 60-byte file leaves only 12 bytes before the footer
    try std.testing.expectError(error.SSTableCorrupted, decodeFooter(&raw, 60));
    raw[7] = 1; // reserved
    try std.testing.expectError(error.SSTableCorrupted, decodeFooter(&raw, 1000));
}
