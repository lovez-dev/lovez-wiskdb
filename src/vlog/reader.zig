//! Positional VLog reads with CRC validation. The reader retains `io` so
//! its final reference can close the file. Invalid entries return
//! `VLogCorrupted` rather than a missing-key result.

const std = @import("std");
const disk = @import("../io/io.zig");
const Io = std.Io;
const entry = @import("format.zig");
const refcount = @import("../util/refcount.zig");
const BlockCache = @import("../cache/block_cache.zig").BlockCache;
const crc = @import("../util/crc.zig");

pub const ReadResult = struct {
    seq: u64,
    expire_at: u64,
    key: []const u8,
    value: []const u8,
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    io: Io,
    file: disk.File,
    file_id: u64,

    pub fn open(
        allocator: std.mem.Allocator,
        dir: disk.Dir,
        io: Io,
        file_id: u64,
    ) (disk.File.OpenError || std.fmt.BufPrintError || std.mem.Allocator.Error)!*Holder {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{d:0>6}.vlog", .{file_id});
        const file = try dir.openFile(io, name, .{ .mode = .read_only });
        errdefer file.close(io);
        return try Holder.create(allocator, .{ .allocator = allocator, .io = io, .file = file, .file_id = file_id });
    }

    /// `key`/`value` borrow the caller's buffers; inconsistent stored lengths
    /// are rejected before slicing, including in builds without assertions.
    pub fn readAt(
        self: *Reader,
        offset: u64,
        key_buf: []u8,
        val_buf: []u8,
    ) (error{ VLogCorrupted, UnsupportedFormatVersion } || Io.File.ReadPositionalError)!ReadResult {
        return self.readAtImpl(offset, key_buf, val_buf, null);
    }

    /// Cached records own their bytes, not a reader pin. Callers enforce the
    /// file retirement gate before using this path; hits still validate CRCs.
    pub fn readAtCached(
        self: *Reader,
        offset: u64,
        key_buf: []u8,
        val_buf: []u8,
        cache: *BlockCache,
    ) (error{ VLogCorrupted, UnsupportedFormatVersion } || Io.File.ReadPositionalError)!ReadResult {
        return self.readAtImpl(offset, key_buf, val_buf, cache);
    }

    fn readAtImpl(
        self: *Reader,
        offset: u64,
        key_buf: []u8,
        val_buf: []u8,
        cache: ?*BlockCache,
    ) (error{ VLogCorrupted, UnsupportedFormatVersion } || Io.File.ReadPositionalError)!ReadResult {
        if (offset % entry.entry_align != 0) return error.VLogCorrupted;
        var record: [8192]u8 = undefined;
        if (key_buf.len <= record.len - entry.header_len - entry.crc_len and val_buf.len <= record.len - entry.header_len - entry.crc_len - key_buf.len) {
            const cache_key = @import("../cache/block_cache.zig").Key{ .file_id = self.file_id, .offset = offset };
            if (cache) |c| {
                if (c.canStore(cache_key, 1)) {
                    if (c.acquire(cache_key)) |cached| {
                        var held = cached;
                        defer held.release();
                        return decodeRecord(held.bytes(), key_buf, val_buf);
                    }
                }
            }
            const read_len = entry.header_len + key_buf.len + val_buf.len + entry.crc_len;
            const got = try self.file.readPositionalAll(self.io, record[0..read_len], offset);
            const result = try decodeRecord(record[0..got], key_buf, val_buf);
            const actual_len = entry.header_len + result.key.len + result.value.len + entry.crc_len;
            if (cache) |c| {
                if (c.canStore(cache_key, actual_len)) {
                    // Caching is best effort: admission failure cannot turn a
                    // verified read into a new allocation failure.
                    var held = c.insertCopy(cache_key, record[0..actual_len]) catch return result;
                    held.release();
                }
            }
            return result;
        }
        var hdr: [entry.header_len]u8 = undefined;
        try self.readInto(&hdr, offset);
        const h = try entry.decodeHeader(&hdr);
        if (h.key_len > key_buf.len or h.val_len > val_buf.len) return error.VLogCorrupted;
        try self.readInto(key_buf[0..h.key_len], offset + entry.header_len);
        try self.readInto(val_buf[0..h.val_len], offset + entry.header_len + h.key_len);
        var crc_buf: [entry.crc_len]u8 = undefined;
        try self.readInto(&crc_buf, offset + entry.header_len + h.key_len + h.val_len);
        if (entry.entryCrc(key_buf[0..h.key_len], val_buf[0..h.val_len]) != std.mem.readInt(u32, &crc_buf, .little)) {
            return error.VLogCorrupted;
        }
        return .{
            .seq = h.seq,
            .expire_at = h.expire_at,
            .key = key_buf[0..h.key_len],
            .value = val_buf[0..h.val_len],
        };
    }

    fn decodeRecord(record: []const u8, key_buf: []u8, val_buf: []u8) (error{ VLogCorrupted, UnsupportedFormatVersion })!ReadResult {
        if (record.len < entry.header_len) return error.VLogCorrupted;
        const h = try entry.decodeHeader(record[0..entry.header_len]);
        if (h.key_len > key_buf.len or h.val_len > val_buf.len) return error.VLogCorrupted;
        const key_end = entry.header_len + @as(usize, h.key_len);
        const value_end = std.math.add(usize, key_end, h.val_len) catch return error.VLogCorrupted;
        if (value_end > record.len or record.len - value_end < entry.crc_len) return error.VLogCorrupted;
        if (crc.crc32(record[entry.header_len..value_end]) != std.mem.readInt(u32, record[value_end..][0..entry.crc_len], .little)) return error.VLogCorrupted;
        @memcpy(key_buf[0..h.key_len], record[entry.header_len..key_end]);
        @memcpy(val_buf[0..h.val_len], record[key_end..value_end]);
        return .{ .seq = h.seq, .expire_at = h.expire_at, .key = key_buf[0..h.key_len], .value = val_buf[0..h.val_len] };
    }

    fn readInto(self: *Reader, buf: []u8, offset: u64) (error{VLogCorrupted} || Io.File.ReadPositionalError)!void {
        // Raw positional read: a short read is a VALUE here (n < len), not an
        // EOF error — that keeps UnexpectedEof out of every caller's set.
        const n = try self.file.readPositionalAll(self.io, buf, offset);
        if (n != buf.len) return error.VLogCorrupted; // torn under a visible pointer
    }

    fn destroy(self: *Reader) void {
        self.file.close(self.io);
        const holder: *Holder = @fieldParentPtr("data", self);
        self.allocator.destroy(holder);
    }

    pub const Holder = refcount.RefCounted(Reader, destroy);
};

test "reader: unaligned pointers, bit rot, and torn tails are VLogCorrupted" {
    const writer = @import("writer.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var w = try writer.Writer.create(tmp.dir, io, 5, 1 << 20);
    const key = "abcdef";
    const val = "payload-xyz";
    _ = try w.append(io, 7, 0, key, val, null);
    w.close(io); // release the write handle before the read-only open

    const h = try Reader.open(std.testing.allocator, tmp.dir, io, 5);
    defer h.release();
    var kbuf: [16]u8 = undefined;
    var vbuf: [64]u8 = undefined;

    try std.testing.expectError(error.VLogCorrupted, h.data.readAt(0, kbuf[0 .. key.len - 1], &vbuf));
    try std.testing.expectError(error.VLogCorrupted, h.data.readAt(0, &kbuf, vbuf[0 .. val.len - 1]));
    const r = try h.data.readAt(0, &kbuf, &vbuf);
    try std.testing.expectEqual(@as(u64, 7), r.seq);
    try std.testing.expectEqualStrings(key, r.key);
    try std.testing.expectEqualStrings(val, r.value);

    try std.testing.expectError(error.VLogCorrupted, h.data.readAt(1, &kbuf, &vbuf)); // unaligned

    // Bit rot in the value: header stays valid, entry CRC must catch it.
    const f = try tmp.dir.openFile(io, "000005.vlog", .{ .mode = .read_write });
    try disk.pwriteAll(f, io, &.{0xFF}, entry.header_len + key.len);
    try std.testing.expectError(error.VLogCorrupted, h.data.readAt(0, &kbuf, &vbuf));

    // Cut the entry in half: the key read comes up short — damage, not EOF.
    try f.setLength(io, entry.header_len + 2);
    f.close(io);
    try std.testing.expectError(error.VLogCorrupted, h.data.readAt(0, &kbuf, &vbuf));
}

test "reader cache: owned records validate hits and reject undersized buffers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var w = try @import("writer.zig").Writer.create(tmp.dir, io, 41, 1 << 20);
    defer w.close(io);
    const pointer = try w.append(io, 7, 0, "key", "value", null);
    const holder = try Reader.open(a, tmp.dir, io, 41);
    defer holder.release();
    var cache = BlockCache.init(a, io, 4096);
    defer cache.deinit();
    var key: [8]u8 = undefined;
    var value: [16]u8 = undefined;
    const first = try holder.data.readAtCached(pointer.offset, &key, &value, &cache);
    try std.testing.expectEqualStrings("key", first.key);
    try std.testing.expectEqualStrings("value", first.value);
    // Only the actual record is retained, not output capacities or next bytes.
    try std.testing.expectEqual(@as(usize, entry.header_len + 3 + 5 + entry.crc_len), cache.stats().bytes);
    @memset(&key, 0);
    @memset(&value, 0);
    const second = try holder.data.readAtCached(pointer.offset, &key, &value, &cache);
    try std.testing.expectEqualStrings("value", second.value);
    try std.testing.expectEqual(@as(u64, 1), cache.stats().hits);
    try std.testing.expectError(error.VLogCorrupted, holder.data.readAtCached(pointer.offset, key[0..2], &value, &cache));
    try std.testing.expectError(error.VLogCorrupted, holder.data.readAtCached(pointer.offset, &key, value[0..4], &cache));
    try std.testing.expectError(error.VLogCorrupted, holder.data.readAtCached(1, &key, &value, &cache));
    // Disk damage is observable on uncached reads, while verified immutable
    // cache bytes remain a snapshot until eviction or reopen.
    try disk.pwriteAll(w.file, io, "!", entry.header_len + 3);
    try std.testing.expectError(error.VLogCorrupted, holder.data.readAt(pointer.offset, &key, &value));
    try std.testing.expectEqualStrings("value", (try holder.data.readAtCached(pointer.offset, &key, &value, &cache)).value);
    // In-memory damage must still be detected on every cache hit.
    var held = cache.acquire(.{ .file_id = 41, .offset = pointer.offset }).?;
    @constCast(held.bytes())[entry.header_len + 3] ^= 1;
    held.release();
    try std.testing.expectError(error.VLogCorrupted, holder.data.readAtCached(pointer.offset, &key, &value, &cache));
}

test "reader cache: admission failures remain successful verified reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var w = try @import("writer.zig").Writer.create(tmp.dir, io, 42, 1 << 20);
    defer w.close(io);
    const pointer = try w.append(io, 1, 0, "key", "value", null);
    const holder = try Reader.open(a, tmp.dir, io, 42);
    defer holder.release();
    var key: [3]u8 = undefined;
    var value: [5]u8 = undefined;
    for (0..5) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        var cache = BlockCache.init(failing.allocator(), io, 4096);
        defer cache.deinit();
        const result = try holder.data.readAtCached(pointer.offset, &key, &value, &cache);
        try std.testing.expectEqualStrings("value", result.value);
        try std.testing.expectEqualStrings("value", (try holder.data.readAtCached(pointer.offset, &key, &value, &cache)).value);
    }
}

test "reader cache: zero small and oversized admission keeps cache empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var w = try @import("writer.zig").Writer.create(tmp.dir, io, 43, 1 << 20);
    defer w.close(io);
    const small = try w.append(io, 1, 0, "k", "value", null);
    const large_value: [8192]u8 = @splat('v');
    const large = try w.append(io, 2, 0, "k", &large_value, null);
    const holder = try Reader.open(a, tmp.dir, io, 43);
    defer holder.release();
    var key: [1]u8 = undefined;
    var value: [8192]u8 = undefined;
    for ([_]usize{ 0, 8 }) |budget| {
        var cache = BlockCache.init(a, io, budget);
        defer cache.deinit();
        try std.testing.expectEqualStrings("value", (try holder.data.readAtCached(small.offset, &key, value[0..5], &cache)).value);
        try std.testing.expectEqual(@as(usize, 0), cache.stats().bytes);
    }
    var cache = BlockCache.init(a, io, 64 * 1024);
    defer cache.deinit();
    const result = try holder.data.readAtCached(large.offset, &key, &value, &cache);
    try std.testing.expectEqualSlices(u8, &large_value, result.value);
    try std.testing.expectEqual(@as(usize, 0), cache.stats().bytes);
}
