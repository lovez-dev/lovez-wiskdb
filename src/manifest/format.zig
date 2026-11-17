//! MANIFEST codec: a WAL-style frame (magic `WKMF`, same 15-byte header
//! layout) wrapping one VersionEdit payload — `prev_edit_crc: u32 LE`
//! then repeated `(tag varint32, payload_len varint32, bytes)` entries.
//! The prev-crc chain catches edits that pass frame CRC but arrive out of
//! order; unknown tags skip by payload_len.

const std = @import("std");
const crc = @import("../util/crc.zig");
const coding = @import("../util/coding.zig");
const varint = @import("../util/varint.zig");

pub const magic = "WKMF";
pub const frame_header_len = 15;
pub const max_payload_len: u16 = 32768;

pub const current_version: u16 = 1;
// Persisted comparator identity stays stable across project renames.
pub const comparator_name = "wiskdb.InternalKey.v1";

pub const FrameType = enum(u8) { full = 1, first = 2, middle = 3, last = 4 };

pub fn frameType(raw: u8) error{ManifestCorrupted}!FrameType {
    return switch (raw) {
        1 => .full,
        2 => .first,
        3 => .middle,
        4 => .last,
        else => error.ManifestCorrupted, // SYNCED frames never appear here
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

/// Bad magic, header CRC, length outside `1..=32768`, or an unknown type
/// all reject as `ManifestCorrupted` — the same read order as the WAL.
pub fn decodeHeader(raw: []const u8) error{ManifestCorrupted}!Header {
    if (raw.len < frame_header_len) return error.ManifestCorrupted;
    if (!std.mem.eql(u8, raw[0..4], magic)) return error.ManifestCorrupted;
    if (crc.crc32(raw[0..11]) != coding.getU32(raw[11..15])) return error.ManifestCorrupted;
    const len = coding.getU16(raw[5..7]);
    if (len == 0 or len > max_payload_len) return error.ManifestCorrupted;
    return .{
        .frame_type = try frameType(raw[4]),
        .payload_len = len,
        .payload_crc = coding.getU32(raw[7..11]),
    };
}

pub const Tag = enum(u32) {
    comparator = 1,
    log_number = 2,
    next_file_number = 3,
    last_sequence = 4,
    delete_file = 5,
    add_file = 6,
    vlog_delete = 7,
    db_id = 8,
    format_version = 9,
    _,
};

pub const DeleteFile = struct { level: u32, file_id: u64 };

pub const FileMeta = struct {
    level: u32,
    file_id: u64,
    file_size: u64,
    smallest: []const u8,
    largest: []const u8,
    min_seq: u64,
    max_seq: u64,
    /// Packed vlog-id set bytes (same encoding as the table props block); opaque here.
    vlog_ids: []const u8,

    pub fn deinit(self: FileMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.smallest);
        allocator.free(self.largest);
        allocator.free(self.vlog_ids);
    }
};

pub const Edit = struct {
    prev_edit_crc: u32 = 0,
    comparator: ?[]const u8 = null,
    log_number: ?u64 = null,
    next_file_number: ?u64 = null,
    last_sequence: ?u64 = null,
    deletes: []const DeleteFile = &.{},
    adds: []const FileMeta = &.{},
    vlog_deletes: []const u64 = &.{},
    db_id: ?[16]u8 = null,
    format_version: ?u16 = null,

    pub fn deinit(self: *Edit, allocator: std.mem.Allocator) void {
        if (self.comparator) |c| allocator.free(c);
        for (self.adds) |a| a.deinit(allocator);
        if (self.adds.len != 0) allocator.free(self.adds);
        if (self.deletes.len != 0) allocator.free(self.deletes);
        if (self.vlog_deletes.len != 0) allocator.free(self.vlog_deletes);
        self.* = .{};
    }
};

fn putVarint(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: u32) error{OutOfMemory}!void {
    var buf: [5]u8 = undefined;
    const n = varint.putU32(&buf, v) catch unreachable; // u32 always fits
    try out.appendSlice(allocator, buf[0..n]);
}

fn putString(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}!void {
    try putVarint(out, allocator, @intCast(s.len));
    try out.appendSlice(allocator, s);
}

fn putEntry(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    tag: Tag,
    body: []const u8,
) error{OutOfMemory}!void {
    try putVarint(out, allocator, @backingInt(tag));
    try putVarint(out, allocator, @intCast(body.len));
    try out.appendSlice(allocator, body);
}

/// Encode one edit: `prev_edit_crc` first, then tag/len/body entries.
pub fn encode(allocator: std.mem.Allocator, edit: *const Edit) error{OutOfMemory}![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var head: [4]u8 = undefined;
    coding.putU32(&head, edit.prev_edit_crc);
    try out.appendSlice(allocator, &head);

    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);

    if (edit.comparator) |c| {
        body.clearRetainingCapacity();
        try putString(&body, allocator, c);
        try putEntry(&out, allocator, .comparator, body.items);
    }
    inline for (.{ .log_number, .next_file_number, .last_sequence }) |field| {
        if (@field(edit, @tagName(field))) |v| {
            body.clearRetainingCapacity();
            var b: [8]u8 = undefined;
            coding.putU64(&b, v);
            try body.appendSlice(allocator, &b);
            try putEntry(&out, allocator, field, body.items);
        }
    }
    for (edit.deletes) |d| {
        body.clearRetainingCapacity();
        var lv: [4]u8 = undefined;
        var id: [8]u8 = undefined;
        coding.putU32(&lv, d.level);
        coding.putU64(&id, d.file_id);
        try body.appendSlice(allocator, &lv);
        try body.appendSlice(allocator, &id);
        try putEntry(&out, allocator, .delete_file, body.items);
    }
    for (edit.adds) |a| {
        body.clearRetainingCapacity();
        var lv: [4]u8 = undefined;
        var id: [8]u8 = undefined;
        var sz: [8]u8 = undefined;
        var mn: [8]u8 = undefined;
        var mx: [8]u8 = undefined;
        coding.putU32(&lv, a.level);
        coding.putU64(&id, a.file_id);
        coding.putU64(&sz, a.file_size);
        coding.putU64(&mn, a.min_seq);
        coding.putU64(&mx, a.max_seq);
        try body.appendSlice(allocator, &lv);
        try body.appendSlice(allocator, &id);
        try body.appendSlice(allocator, &sz);
        try putString(&body, allocator, a.smallest);
        try putString(&body, allocator, a.largest);
        try body.appendSlice(allocator, &mn);
        try body.appendSlice(allocator, &mx);
        try putString(&body, allocator, a.vlog_ids);
        try putEntry(&out, allocator, .add_file, body.items);
    }
    for (edit.vlog_deletes) |vid| {
        body.clearRetainingCapacity();
        var b: [8]u8 = undefined;
        coding.putU64(&b, vid);
        try body.appendSlice(allocator, &b);
        try putEntry(&out, allocator, .vlog_delete, body.items);
    }
    if (edit.db_id) |id| {
        body.clearRetainingCapacity();
        try body.appendSlice(allocator, &id);
        try putEntry(&out, allocator, .db_id, body.items);
    }
    if (edit.format_version) |fv| {
        body.clearRetainingCapacity();
        var b: [2]u8 = undefined;
        coding.putU16(&b, fv);
        try body.appendSlice(allocator, &b);
        try putEntry(&out, allocator, .format_version, body.items);
    }
    return out.toOwnedSlice(allocator);
}

fn takeU64(body: []const u8, pos: *usize) error{ManifestCorrupted}!u64 {
    if (pos.* + 8 > body.len) return error.ManifestCorrupted;
    const v = coding.getU64(body[pos.*..][0..8]);
    pos.* += 8;
    return v;
}

fn takeString(allocator: std.mem.Allocator, body: []const u8, pos: *usize) error{ ManifestCorrupted, OutOfMemory }![]u8 {
    const len_d = varint.getU32(body[pos.*..]) catch return error.ManifestCorrupted;
    pos.* += len_d.len;
    if (len_d.value > body.len - pos.*) return error.ManifestCorrupted;
    const s = try allocator.alloc(u8, len_d.value);
    errdefer allocator.free(s);
    @memcpy(s, body[pos.* .. pos.* + len_d.value]);
    pos.* += len_d.value;
    return s;
}

/// Decode one payload into an owned Edit; every bounds failure is
/// ManifestCorrupted. Unknown tags skip by payload_len.
pub fn decode(allocator: std.mem.Allocator, payload: []const u8) error{ ManifestCorrupted, OutOfMemory }!Edit {
    if (payload.len < 4) return error.ManifestCorrupted;
    var edit: Edit = .{ .prev_edit_crc = coding.getU32(payload[0..4]) };
    errdefer edit.deinit(allocator);

    var deletes: std.ArrayListUnmanaged(DeleteFile) = .empty;
    errdefer deletes.deinit(allocator);
    var adds: std.ArrayListUnmanaged(FileMeta) = .empty;
    errdefer {
        for (adds.items) |a| a.deinit(allocator);
        adds.deinit(allocator);
    }
    var vlog_deletes: std.ArrayListUnmanaged(u64) = .empty;
    errdefer vlog_deletes.deinit(allocator);

    var pos: usize = 4;
    while (pos < payload.len) {
        const tag_d = varint.getU32(payload[pos..]) catch return error.ManifestCorrupted;
        pos += tag_d.len;
        const len_d = varint.getU32(payload[pos..]) catch return error.ManifestCorrupted;
        pos += len_d.len;
        if (len_d.value > payload.len - pos) return error.ManifestCorrupted;
        const body = payload[pos .. pos + len_d.value];
        pos += len_d.value;

        switch (tag_d.value) {
            @backingInt(Tag.comparator) => {
                var bpos: usize = 0;
                const s = try takeString(allocator, body, &bpos);
                if (edit.comparator) |old| allocator.free(old);
                edit.comparator = s;
            },
            @backingInt(Tag.log_number) => {
                var bpos: usize = 0;
                edit.log_number = try takeU64(body, &bpos);
            },
            @backingInt(Tag.next_file_number) => {
                var bpos: usize = 0;
                edit.next_file_number = try takeU64(body, &bpos);
            },
            @backingInt(Tag.last_sequence) => {
                var bpos: usize = 0;
                edit.last_sequence = try takeU64(body, &bpos);
            },
            @backingInt(Tag.delete_file) => {
                if (body.len != 12) return error.ManifestCorrupted;
                try deletes.append(allocator, .{
                    .level = coding.getU32(body[0..4]),
                    .file_id = coding.getU64(body[4..12]),
                });
            },
            @backingInt(Tag.add_file) => {
                var bpos: usize = 0;
                if (bpos + 20 > body.len) return error.ManifestCorrupted;
                const level = coding.getU32(body[0..4]);
                bpos = 4;
                const file_id = try takeU64(body, &bpos);
                const file_size = try takeU64(body, &bpos);
                const smallest = try takeString(allocator, body, &bpos);
                errdefer allocator.free(smallest);
                const largest = try takeString(allocator, body, &bpos);
                errdefer allocator.free(largest);
                const min_seq = try takeU64(body, &bpos);
                const max_seq = try takeU64(body, &bpos);
                const vlog_ids = try takeString(allocator, body, &bpos);
                errdefer allocator.free(vlog_ids);
                if (bpos != body.len) return error.ManifestCorrupted;
                try adds.append(allocator, .{
                    .level = level,
                    .file_id = file_id,
                    .file_size = file_size,
                    .smallest = smallest,
                    .largest = largest,
                    .min_seq = min_seq,
                    .max_seq = max_seq,
                    .vlog_ids = vlog_ids,
                });
            },
            @backingInt(Tag.vlog_delete) => {
                var bpos: usize = 0;
                try vlog_deletes.append(allocator, try takeU64(body, &bpos));
            },
            @backingInt(Tag.db_id) => {
                if (body.len != 16) return error.ManifestCorrupted;
                var id: [16]u8 = undefined;
                @memcpy(&id, body);
                edit.db_id = id;
            },
            @backingInt(Tag.format_version) => {
                if (body.len != 2) return error.ManifestCorrupted;
                edit.format_version = coding.getU16(body[0..2]);
            },
            else => {}, // unknown tag: skip by payload_len
        }
    }
    edit.deletes = try deletes.toOwnedSlice(allocator);
    edit.adds = try adds.toOwnedSlice(allocator);
    edit.vlog_deletes = try vlog_deletes.toOwnedSlice(allocator);
    return edit;
}

test "manifest codec: full edit round-trips field by field" {
    const alloc = std.testing.allocator;
    var orig: Edit = .{
        .prev_edit_crc = 0xDEADBEEF,
        .comparator = comparator_name,
        .log_number = 7,
        .next_file_number = 12,
        .last_sequence = 99,
        .deletes = &.{ .{ .level = 0, .file_id = 3 }, .{ .level = 2, .file_id = 9 } },
        .vlog_deletes = &.{ 4, 5 },
        .db_id = @as([16]u8, @splat(1)),
        .format_version = current_version,
    };
    const add: FileMeta = .{
        .level = 0,
        .file_id = 11,
        .file_size = 4096,
        .smallest = "aaa",
        .largest = "zzz",
        .min_seq = 10,
        .max_seq = 20,
        .vlog_ids = &.{ 1, 10, 0, 0, 0, 0, 0, 0, 0, 5 }, // opaque packed bytes
    };
    orig.adds = &.{add};

    const bytes = try encode(alloc, &orig);
    defer alloc.free(bytes);
    var got = try decode(alloc, bytes);
    defer got.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), got.prev_edit_crc);
    try std.testing.expectEqualStrings(comparator_name, got.comparator.?);
    try std.testing.expectEqual(@as(u64, 7), got.log_number.?);
    try std.testing.expectEqual(@as(u64, 12), got.next_file_number.?);
    try std.testing.expectEqual(@as(u64, 99), got.last_sequence.?);
    try std.testing.expectEqual(@as(usize, 2), got.deletes.len);
    try std.testing.expectEqual(@as(u32, 2), got.deletes[1].level);
    try std.testing.expectEqual(@as(u64, 9), got.deletes[1].file_id);
    try std.testing.expectEqual(@as(usize, 1), got.adds.len);
    const a = got.adds[0];
    try std.testing.expectEqualStrings("aaa", a.smallest);
    try std.testing.expectEqualStrings("zzz", a.largest);
    try std.testing.expectEqual(@as(u64, 4096), a.file_size);
    try std.testing.expectEqual(@as(u64, 20), a.max_seq);
    try std.testing.expectEqualSlices(u8, &.{ 1, 10, 0, 0, 0, 0, 0, 0, 0, 5 }, a.vlog_ids);
    try std.testing.expectEqual(@as(usize, 2), got.vlog_deletes.len);
    try std.testing.expectEqual(@as(u64, 5), got.vlog_deletes[1]);
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(1)), &got.db_id.?);
    try std.testing.expectEqual(current_version, got.format_version.?);
}

test "manifest codec: unknown tags skip; every truncation is ManifestCorrupted" {
    const alloc = std.testing.allocator;
    const base: Edit = .{ .log_number = 3, .format_version = current_version };
    const bytes = try encode(alloc, &base);
    defer alloc.free(bytes);

    // unknown tag99 with a body: skipped, remaining fields survive
    var with_unknown: std.ArrayListUnmanaged(u8) = .empty;
    defer with_unknown.deinit(alloc);
    try with_unknown.appendSlice(alloc, bytes);
    var body: [6]u8 = @splat(0);
    var tn: [5]u8 = undefined;
    const n1 = varint.putU32(&tn, 99) catch unreachable;
    try with_unknown.appendSlice(alloc, tn[0..n1]);
    const n2 = varint.putU32(&tn, body.len) catch unreachable;
    try with_unknown.appendSlice(alloc, tn[0..n2]);
    try with_unknown.appendSlice(alloc, &body);

    var got = try decode(alloc, with_unknown.items);
    defer got.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 3), got.log_number.?);

    // every truncation point inside the entries rejects
    for (4..bytes.len) |cut| {
        if (decode(alloc, bytes[0..cut])) |e| {
            var ed = e; // a cut at an entry boundary is a valid shorter edit
            ed.deinit(alloc);
        } else |err| {
            try std.testing.expectEqual(error.ManifestCorrupted, err); // a mid-entry cut
        }
    }

    // body shorter than its declared length
    var short = bytes[0 .. bytes.len - 1];
    _ = &short;
    try std.testing.expectError(error.ManifestCorrupted, decode(alloc, bytes[0 .. bytes.len - 1]));

    // prev crc field itself missing
    try std.testing.expectError(error.ManifestCorrupted, decode(alloc, bytes[0..2]));
}

test "manifest frame codec: round-trip, then every defect is ManifestCorrupted" {
    var hdr: [frame_header_len]u8 = undefined;
    const payload = "edit-bytes";
    encodeHeader(&hdr, .full, payload.len, crc.crc32(payload));
    const h = try decodeHeader(&hdr);
    try std.testing.expectEqual(FrameType.full, h.frame_type);
    try std.testing.expectEqual(@as(u16, payload.len), h.payload_len);
    try std.testing.expectEqual(crc.crc32(payload), h.payload_crc);

    var bad = hdr;
    bad[0] ^= 0xFF; // magic
    try std.testing.expectError(error.ManifestCorrupted, decodeHeader(&bad));

    bad = hdr;
    bad[7] ^= 0xFF; // payload_crc field: header CRC must catch it
    try std.testing.expectError(error.ManifestCorrupted, decodeHeader(&bad));

    bad = hdr;
    bad[11] ^= 0xFF; // header CRC itself
    try std.testing.expectError(error.ManifestCorrupted, decodeHeader(&bad));

    encodeHeader(&bad, .full, 0, 0); // zero payload length
    try std.testing.expectError(error.ManifestCorrupted, decodeHeader(&bad));

    encodeHeader(&bad, .full, 32769, 0); // above the cap
    try std.testing.expectError(error.ManifestCorrupted, decodeHeader(&bad));

    encodeHeader(&bad, .full, 1, 0);
    bad[4] = 5; // SYNCED is WAL-only; repair header CRC so type is the only defect
    coding.putU32(bad[11..15], crc.crc32(bad[0..11]));
    try std.testing.expectError(error.ManifestCorrupted, decodeHeader(&bad));
}

fn decodeWithFailures(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var edit = try decode(allocator, bytes);
    defer edit.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), edit.adds.len);
}

test "manifest codec: allocation failures release partial records and owned arrays" {
    const alloc = std.testing.allocator;
    const adds = [_]FileMeta{.{ .level = 1, .file_id = 2, .file_size = 3, .smallest = "a", .largest = "z", .min_seq = 1, .max_seq = 4, .vlog_ids = "ids" }};
    const bytes = try encode(alloc, &.{ .comparator = comparator_name, .adds = &adds, .deletes = &.{.{ .level = 0, .file_id = 1 }}, .vlog_deletes = &.{8} });
    defer alloc.free(bytes);
    try std.testing.checkAllAllocationFailures(alloc, decodeWithFailures, .{bytes});
}
