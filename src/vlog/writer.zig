//! Append-only VLog writer with pre-write rotation. The rule — rotate
//! BEFORE a write that would cross the threshold — is what guarantees every
//! entry's start offset is `< vlog_file_size`, the bound the u32 `vlog_off`
//! relies on; checking after the write cannot stop one huge entry crossing.

const std = @import("std");
const disk = @import("../io/io.zig");
const Io = std.Io;
const entry = @import("format.zig");
const coding = @import("../util/coding.zig");
const crc = @import("../util/crc.zig");

pub const Pointer = struct {
    file_id: u64,
    offset: u32,
};

pub const Writer = struct {
    dir: disk.Dir,
    file: disk.File,
    file_id: u64,
    next_file_id: ?u64 = null, // supplied by the database shared file allocator
    directory_dirty: bool = true,
    // Set before a write attempt: failed streaming writes can still dirty the file.
    content_dirty: bool = true,
    /// Bytes written to the current file — rotation input, u64 on purpose: a
    /// single oversized entry may push it past `threshold` (and past u32).
    size: u64,
    threshold: u64,

    pub fn create(dir: disk.Dir, io: Io, first_id: u64, threshold: u64) (disk.File.OpenError || std.fmt.BufPrintError)!Writer {
        return .{
            .dir = dir,
            .file = try createOne(dir, io, first_id),
            .file_id = first_id,
            .size = 0,
            .threshold = threshold,
        };
    }

    fn createOne(dir: disk.Dir, io: Io, id: u64) (disk.File.OpenError || std.fmt.BufPrintError)!disk.File {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{d:0>6}.vlog", .{id});
        return dir.createFile(io, name, .{ .read = true, .exclusive = true });
    }

    pub const Record = struct { seq: u64, key: []const u8, value: []const u8 };

    /// Returns false without writing when this group needs the normal rotation path.
    pub fn appendGroup(self: *Writer, io: Io, records: []const Record, pointers: []Pointer) Io.File.WritePositionalError!bool {
        std.debug.assert(records.len == pointers.len);
        var total: usize = 0;
        for (records) |r| {
            if (r.key.len > std.math.maxInt(u32) or r.value.len > std.math.maxInt(u32)) return false;
            const size = entry.entryTotal(@intCast(r.key.len), @intCast(r.value.len));
            if (size > 65536 - total) return false;
            total += size;
        }
        if (total == 0 or self.size > self.threshold or total > self.threshold - self.size) return false;
        // Bound scratch space and combine only records that cannot trigger rotation.
        // Publish offsets only after the write succeeds; a failed tail stays orphaned.
        var buffer: [65536]u8 = undefined;
        var pos: usize = 0;
        for (records) |r| {
            const key_end = pos + entry.header_len + r.key.len;
            const value_end = key_end + r.value.len;
            const end = pos + entry.entryTotal(@intCast(r.key.len), @intCast(r.value.len));
            entry.encodeHeader(buffer[pos..][0..entry.header_len], r.seq, 0, @intCast(r.key.len), @intCast(r.value.len));
            @memcpy(buffer[pos + entry.header_len .. key_end], r.key);
            @memcpy(buffer[key_end..value_end], r.value);
            coding.putU32(buffer[value_end..][0..entry.crc_len], entry.entryCrc(r.key, r.value));
            @memset(buffer[value_end + entry.crc_len .. end], 0);
            pos = end;
        }
        self.content_dirty = true;
        try disk.pwriteAll(self.file, io, buffer[0..total], self.size);
        pos = 0;
        for (records, pointers) |r, *p| {
            p.* = .{ .file_id = self.file_id, .offset = @intCast(self.size + pos) };
            pos += entry.entryTotal(@intCast(r.key.len), @intCast(r.value.len));
        }
        self.size += total;
        return true;
    }
    /// A supplied checksum must describe the unchanged `value` bytes. Large
    /// writes combine it with the key CRC instead of scanning the value again.
    pub fn append(
        self: *Writer,
        io: Io,
        seq: u64,
        expire_at: u64,
        key: []const u8,
        value: []const u8,
        value_crc: ?u32,
    ) (Io.File.WritePositionalError || disk.File.OpenError || std.fmt.BufPrintError)!Pointer {
        const total = entry.entryTotal(@intCast(key.len), @intCast(value.len));
        if (self.size > 0 and self.size + total > self.threshold) try self.rotate(io);
        // After the rule: size==0, or size+total<=threshold with total>=40 —
        // either way the start offset is strictly below threshold <= u32 max.
        const off: u32 = @intCast(self.size);
        // Small records trade one bounded copy for fewer file writes.
        // Keep large records on the streaming path to bound stack usage.
        var record: [8192]u8 = undefined;
        if (total <= record.len) {
            const key_end = entry.header_len + key.len;
            const value_end = key_end + value.len;
            entry.encodeHeader(record[0..entry.header_len], seq, expire_at, @intCast(key.len), @intCast(value.len));
            @memcpy(record[entry.header_len..key_end], key);
            @memcpy(record[key_end..value_end], value);
            coding.putU32(record[value_end..][0..entry.crc_len], entry.entryCrc(key, value));
            @memset(record[value_end + entry.crc_len .. total], 0);
            self.content_dirty = true;
            try disk.pwriteAll(self.file, io, record[0..total], self.size);
            self.size += total;
            return .{ .file_id = self.file_id, .offset = off };
        }

        var hdr: [entry.header_len]u8 = undefined;
        entry.encodeHeader(&hdr, seq, expire_at, @intCast(key.len), @intCast(value.len));
        var pos = self.size;
        self.content_dirty = true;
        try disk.pwriteAll(self.file, io, &hdr, pos);
        pos += entry.header_len;
        try disk.pwriteAll(self.file, io, key, pos);
        pos += key.len;
        try disk.pwriteAll(self.file, io, value, pos);
        pos += value.len;
        var crc_buf: [entry.crc_len]u8 = undefined;
        // Combining has a fixed cost; the small-record path remains a direct
        // scan. The optional checksum comes from the WAL's existing value CRC.
        const checksum = if (value.len >= 8192 and value_crc != null)
            crc.combine(crc.crc32(key), value_crc.?, value.len)
        else
            entry.entryCrc(key, value);
        coding.putU32(&crc_buf, checksum);
        try disk.pwriteAll(self.file, io, &crc_buf, pos);
        pos += entry.crc_len;
        const pad: usize = @intCast(self.size + total - pos);
        if (pad > 0) {
            const zeros: [7]u8 = @splat(0);
            try disk.pwriteAll(self.file, io, zeros[0..pad], pos);
        }
        self.size += total;
        return .{ .file_id = self.file_id, .offset = off };
    }

    pub fn rotate(self: *Writer, io: Io) (disk.File.OpenError || std.fmt.BufPrintError || Io.File.SyncError)!void {
        // syncThrough syncs only the current file; make a rotated-out file
        // durable before a later SYNCED frame can claim its entries.
        try self.sync(io);
        const next_id = self.next_file_id orelse self.file_id + 1;
        const next_file = try createOne(self.dir, io, next_id);
        self.file.close(io);
        self.file_id = next_id;
        self.next_file_id = null;
        self.file = next_file;
        self.directory_dirty = true;
        self.content_dirty = true;
        self.size = 0;
    }

    pub fn sync(self: *Writer, io: Io) disk.DirectorySyncError!void {
        if (self.content_dirty) {
            try disk.fsync(self.file, io);
            self.content_dirty = false;
        }
        if (self.directory_dirty) {
            _ = try disk.syncDirectory(self.dir, io);
            self.directory_dirty = false;
        }
    }

    pub fn close(self: *Writer, io: Io) void {
        self.file.close(io);
    }
};

test "writer: aligned starts, below-threshold offsets, rotation, readback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const threshold = 1024; // entries are 144 B here: 7 fit, the 8th rotates
    var w = try Writer.create(tmp.dir, io, 42, threshold);
    defer w.close(io);

    var ptrs: [16]Pointer = undefined;
    const v: [100]u8 = @splat('v');
    for (0..16) |n| {
        const k: [2]u8 = .{ 'k', @intCast(n) };
        ptrs[n] = try w.append(io, @intCast(100 + n), 0, &k, &v, null);
        try std.testing.expect(ptrs[n].offset % entry.entry_align == 0);
        try std.testing.expect(ptrs[n].offset < threshold); // the u32-safety invariant
        if (n > 0 and ptrs[n].file_id != ptrs[n - 1].file_id) {
            try std.testing.expectEqual(@as(u64, 0), ptrs[n].offset); // fresh file starts at 0
            try std.testing.expectEqual(ptrs[n - 1].file_id + 1, ptrs[n].file_id);
        }
    }
    try std.testing.expectEqual(@as(u64, 42), ptrs[0].file_id);
    try std.testing.expect(ptrs[15].file_id > 42); // rotation really happened

    // Read entry 8 back through plain preads: header, key, value, entry CRC.
    const p = ptrs[8];
    var name_buf: [16]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d:0>6}.vlog", .{p.file_id});
    var f = try tmp.dir.openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    var hdr: [entry.header_len]u8 = undefined;
    try disk.preadAll(f, io, &hdr, p.offset);
    const h = try entry.decodeHeader(&hdr);
    try std.testing.expectEqual(@as(u32, 2), h.key_len);
    try std.testing.expectEqual(@as(u32, 100), h.val_len);
    var kbuf: [2]u8 = undefined;
    var vbuf: [100]u8 = undefined;
    try disk.preadAll(f, io, &kbuf, p.offset + entry.header_len);
    try disk.preadAll(f, io, &vbuf, p.offset + entry.header_len + 2);
    try std.testing.expectEqualSlices(u8, &.{ 'k', 8 }, &kbuf);
    try std.testing.expectEqualSlices(u8, &v, &vbuf);
    var crc_buf: [4]u8 = undefined;
    try disk.preadAll(f, io, &crc_buf, p.offset + entry.header_len + 2 + 100);
    try std.testing.expectEqual(entry.entryCrc(&kbuf, &vbuf), coding.getU32(&crc_buf));

    try std.testing.expectError(error.PathAlreadyExists, Writer.create(tmp.dir, io, 42, threshold));
}

test "writer: reused value checksums preserve entry bytes across size boundaries and rotation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var plain = try Writer.create(tmp.dir, io, 101, 64 * 1024);
    defer plain.close(io);
    var reused = try Writer.create(tmp.dir, io, 201, 64 * 1024);
    defer reused.close(io);
    const value = try allocator.alloc(u8, 65537);
    defer allocator.free(value);
    for (value, 0..) |*byte, i| byte.* = @truncate(i *% 19 +% (i >> 7));
    const key = "binary\x00key";
    const small_limit = 8192 - entry.header_len - entry.crc_len - key.len;
    for ([_]usize{ 0, small_limit, small_limit + 1, 8191, 8192, 8193, 65537 }, 0..) |len, i| {
        const payload = value[0..len];
        const expected = try plain.append(io, @intCast(i + 1), 4567, key, payload, null);
        const actual = try reused.append(io, @intCast(i + 1), 4567, key, payload, crc.crc32(payload));
        try std.testing.expectEqual(expected.offset, actual.offset);
        const size: usize = @intCast(entry.entryTotal(@intCast(key.len), @intCast(len)));
        const before = try allocator.alloc(u8, size);
        defer allocator.free(before);
        const after = try allocator.alloc(u8, size);
        defer allocator.free(after);
        var name: [32]u8 = undefined;
        const plain_file = try tmp.dir.openFile(io, try std.fmt.bufPrint(&name, "{d:0>6}.vlog", .{expected.file_id}), .{});
        defer plain_file.close(io);
        try disk.preadAll(plain_file, io, before, expected.offset);
        const reused_file = try tmp.dir.openFile(io, try std.fmt.bufPrint(&name, "{d:0>6}.vlog", .{actual.file_id}), .{});
        defer reused_file.close(io);
        try disk.preadAll(reused_file, io, after, actual.offset);
        try std.testing.expectEqualSlices(u8, before, after);
    }
    try std.testing.expect(plain.file_id > 101);
    try std.testing.expectEqual(plain.file_id - 101, reused.file_id - 201);
}

test "writer: grouped records match individual encoding and reject without changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var grouped = try Writer.create(tmp.dir, io, 91, 4096);
    defer grouped.close(io);
    var plain = try Writer.create(tmp.dir, io, 92, 4096);
    defer plain.close(io);
    const records = [_]Writer.Record{
        .{ .seq = 10, .key = "first", .value = "one" },
        .{ .seq = 11, .key = "second", .value = "two" },
    };
    var pointers: [2]Pointer = undefined;
    try std.testing.expect(try grouped.appendGroup(io, &records, &pointers));
    for (records, pointers) |r, p| {
        const expected = try plain.append(io, r.seq, 0, r.key, r.value, null);
        try std.testing.expectEqual(expected.offset, p.offset);
        try std.testing.expectEqual(grouped.file_id, p.file_id);
    }
    var actual: [256]u8 = undefined;
    var expected: [256]u8 = undefined;
    try disk.preadAll(grouped.file, io, actual[0..grouped.size], 0);
    try disk.preadAll(plain.file, io, expected[0..plain.size], 0);
    try std.testing.expectEqualSlices(u8, expected[0..plain.size], actual[0..grouped.size]);
    const before = grouped.size;
    grouped.threshold = before;
    try std.testing.expect(!try grouped.appendGroup(io, &records, &pointers));
    try std.testing.expectEqual(before, grouped.size);
    try std.testing.expectEqual(before, (try grouped.file.stat(io)).size);
    // A read-only handle deterministically rejects writes before any publication.
    const read_only = try tmp.dir.openFile(io, "000091.vlog", .{});
    defer read_only.close(io);
    const original = grouped.file;
    grouped.file = read_only;
    defer grouped.file = original;
    grouped.threshold = 4096;
    pointers[0] = .{ .file_id = 999, .offset = 123 };
    if (grouped.appendGroup(io, &records, &pointers)) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expectEqual(before, grouped.size);
    try std.testing.expectEqual(@as(u64, 999), pointers[0].file_id);
    try std.testing.expectEqual(@as(u32, 123), pointers[0].offset);
}
test "writer: failed grouped write publishes neither offsets nor size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var grouped = try Writer.create(tmp.dir, io, 93, 4096);
    defer grouped.close(io);
    const records = [_]Writer.Record{
        .{ .seq = 20, .key = "first", .value = "one" },
        .{ .seq = 21, .key = "second", .value = "two" },
    };
    var pointers = [_]Pointer{ .{ .file_id = 999, .offset = 123 }, .{ .file_id = 998, .offset = 456 } };
    disk.TestWrite.calls = 0;
    disk.TestWrite.fail_at = 0;
    defer disk.TestWrite.fail_at = std.math.maxInt(usize);
    try std.testing.expectError(error.InputOutput, grouped.appendGroup(io, &records, &pointers));
    try std.testing.expectEqual(@as(usize, 0), grouped.size);
    try std.testing.expectEqual(@as(u64, 999), pointers[0].file_id);
    try std.testing.expectEqual(@as(u32, 123), pointers[0].offset);
    try std.testing.expectEqual(@as(u64, 998), pointers[1].file_id);
    try std.testing.expectEqual(@as(u32, 456), pointers[1].offset);
}

test "writer: an oversized entry owns its file; the next write rotates first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var w = try Writer.create(tmp.dir, io, 7, 64);
    defer w.close(io);

    const big: [100]u8 = @splat('x'); // entry_total = 144 > threshold 64
    const p1 = try w.append(io, 1, 0, "a", &big, null);
    try std.testing.expectEqual(@as(u32, 0), p1.offset); // fresh file: written anyway
    const p2 = try w.append(io, 2, 0, "b", &big, null);
    try std.testing.expectEqual(@as(u64, 8), p2.file_id);
    try std.testing.expectEqual(@as(u32, 0), p2.offset); // rotated BEFORE the write
}

test "writer: failed rotation leaves the old writer open and retryable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try Writer.create(tmp.dir, io, 1, 64);
    defer writer.close(io);
    _ = try writer.append(io, 1, 0, "k", "v", null);
    try tmp.dir.createDirPath(io, "000002.vlog");
    if (writer.append(io, 2, 0, "k", "v", null)) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expectEqual(@as(u64, 1), writer.file_id);
    try writer.sync(io);
    try tmp.dir.deleteDir(io, "000002.vlog");
    const pointer = try writer.append(io, 2, 0, "k", "v", null);
    try std.testing.expectEqual(@as(u64, 2), pointer.file_id);
}

test "writer: directory barrier failure prevents rotation from retiring the old file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try Writer.create(tmp.dir, io, 1, 64);
    defer writer.close(io);
    _ = try writer.append(io, 1, 0, "key", "value", null);
    {
        disk.TestBarrier.target = tmp.dir.handle;
        disk.TestBarrier.calls = 0;
        disk.TestBarrier.fail_at = 0;
        defer disk.TestBarrier.target = null;
        try std.testing.expectError(error.InputOutput, writer.rotate(io));
    }
    try std.testing.expectEqual(@as(u64, 1), writer.file_id);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "000002.vlog", .{}));
    try writer.rotate(io);
    try std.testing.expectEqual(@as(u64, 2), writer.file_id);
}

test "writer sync: unchanged files skip fsync but new records and rotations require it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try Writer.create(tmp.dir, io, 1, 4096);
    defer writer.close(io);
    disk.TestSync.target = writer.file.handle;
    disk.TestSync.calls = 0;
    defer disk.TestSync.target = null;
    try writer.sync(io);
    try writer.sync(io);
    try std.testing.expectEqual(@as(usize, 1), disk.TestSync.calls);
    _ = try writer.append(io, 1, 0, "k", "v", null);
    try writer.sync(io);
    try writer.sync(io);
    try std.testing.expectEqual(@as(usize, 2), disk.TestSync.calls);

    const records = [_]Writer.Record{.{ .seq = 2, .key = "group", .value = "value" }};
    var pointers: [1]Pointer = undefined;
    try std.testing.expect(try writer.appendGroup(io, &records, &pointers));
    try writer.sync(io);
    try std.testing.expectEqual(@as(usize, 3), disk.TestSync.calls);
    // Rejecting a group without a write does not dirty the file.
    writer.threshold = writer.size;
    try std.testing.expect(!try writer.appendGroup(io, &records, &pointers));
    try writer.sync(io);
    try std.testing.expectEqual(@as(usize, 3), disk.TestSync.calls);

    try writer.rotate(io);
    disk.TestSync.target = writer.file.handle;
    disk.TestSync.calls = 0;
    try writer.sync(io);
    try writer.sync(io);
    try std.testing.expectEqual(@as(usize, 1), disk.TestSync.calls);
}

test "writer sync: failed file and directory barriers remain retryable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try Writer.create(tmp.dir, io, 1, 4096);
    defer writer.close(io);
    disk.TestSync.target = writer.file.handle;
    disk.TestSync.calls = 0;
    disk.TestSync.fail_at = 0;
    defer {
        disk.TestSync.target = null;
        disk.TestSync.fail_at = std.math.maxInt(usize);
    }
    disk.TestBarrier.target = tmp.dir.handle;
    disk.TestBarrier.calls = 0;
    disk.TestBarrier.fail_at = 0;
    defer disk.TestBarrier.target = null;
    try std.testing.expectError(error.InputOutput, writer.sync(io));
    try std.testing.expectEqual(@as(usize, 0), disk.TestBarrier.calls);
    try std.testing.expectError(error.InputOutput, writer.sync(io));
    try std.testing.expectEqual(@as(usize, 2), disk.TestSync.calls);
    try std.testing.expectEqual(@as(usize, 1), disk.TestBarrier.calls);
    // Retrying the directory barrier need not repeat the successful file sync.
    try writer.sync(io);
    try writer.sync(io);
    try std.testing.expectEqual(@as(usize, 2), disk.TestSync.calls);
    try std.testing.expectEqual(@as(usize, 2), disk.TestBarrier.calls);
}

test "writer sync: failed append attempts still require synchronization" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try Writer.create(tmp.dir, io, 1, 65536);
    defer writer.close(io);
    try writer.sync(io);
    disk.TestSync.target = writer.file.handle;
    disk.TestSync.calls = 0;
    defer disk.TestSync.target = null;
    disk.TestWrite.calls = 0;
    disk.TestWrite.fail_at = 1;
    defer disk.TestWrite.fail_at = std.math.maxInt(usize);
    const large: [9000]u8 = @splat('v');
    // Streaming append writes its header, then fails before the key payload.
    try std.testing.expectError(error.InputOutput, writer.append(io, 1, 0, "key", &large, null));
    try std.testing.expectEqual(@as(u64, 0), writer.size);
    try std.testing.expect((try writer.file.stat(io)).size > 0);
    try writer.sync(io);
    try writer.sync(io);
    try std.testing.expectEqual(@as(usize, 1), disk.TestSync.calls);

    const records = [_]Writer.Record{.{ .seq = 2, .key = "group", .value = "value" }};
    var pointers: [1]Pointer = undefined;
    disk.TestWrite.calls = 0;
    disk.TestWrite.fail_at = 0;
    try std.testing.expectError(error.InputOutput, writer.appendGroup(io, &records, &pointers));
    try writer.sync(io);
    try std.testing.expectEqual(@as(usize, 2), disk.TestSync.calls);
    // The small-record append path must conservatively dirty before writing too.
    disk.TestWrite.calls = 0;
    try std.testing.expectError(error.InputOutput, writer.append(io, 3, 0, "small", "value", null));
    try writer.sync(io);
    try std.testing.expectEqual(@as(usize, 3), disk.TestSync.calls);
}
