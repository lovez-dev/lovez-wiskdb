//! WriteBatch decoding and VLog pointer verification for WAL replay:
//! nothing here mutates the MemTable until a batch has fully validated,
//! so a failed pointer check discards the batch as a whole.

const std = @import("std");
const disk = @import("io/io.zig");
const MemTable = @import("memtable/memtable.zig").MemTable;
const vfmt = @import("vlog/format.zig");
const coding = @import("util/coding.zig");
const ivfmt = @import("util/internal_value.zig");

/// One maximum WriteBatch plus per-record header headroom: the batch cap
/// is logical, while the serialized form adds 28 B + expire per record.
pub const replay_buf_len: usize = 2 * 1024 * 1024;

pub const VlogFile = struct { id: u64, file: disk.File };

pub fn parseIdName(name: []const u8, suffix: []const u8) ?u64 {
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    const digits = name[0 .. name.len - suffix.len];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

fn vlogHandle(
    cache: *std.ArrayListUnmanaged(VlogFile),
    allocator: std.mem.Allocator,
    dir: disk.Dir,
    io: std.Io,
    id: u64,
) !?disk.File {
    for (cache.items) |vf| {
        if (vf.id == id) return vf.file;
    }
    var namebuf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&namebuf, "{d:0>6}.vlog", .{id}) catch unreachable;
    const f = dir.openFile(io, name, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    errdefer f.close(io);
    try cache.append(allocator, .{ .id = id, .file = f });
    return f;
}

/// Header magic/CRC plus key match plus entry CRC, all sized from the
/// record so a garbage pointer can never drive a giant read.
fn validatePointer(
    allocator: std.mem.Allocator,
    scratch: *std.ArrayListUnmanaged(u8),
    cache: *std.ArrayListUnmanaged(VlogFile),
    vlog_dir: disk.Dir,
    io: std.Io,
    id: u64,
    off: u64,
    expect_key: []const u8,
    expect_val_len: u32,
) !bool {
    const f = (try vlogHandle(cache, allocator, vlog_dir, io, id)) orelse return false;
    if (off % vfmt.entry_align != 0) return false;
    var hdr: [vfmt.header_len]u8 = undefined;
    disk.preadAll(f, io, &hdr, off) catch return false;
    const h = vfmt.decodeHeader(&hdr) catch return false;
    if (h.key_len != expect_key.len or h.val_len != expect_val_len) return false;
    const value_end = std.math.add(usize, h.key_len, h.val_len) catch return false;
    const payload_len = std.math.add(usize, value_end, vfmt.crc_len) catch return false;
    // Match WAL lengths before growing scratch; retain capacity across the batch.
    try scratch.resize(allocator, payload_len);
    disk.preadAll(f, io, scratch.items, off + vfmt.header_len) catch return false;
    const kbuf = scratch.items[0..h.key_len];
    const vbuf = scratch.items[h.key_len..value_end];
    if (!std.mem.eql(u8, kbuf, expect_key)) return false;
    if (vfmt.entryCrc(kbuf, vbuf) != coding.getU32(scratch.items[value_end..][0..vfmt.crc_len])) return false;
    return true;
}

/// Decode one WriteBatch into the MemTable. Returns false when a VLog
/// pointer past the watermark fails validation (caller truncates); batch
/// structure breaking inside a checksummed frame is real corruption.
/// Register external values by WAL id to prevent GC while replay is needed.
pub fn applyBatch(
    allocator: std.mem.Allocator,
    mt: *MemTable,
    vlog_files: *std.ArrayListUnmanaged(VlogFile),
    vlog_dir: disk.Dir,
    io: std.Io,
    batch: []const u8,
    durable: u64,
    max_seq: *u64,
    wal_id: u64,
    replayable: *std.AutoHashMapUnmanaged(u64, u64),
) !bool {
    if (batch.len < 12) return error.WalCorrupted;
    const first_seq = coding.getU64(batch[0..8]);
    const count = coding.getU32(batch[8..12]);

    // Two phases: nothing reaches the MemTable until every record has
    // decoded and every past-watermark pointer verified, so a late failure
    // discards the batch as a whole.
    const Pending = union(enum) {
        put: struct { seq: u64, key: []const u8, iv: []u8 },
        del: struct { seq: u64, key: []const u8 },
    };
    var ops: std.ArrayListUnmanaged(Pending) = .empty;
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(allocator);
    defer {
        for (ops.items) |op| switch (op) {
            .put => |p| allocator.free(p.iv),
            .del => {},
        };
        ops.deinit(allocator);
    }

    var pos: usize = 12;
    var i: u32 = 0;
    var top_seq: u64 = 0;
    while (i < count) : (i += 1) {
        if (pos + 28 > batch.len) return error.WalCorrupted;
        const flags = batch[pos];
        const key_len = coding.getU32(batch[pos + 4 ..][0..4]);
        const val_len = coding.getU32(batch[pos + 8 ..][0..4]);
        const vlog_id = coding.getU64(batch[pos + 12 ..][0..8]);
        const vlog_off = coding.getU32(batch[pos + 20 ..][0..4]);
        const val_crc = coding.getU32(batch[pos + 24 ..][0..4]);
        pos += 28;
        if (key_len > batch.len - pos) return error.WalCorrupted;
        const key = batch[pos .. pos + key_len];
        pos += key_len;
        const deleted = flags & ivfmt.deleted != 0;
        const is_inline = flags & ivfmt.inline_value != 0;
        const has_expire = flags & ivfmt.has_expiry != 0;
        var expire_at: ?u64 = null;
        if (has_expire) {
            if (pos + 8 > batch.len) return error.WalCorrupted;
            expire_at = coding.getU64(batch[pos..][0..8]);
            pos += 8;
        }
        var inline_bytes: []const u8 = &.{};
        if (is_inline) {
            if (val_len > batch.len - pos) return error.WalCorrupted;
            inline_bytes = batch[pos .. pos + val_len];
            pos += val_len;
        }
        const seq = first_seq + i;
        if (!deleted and !is_inline and seq > durable) {
            if (vlog_id == 0) return false;
            if (!try validatePointer(allocator, &scratch, vlog_files, vlog_dir, io, vlog_id, vlog_off, key, val_len)) return false;
        }
        if (deleted) {
            try ops.append(allocator, .{ .del = .{ .seq = seq, .key = key } });
        } else {
            const header = ivfmt.Header{
                .flags = flags & 0b111,
                .value_len = val_len,
                .file_id = vlog_id,
                .offset = vlog_off,
                .value_crc = val_crc,
                .expire_at = expire_at,
            };
            const iv = try allocator.alloc(u8, header.encodedLen());
            _ = ivfmt.encode(header, inline_bytes, iv) catch unreachable;
            ops.append(allocator, .{ .put = .{ .seq = seq, .key = key, .iv = iv } }) catch |e| {
                allocator.free(iv);
                return e;
            };
        }
        if (seq > top_seq) top_seq = seq;
    }

    for (ops.items) |op| switch (op) {
        .put => |p| {
            try mt.put(p.seq, p.key, p.iv);
            // Keep the newest referencing WAL id, independent of replay order.
            const header = ivfmt.Header.decode(p.iv) catch unreachable;
            if (!header.isInline()) {
                const vid = header.file_id;
                if (vid != 0) {
                    const gop = try replayable.getOrPut(allocator, vid);
                    if (!gop.found_existing or gop.value_ptr.* < wal_id) gop.value_ptr.* = wal_id;
                }
            }
        },
        .del => |d| try mt.delete(d.seq, d.key),
    };
    if (top_seq > max_seq.*) max_seq.* = top_seq;
    return true;
}

test "replay: pointer scratch reuses capacity after prewarm" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try @import("vlog/writer.zig").Writer.create(tmp.dir, io, 1, 4096);
    defer writer.close(io);
    const large: [128]u8 = @splat('v');
    const first = try writer.append(io, 1, 0, "long-key", &large, null);
    const second = try writer.append(io, 2, 0, "k", "small", null);
    const empty = try writer.append(io, 3, 0, "", "", null);

    var failing = std.testing.FailingAllocator.init(a, .{});
    const alloc = failing.allocator();
    var files: std.ArrayListUnmanaged(VlogFile) = .empty;
    defer {
        for (files.items) |vf| vf.file.close(io);
        files.deinit(alloc);
    }
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(alloc);
    try std.testing.expect(try validatePointer(alloc, &scratch, &files, tmp.dir, io, 1, first.offset, "long-key", large.len));
    const allocation_count = failing.alloc_index;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expect(try validatePointer(alloc, &scratch, &files, tmp.dir, io, 1, second.offset, "k", 5));
    try std.testing.expect(try validatePointer(alloc, &scratch, &files, tmp.dir, io, 1, empty.offset, "", 0));
    try std.testing.expect(try validatePointer(alloc, &scratch, &files, tmp.dir, io, 1, first.offset, "long-key", large.len));
    try std.testing.expect(!try validatePointer(alloc, &scratch, &files, tmp.dir, io, 1, first.offset, "long-key", large.len + 1));
    try std.testing.expectEqual(allocation_count, failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);
}

test "replay: pointer validation rejects mismatches and torn payloads" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try @import("vlog/writer.zig").Writer.create(tmp.dir, io, 1, 4096);
    defer writer.close(io);
    _ = try writer.append(io, 1, 0, "key", "value", null);
    var files: std.ArrayListUnmanaged(VlogFile) = .empty;
    defer {
        for (files.items) |vf| vf.file.close(io);
        files.deinit(a);
    }
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(a);
    // Length mismatches must not allocate payload storage, even for valid headers.
    try std.testing.expect(!try validatePointer(a, &scratch, &files, tmp.dir, io, 1, 0, "key", 6));
    try std.testing.expect(!try validatePointer(a, &scratch, &files, tmp.dir, io, 1, 0, "keys", 5));
    try std.testing.expectEqual(@as(usize, 0), scratch.capacity);
    try std.testing.expect(!try validatePointer(a, &scratch, &files, tmp.dir, io, 1, 0, "bad", 5));
    try std.testing.expect(!try validatePointer(a, &scratch, &files, tmp.dir, io, 1, 1, "key", 5));
    try std.testing.expect(!try validatePointer(a, &scratch, &files, tmp.dir, io, 2, 0, "key", 5));
    const crc_offset = vfmt.header_len + 3 + 5;
    var bad_crc: [vfmt.crc_len]u8 = undefined;
    coding.putU32(&bad_crc, vfmt.entryCrc("key", "value") ^ 1);
    try disk.pwriteAll(writer.file, io, &bad_crc, crc_offset);
    try std.testing.expect(!try validatePointer(a, &scratch, &files, tmp.dir, io, 1, 0, "key", 5));
    try writer.file.setLength(io, crc_offset + vfmt.crc_len - 1);
    try std.testing.expect(!try validatePointer(a, &scratch, &files, tmp.dir, io, 1, 0, "key", 5));
    try writer.file.setLength(io, vfmt.header_len - 1);
    try std.testing.expect(!try validatePointer(a, &scratch, &files, tmp.dir, io, 1, 0, "key", 5));
}

fn checkPointerAllocationFailures(a: std.mem.Allocator, dir: disk.Dir, second_off: u32) !void {
    const io = std.testing.io;
    var files: std.ArrayListUnmanaged(VlogFile) = .empty;
    defer {
        for (files.items) |vf| vf.file.close(io);
        files.deinit(a);
    }
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(a);
    try std.testing.expect(try validatePointer(a, &scratch, &files, dir, io, 1, 0, "k", 1));
    try std.testing.expect(try validatePointer(a, &scratch, &files, dir, io, 1, second_off, "k", 1024));
}

test "replay: pointer cache and scratch release resources on allocation failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try @import("vlog/writer.zig").Writer.create(tmp.dir, io, 1, 4096);
    defer writer.close(io);
    _ = try writer.append(io, 1, 0, "k", "v", null);
    const large: [1024]u8 = @splat('v');
    const second = try writer.append(io, 2, 0, "k", &large, null);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkPointerAllocationFailures, .{ tmp.dir, second.offset });
}

test "replay: a late invalid pointer leaves the entire batch unapplied" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try @import("vlog/writer.zig").Writer.create(tmp.dir, io, 1, 4096);
    defer writer.close(io);
    const pointers = [_]@import("vlog/writer.zig").Pointer{
        try writer.append(io, 1, 0, "one", "111", null),
        try writer.append(io, 2, 0, "two", "222", null),
    };
    var batch: [12 + 2 * (28 + 3)]u8 = @splat(0);
    coding.putU64(batch[0..8], 1);
    coding.putU32(batch[8..12], 2);
    for (pointers, 0..) |pointer, i| {
        const pos = 12 + i * 31;
        coding.putU32(batch[pos + 4 ..][0..4], 3);
        coding.putU32(batch[pos + 8 ..][0..4], 3);
        coding.putU64(batch[pos + 12 ..][0..8], pointer.file_id);
        coding.putU32(batch[pos + 20 ..][0..4], pointer.offset);
        @memcpy(batch[pos + 28 ..][0..3], if (i == 0) "one" else "bad");
    }
    const holder = try MemTable.create(a, 1);
    defer holder.release();
    var files: std.ArrayListUnmanaged(VlogFile) = .empty;
    defer {
        for (files.items) |vf| vf.file.close(io);
        files.deinit(a);
    }
    var replayable: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    defer replayable.deinit(a);
    var max_seq: u64 = 0;
    try std.testing.expect(!try applyBatch(a, &holder.data, &files, tmp.dir, io, &batch, 0, &max_seq, 7, &replayable));
    try std.testing.expect(holder.data.get("one", 2) == null);
    try std.testing.expectEqual(@as(u64, 0), max_seq);
    try std.testing.expectEqual(@as(u32, 0), replayable.count());
    @memcpy(batch[batch.len - 3 ..], "two");
    try std.testing.expect(try applyBatch(a, &holder.data, &files, tmp.dir, io, &batch, 0, &max_seq, 7, &replayable));
    try std.testing.expect(holder.data.get("one", 2) != null);
    try std.testing.expect(holder.data.get("two", 2) != null);
    try std.testing.expectEqual(@as(u64, 2), max_seq);
    try std.testing.expectEqual(@as(u64, 7), replayable.get(1).?);
}
