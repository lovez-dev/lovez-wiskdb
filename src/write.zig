//! Serialized writes: VLog append, WAL recording and MemTable publication.

const std = @import("std");
const dbz = @import("db.zig");
const vw = @import("vlog/writer.zig");
const coding = @import("util/coding.zig");
const ivfmt = @import("util/internal_value.zig");
const crc = @import("util/crc.zig");
const file_ids = @import("file_ids.zig");
const replay = @import("replay.zig");
const wf = @import("wal/format.zig");

const Db = dbz.Db;
const Op = dbz.Op;

inline fn beginWriteLocked(db: *Db) !void {
    db.write_mutex.lockUncancelable(db.io);
    errdefer db.write_mutex.unlock(db.io);
    if (db.closing or db.closed) return error.DbClosed;
    db.startRuntime();
    while (db.memtables.immutableCount() >= db.options.max_immutable_count and db.background_error == null) {
        db.write_cond.waitUncancelable(db.io, &db.write_mutex);
    }
    if (db.background_error) |err| return err;
}

inline fn encodeOneLocked(
    db: *Db,
    batch: *std.ArrayListUnmanaged(u8),
    op: Op,
    seq: u64,
    ptr_out: *vw.Pointer,
    checksum_out: *u32,
    grouped: bool,
    registered_vlog: *?u64,
) !void {
    var hdr: [28]u8 = @splat(0);
    var key: []const u8 = "";
    var inline_bytes: []const u8 = &.{};
    switch (op) {
        .del => |k| {
            if (k.len > std.math.maxInt(u32)) return error.KeyTooLarge;
            key = k;
            coding.putU32(hdr[0..4], 0b001);
            coding.putU32(hdr[4..8], @intCast(k.len));
        },
        .put => |p| {
            if (p.key.len > std.math.maxInt(u32)) return error.KeyTooLarge;
            if (p.value.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            key = p.key;
            coding.putU32(hdr[4..8], @intCast(p.key.len));
            coding.putU32(hdr[8..12], @intCast(p.value.len));
            const checksum = crc.crc32(p.value);
            checksum_out.* = checksum;
            coding.putU32(hdr[24..28], checksum);
            if (p.value.len < db.options.value_threshold) {
                coding.putU32(hdr[0..4], 0b010);
                inline_bytes = p.value;
            } else {
                if (!grouped) ptr_out.* = try file_ids.appendVlogLocked(db, seq, 0, p.key, p.value, checksum);
                // Rotation only advances file ids under the write mutex.
                // Keep this cache batch-local: later WALs must register again.
                if (registered_vlog.* != ptr_out.*.file_id) {
                    try db.vlog.registerReplayable(db.io, ptr_out.*.file_id, db.wal_id);
                    registered_vlog.* = ptr_out.*.file_id;
                }
                coding.putU64(hdr[12..20], ptr_out.*.file_id);
                coding.putU32(hdr[20..24], @intCast(ptr_out.*.offset));
            }
        },
    }
    try batch.ensureUnusedCapacity(db.internal_allocator, hdr.len + key.len + inline_bytes.len);
    batch.appendSliceAssumeCapacity(&hdr);
    batch.appendSliceAssumeCapacity(key);
    batch.appendSliceAssumeCapacity(inline_bytes);
}

inline fn publishOneLocked(db: *Db, op: Op, seq: u64, ptr: vw.Pointer, checksum: u32) !void {
    const mt = &db.memtables.current.data;
    switch (op) {
        .del => |k| try mt.delete(seq, k),
        .put => |p| {
            const is_inline = p.value.len < db.options.value_threshold;
            var header_buf: [ivfmt.expiry_header_len]u8 = undefined;
            const header = (ivfmt.Header{
                .flags = if (is_inline) ivfmt.inline_value else 0,
                .value_len = @intCast(p.value.len),
                .file_id = if (is_inline) 0 else ptr.file_id,
                .offset = if (is_inline) 0 else ptr.offset,
                .value_crc = checksum,
            }).encode(&header_buf) catch unreachable;
            try mt.putParts(seq, p.key, header, if (is_inline) p.value else &.{});
        },
    }
}

inline fn appendWalLocked(db: *Db, batch: *const std.ArrayListUnmanaged(u8)) !void {
    var pos: usize = 0;
    while (pos < batch.items.len) {
        const end = @min(pos + wf.max_payload_len, batch.items.len);
        const kind: wf.FrameType = if (pos == 0 and end == batch.items.len)
            .full
        else if (pos == 0)
            .first
        else if (end == batch.items.len)
            .last
        else
            .middle;
        try db.wal.append(db.io, kind, batch.items[pos..end]);
        pos = end;
    }
}

inline fn commitWriteLocked(db: *Db, last: u64) !void {
    if (db.options.durability == .sync) try db.syncThrough(last);
    db.last_seq.store(last, .release);
    db.write_cond.broadcast(db.io);
    if (db.memtables.current.data.approx_bytes.load(.monotonic) > db.options.write_buffer_size) {
        try db.prepareFlushLocked(last);
        try db.freezeCurrent(last);
    }
}

inline fn writeSingleOpLocked(db: *Db, op: Op) !void {
    if (db.next_seq.load(.monotonic) > std.math.maxInt(u64) - 1) return error.BatchTooLarge;
    const first = db.next_seq.fetchAdd(1, .monotonic);
    var wal_started = false;
    errdefer if (wal_started) {
        db.background_error = error.WriteFailed;
        db.write_cond.broadcast(db.io);
    };

    const batch = &db.wal_scratch;
    batch.clearRetainingCapacity();
    defer if (batch.capacity > 1024 * 1024) {
        batch.deinit(db.internal_allocator);
        batch.* = .empty;
    };
    try batch.appendNTimes(db.internal_allocator, 0, 12);
    std.mem.writeInt(u64, batch.items[0..8], first, .little);
    std.mem.writeInt(u32, batch.items[8..12], 1, .little);

    var ptr: vw.Pointer = undefined;
    var checksum: u32 = 0;
    var registered_vlog: ?u64 = null;
    try encodeOneLocked(db, batch, op, first, &ptr, &checksum, false, &registered_vlog);
    if (batch.items.len > replay.replay_buf_len) return error.BatchTooLarge;
    wal_started = true;
    try appendWalLocked(db, batch);
    try publishOneLocked(db, op, first, ptr, checksum);
    try commitWriteLocked(db, first);
}

/// Append large values to the VLog, record the batch in the WAL, then publish
/// its MemTable entries. Sync durability waits for persistence before returning;
/// interval and async modes may acknowledge before a later sync.
pub fn writeBatch(db: *Db, ops: []const Op) !void {
    try beginWriteLocked(db);
    defer db.write_mutex.unlock(db.io);
    if (ops.len == 0) return;
    if (ops.len > std.math.maxInt(u32)) return error.BatchTooLarge;
    if (ops.len == 1) return writeSingleOpLocked(db, ops[0]);
    var wal_started = false;
    errdefer if (wal_started) {
        db.background_error = error.WriteFailed;
        db.write_cond.broadcast(db.io);
    };
    if (db.next_seq.load(.monotonic) > std.math.maxInt(u64) - ops.len) return error.BatchTooLarge;
    const first = db.next_seq.fetchAdd(ops.len, .monotonic);
    const my_last = first + ops.len - 1;
    // Collection updates and other small batches need no pointer allocation.
    // Larger batches retain the heap fallback to bound stack usage.
    var pointer_stack: [64]vw.Pointer = undefined;
    const ptrs = if (ops.len <= pointer_stack.len) pointer_stack[0..ops.len] else try db.internal_allocator.alloc(vw.Pointer, ops.len);
    defer if (ops.len > pointer_stack.len) db.internal_allocator.free(ptrs);
    // Reuse each value checksum across WAL encoding and the MemTable mirror.
    var crc_stack: [64]u32 = undefined;
    const checksums = if (ops.len <= crc_stack.len) crc_stack[0..ops.len] else try db.internal_allocator.alloc(u32, ops.len);
    defer if (ops.len > crc_stack.len) db.internal_allocator.free(checksums);
    // Group only external puts that fit without rotating the VLog.
    var records: [256]vw.Writer.Record = undefined;
    var grouped = true;
    if (grouped) {
        const format = @import("vlog/format.zig");
        var total: u64 = 0;
        for (ops) |op| switch (op) {
            .put => |p| {
                if (p.value.len < db.options.value_threshold or p.key.len > std.math.maxInt(u32) or p.value.len > std.math.maxInt(u32)) {
                    grouped = false;
                    break;
                }
                const size = format.entryTotal(@intCast(p.key.len), @intCast(p.value.len));
                if (size > 65536 or total > std.math.maxInt(u32) - size) {
                    grouped = false;
                    break;
                }
                total += size;
            },
            .del => {
                grouped = false;
                break;
            },
        };
        // Preflight the entire batch to avoid partial grouping across rotation.
        const writer = &db.vlog.writer;
        grouped = grouped and writer.size <= writer.threshold and total <= writer.threshold - writer.size;
        if (grouped) {
            var start: usize = 0;
            while (start < ops.len) {
                var end = start;
                var bytes: usize = 0;
                while (end < ops.len and end - start < records.len) : (end += 1) {
                    const p = ops[end].put;
                    const size = format.entryTotal(@intCast(p.key.len), @intCast(p.value.len));
                    if (size > 65536 - bytes) break;
                    records[end - start] = .{ .seq = first + end, .key = p.key, .value = p.value };
                    bytes += size;
                }
                const accepted = try writer.appendGroup(db.io, records[0 .. end - start], ptrs[start..end]);
                std.debug.assert(accepted);
                start = end;
            }
        }
    }

    // The write mutex makes scratch reuse safe and avoids per-put allocations.
    // Release outlier batches so one large request cannot retain excess memory.
    const batch = &db.wal_scratch;
    batch.clearRetainingCapacity();
    defer if (batch.capacity > 1024 * 1024) {
        batch.deinit(db.internal_allocator);
        batch.* = .empty;
    };
    try batch.appendNTimes(db.internal_allocator, 0, 12); // first_seq + count
    std.mem.writeInt(u64, batch.items[0..8], first, .little);
    std.mem.writeInt(u32, batch.items[8..12], @intCast(ops.len), .little);
    var registered_vlog: ?u64 = null;
    for (ops, 0..) |op, i| {
        try encodeOneLocked(db, batch, op, first + i, &ptrs[i], &checksums[i], grouped, &registered_vlog);
    }
    // Failed VLog appends leave orphaned bytes but no MemTable entries.
    if (batch.items.len > replay.replay_buf_len) return error.BatchTooLarge;
    wal_started = true;
    try appendWalLocked(db, batch);
    for (ops, 0..) |op, i| {
        try publishOneLocked(db, op, first + i, ptrs[i], checksums[i]);
    }
    try commitWriteLocked(db, my_last);
}

pub fn put(db: *Db, key: []const u8, value: []const u8) !void {
    try beginWriteLocked(db);
    defer db.write_mutex.unlock(db.io);
    return writeSingleOpLocked(db, .{ .put = .{ .key = key, .value = value } });
}

pub fn delete(db: *Db, key: []const u8) !void {
    const ops = [_]Op{.{ .del = key }};
    try writeBatch(db, &ops);
}

test "small batches: inline external and mixed writes survive stack and heap boundaries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Mode = enum { inline_values, external_values, mixed };
    for ([_]Mode{ .inline_values, .external_values, .mixed }) |mode| {
        for ([_]usize{ 2, 64, 65 }) |count| {
            var tmp = std.testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            var keys: [65][2]u8 = undefined;
            var ops: [65]Op = undefined;
            const large: [600]u8 = @splat('v');
            for (ops[0..count], 0..) |*op, i| {
                keys[i] = .{ 0, @intCast(i) };
                op.* = if (mode == .mixed and i % 3 == 0)
                    .{ .del = &keys[i] }
                else
                    .{ .put = .{ .key = &keys[i], .value = if (mode == .external_values or (mode == .mixed and i % 3 == 1)) &large else "inline" } };
            }
            {
                var db = try Db.open(allocator, io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
                defer db.deinit();
                try writeBatch(&db, ops[0..count]);
                try expectBatch(&db, ops[0..count]);
                try db.flush();
            }
            var reopened = try Db.open(allocator, io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
            defer reopened.deinit();
            try expectBatch(&reopened, ops[0..count]);
        }
    }
}

fn expectBatch(db: *Db, ops: []const Op) !void {
    for (ops) |op| {
        const key = switch (op) {
            .put => |p| p.key,
            .del => |k| k,
        };
        const value = try db.get(key);
        defer if (value) |bytes| db.allocator.free(bytes);
        switch (op) {
            .put => |p| try std.testing.expectEqualSlices(u8, p.value, value orelse return error.TestUnexpectedResult),
            .del => try std.testing.expect(value == null),
        }
    }
}

test "small batches: warm inline writes avoid scratch allocation and failed heap fallback stays retryable" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer db.deinit();
    var ops: [65]Op = @splat(.{ .put = .{ .key = "same", .value = "warm" } });
    try writeBatch(&db, ops[0..64]);
    db.worker.waitIdle();
    const saved_allocator = db.internal_allocator;
    var failing = std.testing.FailingAllocator.init(saved_allocator, .{ .fail_index = 0 });
    {
        // The MemTable arena already has room; only batch scratch uses this
        // allocator, so this catches a regression to per-batch pointer storage.
        db.internal_allocator = failing.allocator();
        defer db.internal_allocator = saved_allocator;
        try writeBatch(&db, ops[0..64]);
        ops[64] = .{ .put = .{ .key = "not-published", .value = "new" } };
        const before = db.last_seq.load(.acquire);
        try std.testing.expectError(error.OutOfMemory, writeBatch(&db, &ops));
        try std.testing.expectEqual(before, db.last_seq.load(.acquire));
    }
    const unpublished = try db.get("not-published");
    defer if (unpublished) |bytes| db.allocator.free(bytes);
    try std.testing.expect(unpublished == null);
    try writeBatch(&db, &ops);
    try expectBatch(&db, ops[64..]);
}

test "batch replayable refs: grouped writes register again after WAL advance and purge" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer db.deinit();
    const value: [600]u8 = @splat('x');
    const grouped = [_]Op{
        .{ .put = .{ .key = "a", .value = &value } },
        .{ .put = .{ .key = "b", .value = &value } },
    };
    try writeBatch(&db, &grouped);
    const vlog_id = db.vlog.writer.file_id;
    const old_wal = db.wal_id;
    try std.testing.expect(db.vlog.replayableProtected(db.io, vlog_id, old_wal));
    try db.flush();
    db.worker.waitIdle();
    try std.testing.expect(db.wal_id > old_wal);
    _ = db.vlog.purgeReplayable(db.io, db.wal_id);
    try std.testing.expect(!db.vlog.replayableProtected(db.io, vlog_id, db.wal_id));
    const mixed = [_]Op{
        .{ .put = .{ .key = "c", .value = &value } },
        .{ .put = .{ .key = "small", .value = "inline" } },
        .{ .del = "a" },
        .{ .put = .{ .key = "d", .value = &value } },
    };
    try writeBatch(&db, &mixed);
    try std.testing.expectEqual(vlog_id, db.vlog.writer.file_id);
    try std.testing.expect(db.vlog.replayableProtected(db.io, vlog_id, db.wal_id));
    try expectBatch(&db, &mixed);
}

test "batch replayable refs: every rotated file stays protected" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{
        .durability = .async,
        .automatic_gc = false,
        .vlog_file_size = @import("vlog/manager.zig").min_file_size,
    });
    defer db.deinit();
    const value = try std.testing.allocator.alloc(u8, @intCast(db.options.vlog_file_size));
    defer std.testing.allocator.free(value);
    @memset(value, 'r');
    const first_vlog = db.vlog.writer.file_id;
    const ops = [_]Op{
        .{ .put = .{ .key = "first", .value = value } },
        .{ .put = .{ .key = "second", .value = value } },
        .{ .put = .{ .key = "third", .value = value } },
    };
    try writeBatch(&db, &ops);
    try std.testing.expect(db.vlog.writer.file_id > first_vlog);
    try std.testing.expectEqual(@as(u32, 3), db.vlog.replayable.count());
    var it = db.vlog.replayable.iterator();
    while (it.next()) |entry| try std.testing.expectEqual(db.wal_id, entry.value_ptr.*);
    try expectBatch(&db, &ops);
}

test "batch replayable refs: registration OOM leaves WAL and MemTable retryable" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer db.deinit();
    try db.put("warm", "inline");
    db.worker.waitIdle();
    const before_seq = db.last_seq.load(.acquire);
    const before_wal = db.wal.end;
    const value: [600]u8 = @splat('f');
    const ops = [_]Op{
        .{ .put = .{ .key = "first", .value = &value } },
        .{ .put = .{ .key = "second", .value = &value } },
    };
    const saved_allocator = db.vlog.replayable.allocator;
    var failing = std.testing.FailingAllocator.init(saved_allocator, .{ .fail_index = 0 });
    {
        db.vlog.replayable.allocator = failing.allocator();
        defer db.vlog.replayable.allocator = saved_allocator;
        try std.testing.expectError(error.OutOfMemory, writeBatch(&db, &ops));
    }
    try std.testing.expectEqual(before_seq, db.last_seq.load(.acquire));
    try std.testing.expectEqual(before_wal, db.wal.end);
    try std.testing.expect(db.background_error == null);
    const absent = try db.get("first");
    defer if (absent) |bytes| db.allocator.free(bytes);
    try std.testing.expect(absent == null);
    try writeBatch(&db, &ops);
    try expectBatch(&db, &ops);
    try std.testing.expect(db.vlog.replayableProtected(db.io, db.vlog.writer.file_id, db.wal_id));
}

test "write mirror: inline boundaries own bytes and external values keep only pointers" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer db.deinit();
    var value: [512]u8 = @splat('v');
    const ops = [_]Op{
        .{ .put = .{ .key = "empty", .value = "" } },
        .{ .put = .{ .key = "inline", .value = value[0..511] } },
        .{ .put = .{ .key = "external", .value = &value } },
    };
    try writeBatch(&db, &ops);
    const seq = db.last_seq.load(.acquire);
    for (ops, 0..) |op, i| {
        const iv = db.memtables.current.data.get(op.put.key, seq) orelse return error.TestUnexpectedResult;
        const view = try ivfmt.View.decode(iv);
        const is_inline = i < 2;
        try std.testing.expectEqual(is_inline, view.header.isInline());
        try std.testing.expectEqual(ivfmt.header_len + @as(usize, if (is_inline) op.put.value.len else 0), iv.len);
        try std.testing.expectEqual(@as(u32, @intCast(op.put.value.len)), view.header.value_len);
    }
    @memset(&value, 'x');
    const expected: [512]u8 = @splat('v');
    const empty = (try db.get("empty")) orelse return error.TestUnexpectedResult;
    defer db.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    for ([_][]const u8{ "inline", "external" }, [_]usize{ 511, 512 }) |key, len| {
        const actual = (try db.get(key)) orelse return error.TestUnexpectedResult;
        defer db.allocator.free(actual);
        try std.testing.expectEqualSlices(u8, expected[0..len], actual);
    }
}

test "external writes: supplied value CRC matches the combined VLog entry after reopen" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const value = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(value);
    for (value, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% (i >> 8) +% 17);

    {
        var db = try Db.open(allocator, io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
        defer db.deinit();
        try db.put("combined-crc", value);
        const from_memtable = (try db.get("combined-crc")) orelse return error.TestUnexpectedResult;
        defer allocator.free(from_memtable);
        try std.testing.expectEqualSlices(u8, value, from_memtable);
        try db.flush();
        const from_sst = (try db.get("combined-crc")) orelse return error.TestUnexpectedResult;
        defer allocator.free(from_sst);
        try std.testing.expectEqualSlices(u8, value, from_sst);
        try db.close();
    }

    var reopened = try Db.open(allocator, io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer reopened.deinit();
    const after_reopen = (try reopened.get("combined-crc")) orelse return error.TestUnexpectedResult;
    defer allocator.free(after_reopen);
    try std.testing.expectEqualSlices(u8, value, after_reopen);
}
