//! MemTable-to-SST flush and orphan cleanup. Recovery must publish the
//! flushed pointers before removing their replay inputs.

const std = @import("std");
const disk = @import("io/io.zig");
const mf = @import("manifest/format.zig");
const mreader = @import("manifest/reader.zig");
const VersionSet = mreader.VersionSet;
const tbuild = @import("sstable/table_builder.zig");
const MemTable = @import("memtable/memtable.zig").MemTable;
const ivfmt = @import("util/internal_value.zig");
const vids = @import("util/vlog_ids.zig");
const internal_key = @import("util/internal_key.zig");
const parseIdName = @import("replay.zig").parseIdName;

fn vsHasFile(vs: *const VersionSet, file_id: u64) bool {
    var it = vs.by_level.iterator();
    while (it.next()) |lvl| {
        for (lvl.value_ptr.items) |f| {
            if (f.file_id == file_id) return true;
        }
    }
    return false;
}

fn vlogAnyReference(vs: *const VersionSet, id: u64) vids.Ref {
    var it = vs.by_level.iterator();
    while (it.next()) |lvl| {
        for (lvl.value_ptr.items) |f| {
            const r = vids.reference(f.vlog_ids, id);
            if (r != .absent) return r;
        }
    }
    return .absent;
}

pub fn cleanOrphans(allocator: std.mem.Allocator, io: std.Io, sst_dir: disk.Dir, vlog_dir: disk.Dir, vs: *const VersionSet) !void {
    var stale: std.ArrayListUnmanaged(u64) = .empty;
    defer stale.deinit(allocator);

    var sit = sst_dir.iterate();
    while (try sit.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const id = parseIdName(entry.name, ".sst") orelse continue;
        if (!vsHasFile(vs, id)) try stale.append(allocator, id);
    }
    for (stale.items) |id| {
        var namebuf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&namebuf, "{d:0>6}.sst", .{id}) catch unreachable;
        disk.unlink(sst_dir, io, name) catch {};
    }

    stale.clearRetainingCapacity();
    var vit = vlog_dir.iterate();
    while (try vit.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const id = parseIdName(entry.name, ".vlog") orelse continue;
        if (vlogAnyReference(vs, id) == .absent) try stale.append(allocator, id);
    }
    for (stale.items) |id| {
        var namebuf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&namebuf, "{d:0>6}.vlog", .{id}) catch unreachable;
        disk.unlink(vlog_dir, io, name) catch {};
    }
}

pub fn flushMemtable(allocator: std.mem.Allocator, io: std.Io, sst_dir: disk.Dir, mt: *MemTable, vs: *VersionSet) !?u64 {
    const tables = [_]*MemTable{mt};
    return flushMemtables(allocator, io, sst_dir, &tables, vs);
}

const FlushCursor = struct {
    it: MemTable.Iterator,
    key: []const u8,
};

fn siftDown(heap: []FlushCursor, start: usize) void {
    const cursor = heap[start];
    var parent = start;
    while (parent < heap.len / 2) {
        var child = parent * 2 + 1;
        if (child + 1 < heap.len and internal_key.compare(heap[child + 1].key, heap[child].key) == .lt) child += 1;
        if (internal_key.compare(cursor.key, heap[child].key) != .gt) break;
        heap[parent] = heap[child];
        parent = child;
    }
    heap[parent] = cursor;
}

/// Build one L0 SST from several MemTable generations. Entries keep their
/// encoded sequence suffix, including every old version and tombstone.
/// Callers retain the frozen tables until their borrowed cursors are consumed.
pub fn flushMemtables(allocator: std.mem.Allocator, io: std.Io, sst_dir: disk.Dir, mts: []const *MemTable, vs: *VersionSet) !?u64 {
    if (mts.len == 0) return null;
    var single: [1]FlushCursor = undefined;
    const cursors = if (mts.len == 1) &single else try allocator.alloc(FlushCursor, mts.len);
    defer if (mts.len > 1) allocator.free(cursors);
    var count: usize = 0;
    for (mts) |mt| {
        var it = mt.iterator();
        it.seekToFirst();
        if (it.valid()) {
            cursors[count] = .{ .it = it, .key = it.key() };
            count += 1;
        }
    }
    if (count == 0) return null;
    var heap = cursors[0..count];
    var parent = count / 2;
    while (parent > 0) {
        parent -= 1;
        siftDown(heap, parent);
    }

    var tb = try tbuild.TableBuilder.init(allocator, .{});
    defer tb.deinit();

    var tombstone: [ivfmt.header_len]u8 = undefined;
    while (heap.len != 0) {
        const ik = heap[0].key;
        const view = internal_key.decode(ik) catch unreachable;
        const iv: []const u8 = if (view.kind == .delete) blk: {
            // MemTables store tombstones without a value; SSTs carry a header.
            break :blk ivfmt.encode(.{ .flags = ivfmt.deleted }, "", &tombstone) catch unreachable;
        } else heap[0].it.value();
        _ = ivfmt.View.decode(iv) catch return error.SSTableCorrupted;
        try tb.add(ik, iv);

        heap[0].it.next();
        if (heap[0].it.valid()) {
            heap[0].key = heap[0].it.key();
        } else {
            heap[0] = heap[heap.len - 1];
            heap = heap[0 .. heap.len - 1];
        }
        // Only the root changed; each input iterator advances monotonically.
        if (heap.len > 1) siftDown(heap, 0);
    }

    const img = try tb.finish();

    const sst_id = vs.next_file_number;
    const add = try tb.metadata(0, sst_id);
    defer add.deinit(allocator);
    vs.next_file_number += 1;
    var namebuf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&namebuf, "{d:0>6}.sst", .{sst_id}) catch unreachable;
    const f = try sst_dir.createFile(io, name, .{ .read = true, .truncate = true, .exclusive = true });
    disk.pwriteAll(f, io, img, 0) catch |e| {
        f.close(io);
        disk.unlink(sst_dir, io, name) catch {};
        return e;
    };
    disk.fsync(f, io) catch |e| {
        f.close(io);
        disk.unlink(sst_dir, io, name) catch {};
        return e;
    };
    f.close(io);
    _ = try disk.syncDirectory(sst_dir, io);

    const adds = [_]mf.FileMeta{add};
    var e = mf.Edit{ .adds = &adds };
    try vs.apply(&e); // clones what it stores; e itself owns nothing
    return sst_id;
}

fn testFlushGenerations(table_count: usize, empty_between: bool) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const TableReader = @import("sstable/table_reader.zig").TableReader;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    var holders: [65]*MemTable.Holder = undefined;
    var tables: [65]*MemTable = undefined;
    var created: usize = 0;
    defer for (holders[0..created]) |holder| holder.release();
    var active: usize = 0;
    var last_sequence: u64 = 0;
    for (0..table_count) |i| {
        holders[i] = try MemTable.create(allocator, i + 1);
        created += 1;
        tables[table_count - i - 1] = &holders[i].data;
        if (empty_between and i % 3 == 1) continue;
        active += 1;
        const seq = i * 3 + 1;
        last_sequence = seq + 2;
        const payload = [_]u8{@intCast(i)};
        var value_buf: [ivfmt.header_len + 1]u8 = undefined;
        const value = try ivfmt.encode(.{ .flags = ivfmt.inline_value, .value_len = 1 }, &payload, &value_buf);
        try holders[i].data.put(seq, "k", value);
        try holders[i].data.delete(seq + 1, "k");
        try holders[i].data.put(seq + 2, "k", value);
        try holders[i].data.put(seq, "a", value);
        const pointer = try ivfmt.encode(.{ .file_id = i % 4 + 1, .value_len = 100 }, "", &value_buf);
        try holders[i].data.put(seq + 2, "z", pointer);
    }
    // Input order is deliberately unrelated to sequence or key order.
    if (table_count > 2) std.mem.swap(*MemTable, &tables[0], &tables[table_count / 2]);
    const id = try flushMemtables(allocator, io, tmp.dir, tables[0..table_count], &vs);
    for (holders[0..created]) |holder| holder.release();
    created = 0;
    if (active == 0) {
        try std.testing.expect(id == null);
        try std.testing.expectEqual(@as(u64, 1), vs.next_file_number);
        try std.testing.expectEqual(@as(usize, 0), vs.fileCount(0));
        var files = tmp.dir.iterate();
        try std.testing.expect((try files.next(io)) == null);
        return;
    }
    try std.testing.expectEqual(@as(?u64, 1), id);
    try std.testing.expectEqual(@as(usize, 1), vs.fileCount(0));
    const meta = vs.by_level.get(0).?.items[0];
    try std.testing.expectEqualStrings("a", meta.smallest);
    try std.testing.expectEqualStrings("z", meta.largest);
    try std.testing.expectEqual(@as(u64, 1), meta.min_seq);
    try std.testing.expectEqual(last_sequence, meta.max_seq);
    for (0..table_count) |i| {
        if (empty_between and i % 3 == 1) continue;
        try std.testing.expectEqual(vids.Ref.referenced, vids.reference(meta.vlog_ids, i % 4 + 1));
    }

    var table = try TableReader.open(allocator, io, tmp.dir, "000001.sst");
    defer table.deinit();
    var it = TableReader.TableIter.init(&table);
    defer it.deinit();
    try it.seekToFirst();
    var entries: usize = 0;
    for ([_][]const u8{ "a", "k", "z" }) |user| {
        var generation = table_count;
        while (generation > 0) {
            generation -= 1;
            if (empty_between and generation % 3 == 1) continue;
            const versions: usize = if (std.mem.eql(u8, user, "k")) 3 else 1;
            for (0..versions) |version| {
                try std.testing.expect(it.valid());
                const view = try internal_key.decode(it.key());
                const seq = generation * 3 + if (user[0] == 'a') @as(usize, 1) else 3 - version;
                const deleted = user[0] == 'k' and version == 1;
                try std.testing.expectEqualStrings(user, view.user);
                try std.testing.expectEqual(@as(u64, seq), view.seq);
                try std.testing.expectEqual(if (deleted) internal_key.Kind.delete else .put, view.kind);
                try std.testing.expectEqual(deleted, (try ivfmt.Header.decode(it.value())).isDeleted());
                entries += 1;
                try it.next();
            }
        }
    }
    try std.testing.expect(!it.valid());
    try std.testing.expectEqual(active * 5, entries);

    for (0..table_count * 3 + 2) |snapshot| {
        var key_buf: [1 + internal_key.suffix_len]u8 = undefined;
        _ = try internal_key.encode("k", snapshot, .put, &key_buf);
        const got = try table.get(&key_buf);
        defer if (got) |value| allocator.free(value);
        var expected = @min(snapshot, table_count * 3);
        while (expected > 0 and empty_between and ((expected - 1) / 3) % 3 == 1) expected -= 1;
        if (expected == 0) {
            try std.testing.expect(got == null);
        } else {
            try std.testing.expect(got != null);
            const value = try ivfmt.View.decode(got.?);
            try std.testing.expectEqual(expected % 3 == 2, value.header.isDeleted());
            if (!value.header.isDeleted()) {
                try std.testing.expectEqualSlices(u8, &.{@intCast((expected - 1) / 3)}, value.inline_bytes);
            }
        }
    }
}

test "flush: ordered streams retain all versions across zero, one, two and many generations" {
    for ([_]usize{ 0, 1, 2, 64, 65 }) |count| {
        try testFlushGenerations(count, false);
        try testFlushGenerations(count, true);
    }
}

test "flush: empty generations create no SST and malformed values are not published" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    const empty = try MemTable.create(allocator, 1);
    defer empty.release();
    try std.testing.expect((try flushMemtable(allocator, io, tmp.dir, &empty.data, &vs)) == null);
    try std.testing.expect((try flushMemtables(allocator, io, tmp.dir, &.{ &empty.data, &empty.data }, &vs)) == null);
    var header: [ivfmt.header_len]u8 = undefined;
    const truncated = try (ivfmt.Header{ .flags = ivfmt.inline_value, .value_len = 1 }).encode(&header);
    for ([_][]const u8{ "bad", truncated }) |bad| {
        const holder = try MemTable.create(allocator, 2);
        defer holder.release();
        try holder.data.put(1, "k", bad);
        try std.testing.expectError(error.SSTableCorrupted, flushMemtables(allocator, io, tmp.dir, &.{ &empty.data, &holder.data, &empty.data }, &vs));
    }
    try std.testing.expectEqual(@as(u64, 1), vs.next_file_number);
    try std.testing.expectEqual(@as(usize, 0), vs.fileCount(0));
    var files = tmp.dir.iterate();
    try std.testing.expect((try files.next(io)) == null);
}
