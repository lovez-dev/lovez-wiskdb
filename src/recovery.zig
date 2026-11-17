//! Recovery orchestration after the manifest is rebuilt: scan WALs at or
//! above log_number, replay batches into a MemTable (validating VLog
//! pointers past the durability watermark), flush when anything replayed,
//! append a manifest delta edit, then clean orphan files. A failed
//! flush keeps its WALs and skips cleanup so replayed pointers can never
//! be deleted before their SST lands.

const std = @import("std");
const disk = @import("io/io.zig");
const mf = @import("manifest/format.zig");
const mreader = @import("manifest/reader.zig");
const mdiff = @import("manifest/diff.zig");
const mw = @import("manifest/writer.zig");
const VersionSet = mreader.VersionSet;
const walr = @import("wal/reader.zig");
const MemTable = @import("memtable/memtable.zig").MemTable;
const rp = @import("replay.zig");
const fl = @import("flush.zig");
const vfmt = @import("vlog/format.zig");
const coding = @import("util/coding.zig");
const internal_key = @import("util/internal_key.zig");

pub const Report = struct {
    vs: VersionSet,
    manifest_name: []u8,
    manifest_tail: mw.Tail,
    used_fallback: bool,
    scanned_wals: usize = 0,
    applied_batches: usize = 0,
    flushed: bool = false,
    flush_failed: bool = false,
    flushed_sst: ?u64 = null,
    truncated_wal: ?u64 = null,
    log_number: u64,
    last_seq: u64,
    next_seq: u64,

    /// vlog ids each still-replayable WAL points at, newest WAL per id.
    /// Seeded by replay; the runtime janitor purges rows whose WAL has
    /// been consumed.
    replayable: std.AutoHashMapUnmanaged(u64, u64),
    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_name);
        self.vs.deinit();
        self.replayable.deinit(allocator);
    }
};

/// `db_dir` must have been opened with `iterate = true` for file-id scans.
pub fn recover(allocator: std.mem.Allocator, io: std.Io, db_dir: disk.Dir) !Report {
    const mrec = try mreader.recover(allocator, io, db_dir);
    // Ownership moves out field by field; mrec's own deinit never runs.
    var vs = mrec.vs;
    const used_fallback = mrec.used_fallback;
    // Ownership moves into the report; append reuses the CURRENT manifest.
    const manifest_name = mrec.manifest_name;
    var manifest_tail = mrec.tail;
    errdefer allocator.free(manifest_name);
    errdefer vs.deinit();
    var committed = try vs.cloneState();
    defer committed.deinit();

    const wal_dir = try db_dir.openDir(io, "WAL", .{ .iterate = true });
    defer wal_dir.close(io);
    const sst_dir = try db_dir.openDir(io, "SST", .{ .iterate = true });
    defer sst_dir.close(io);
    const vlog_dir = try db_dir.openDir(io, "VLOG", .{ .iterate = true });
    defer vlog_dir.close(io);

    // A crash may leave outputs newer than the last committed manifest.
    // Reserve above every on-disk id before replay creates any new files.
    for ([_]disk.Dir{ db_dir, wal_dir, sst_dir, vlog_dir }, 0..) |dir, index| {
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const id = if (index == 0) blk: {
                if (!std.mem.startsWith(u8, entry.name, mw.file_prefix)) continue;
                break :blk std.fmt.parseInt(u64, entry.name[mw.file_prefix.len..], 10) catch continue;
            } else rp.parseIdName(entry.name, switch (index) {
                1 => ".wal",
                2 => ".sst",
                else => ".vlog",
            }) orelse continue;
            if (id == std.math.maxInt(u64)) return error.ManifestCorrupted;
            vs.next_file_number = @max(vs.next_file_number, id + 1);
        }
    }

    var mt_holder = try MemTable.create(allocator, vs.last_sequence);
    defer mt_holder.release();
    const mt = &mt_holder.data;

    var wal_ids: std.ArrayListUnmanaged(u64) = .empty;
    defer wal_ids.deinit(allocator);
    {
        var it = wal_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const id = rp.parseIdName(entry.name, ".wal") orelse continue;
            if (id >= vs.log_number) try wal_ids.append(allocator, id);
        }
        std.sort.heap(u64, wal_ids.items, {}, struct {
            fn lt(_: void, a: u64, b: u64) bool {
                return a < b;
            }
        }.lt);
    }

    var vlog_files: std.ArrayListUnmanaged(rp.VlogFile) = .empty;
    defer {
        for (vlog_files.items) |vf| vf.file.close(io);
        vlog_files.deinit(allocator);
    }

    // Track VLogs protected by WALs that still need replay.
    var replayable: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    errdefer replayable.deinit(allocator);
    const scratch = try allocator.alloc(u8, rp.replay_buf_len);
    defer allocator.free(scratch);

    var scanned: usize = 0;
    var applied: usize = 0;
    var max_replayed_seq: u64 = 0;
    var truncated_wal: ?u64 = null;

    for (wal_ids.items) |id| {
        var namebuf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&namebuf, "{d:0>6}.wal", .{id}) catch unreachable;
        const f = try wal_dir.openFile(io, name, .{ .mode = .read_write });
        defer f.close(io);
        scanned += 1;
        const size = try f.length(io);

        // Pass 1: the file's durability watermark, so pass 2 knows which
        // batches the fsync ordering already proved durable.
        var pass1 = walr.Replay.init(f, scratch);
        var durable: u64 = 0;
        while (try pass1.next(io)) |item| {
            if (item == .synced) durable = item.synced;
        }

        // Pass 2: apply; a pointer failing validation cuts the file at the
        // start of that batch (never mid-batch).
        var pass2 = walr.Replay.init(f, scratch);
        var stop = false;
        while (!stop) {
            const batch_start = pass2.truncate_at; // start of the item about to yield
            const item = (try pass2.next(io)) orelse break;
            switch (item) {
                .synced => {},
                .batch => |bytes| {
                    if (try rp.applyBatch(allocator, mt, &vlog_files, vlog_dir, io, bytes, durable, &max_replayed_seq, id, &replayable)) {
                        applied += 1;
                    } else {
                        try f.setLength(io, batch_start);
                        truncated_wal = id;
                        stop = true;
                    }
                },
            }
        }
        if (!stop and pass2.truncate_at < size) {
            try f.setLength(io, pass2.truncate_at); // torn tail: keep the effective prefix
            truncated_wal = id;
        }
    }

    // Validated replay bytes may still be in the OS cache after a process
    // crash. Make referenced VLogs durable before publishing SSTs/retiring WALs.
    var vlog_entries = vlog_dir.iterate();
    while (try vlog_entries.next(io)) |entry| {
        if (entry.kind != .file or rp.parseIdName(entry.name, ".vlog") == null) continue;
        const value_file = try vlog_dir.openFile(io, entry.name, .{ .mode = .read_write });
        defer value_file.close(io);
        try disk.fsync(value_file, io);
    }
    _ = try disk.syncDirectory(vlog_dir, io);

    var flushed = false;
    var flush_failed = false;
    var flushed_sst: ?u64 = null;
    if (fl.flushMemtable(allocator, io, sst_dir, mt, &vs)) |maybe_id| {
        if (maybe_id) |sid| {
            flushed = true;
            flushed_sst = sid;
        }
    } else |e| switch (e) {
        error.OutOfMemory => return e,
        else => flush_failed = true, // partial SST already unlinked inside
    }

    vs.last_sequence = @max(vs.last_sequence, max_replayed_seq);
    if (flushed and wal_ids.items.len != 0) vs.log_number = wal_ids.items[wal_ids.items.len - 1] + 1;

    {
        var writer = try mw.Writer.openAppend(allocator, io, db_dir, manifest_name, manifest_tail);
        defer writer.close();
        var edit = try mdiff.deltaEdit(allocator, &committed, &vs);
        defer mdiff.freeEdit(allocator, &edit);
        try writer.appendEdit(&edit);
        manifest_tail = .{ .offset = writer.offset, .prev_crc = writer.prev_crc };
    }
    // Repair the pointer before retiring replay inputs after fallback.
    if (used_fallback) try mw.publishCurrent(io, db_dir, manifest_name);

    if (!flush_failed) {
        for (wal_ids.items) |id| {
            var namebuf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&namebuf, "{d:0>6}.wal", .{id}) catch unreachable;
            disk.unlink(wal_dir, io, name) catch {}; // replayed content now lives in the SST
        }
        try fl.cleanOrphans(allocator, io, sst_dir, vlog_dir, &vs);
    }

    return .{
        .vs = vs,
        .manifest_name = manifest_name,
        .manifest_tail = manifest_tail,
        .used_fallback = used_fallback,
        .scanned_wals = scanned,
        .applied_batches = applied,
        .flushed = flushed,
        .flush_failed = flush_failed,
        .flushed_sst = flushed_sst,
        .truncated_wal = truncated_wal,
        .log_number = vs.log_number,
        .last_seq = vs.last_sequence,
        .next_seq = vs.last_sequence + 1,
        .replayable = replayable,
    };
}

fn setupRecoveryDirs(io: std.Io, dir: disk.Dir) !void {
    try dir.createDirPath(io, "WAL");
    try dir.createDirPath(io, "SST");
    try dir.createDirPath(io, "VLOG");
}

fn initialManifest(allocator: std.mem.Allocator, io: std.Io, dir: disk.Dir, log_number: u64, next_file_number: u64) !void {
    var w = try mw.Writer.create(allocator, io, dir, 7);
    defer w.close();
    const ed = mf.Edit{
        .comparator = mf.comparator_name,
        .format_version = mf.current_version,
        .log_number = log_number,
        .next_file_number = next_file_number,
        .last_sequence = 0,
    };
    try w.appendEdit(&ed);
    var buf: [64]u8 = undefined;
    try mw.publishCurrent(io, dir, mw.fileName(7, &buf));
}

test "recovery: fallback repairs CURRENT before future appends" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try setupRecoveryDirs(io, tmp.dir);
    try initialManifest(allocator, io, tmp.dir, 1, 8);
    const current = try tmp.dir.createFile(io, "CURRENT", .{ .truncate = true });
    try disk.pwriteAll(current, io, "invalid\n", 0);
    current.close(io);
    {
        var report = try recover(allocator, io, tmp.dir);
        defer report.deinit(allocator);
        try std.testing.expect(report.used_fallback);
        try std.testing.expectEqualStrings("MANIFEST-000007", report.manifest_name);
    }
    var again = try recover(allocator, io, tmp.dir);
    defer again.deinit(allocator);
    try std.testing.expect(!again.used_fallback);
    try std.testing.expectEqualStrings("MANIFEST-000007", again.manifest_name);
}

fn inlineBatch(allocator: std.mem.Allocator, first_seq: u64, keys: []const []const u8, vals: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var head: [12]u8 = undefined;
    coding.putU64(head[0..8], first_seq);
    coding.putU32(head[8..12], @intCast(keys.len));
    try out.appendSlice(allocator, &head);
    for (keys, vals) |k, v| {
        var rec: [28]u8 = @splat(0);
        rec[0] = 0b010; // INLINE
        coding.putU32(rec[4..8], @intCast(k.len));
        coding.putU32(rec[8..12], @intCast(v.len));
        coding.putU32(rec[24..28], vfmt.entryCrc(k, v));
        try out.appendSlice(allocator, &rec);
        try out.appendSlice(allocator, k);
        try out.appendSlice(allocator, v);
    }
    return out.toOwnedSlice(allocator);
}

/// A batch of one non-inline put: the value lives in the vlog, so the
/// WAL record is a bare pointer — enough to exercise registration
/// without a real vlog file when the record sits at or below the
/// durability watermark.
fn vlogBatch(allocator: std.mem.Allocator, first_seq: u64, key: []const u8, vlog_id: u64) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var head: [12]u8 = undefined;
    coding.putU64(head[0..8], first_seq);
    coding.putU32(head[8..12], 1);
    try out.appendSlice(allocator, &head);
    var rec: [28]u8 = @splat(0); // flags 0: non-inline, no expire
    coding.putU32(rec[4..8], @intCast(key.len));
    coding.putU32(rec[8..12], 4); // logical value length
    coding.putU64(rec[12..20], vlog_id);
    coding.putU32(rec[20..24], 0); // vlog_off
    try out.appendSlice(allocator, &rec);
    try out.appendSlice(allocator, key);
    return out.toOwnedSlice(allocator);
}

test "recovery: a failed flush skips orphan cleanup and keeps its WALs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try setupRecoveryDirs(io, tmp.dir);
    try initialManifest(allocator, io, tmp.dir, 1, 2);

    {
        var w = try @import("wal/writer.zig").Wal.create(tmp.dir, io, "WAL/000001.wal");
        defer w.close(io);
        const batch = try inlineBatch(allocator, 1, &.{"alpha"}, &.{"one"});
        defer allocator.free(batch);
        try w.append(io, .full, batch);
        try w.appendSynced(io, 1);
    }
    const orphan = try tmp.dir.createFile(io, "VLOG/000099.vlog", .{});
    try disk.pwriteAll(orphan, io, "junk", 0);
    orphan.close(io);
    // a directory squatting on the next SST number fails the flush naturally
    try tmp.dir.createDirPath(io, "SST/000100.sst");

    var rep = try recover(allocator, io, tmp.dir);
    defer rep.deinit(allocator);

    try std.testing.expect(rep.flush_failed);
    try std.testing.expect(!rep.flushed);
    try std.testing.expectEqual(@as(u64, 1), rep.log_number); // no flush, no advance
    try std.testing.expectEqual(@as(usize, 1), rep.applied_batches);
    // cleanup never ran: the orphan and the replayed WAL both survive
    const o = try tmp.dir.openFile(io, "VLOG/000099.vlog", .{ .mode = .read_only });
    o.close(io);
    const wl = try tmp.dir.openFile(io, "WAL/000001.wal", .{ .mode = .read_only });
    wl.close(io);
}

test "recovery: log_number stays put while any replayed generation stays unflushed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try setupRecoveryDirs(io, tmp.dir);
    try initialManifest(allocator, io, tmp.dir, 1, 3);

    {
        var w = try @import("wal/writer.zig").Wal.create(tmp.dir, io, "WAL/000001.wal");
        defer w.close(io);
        const b = try inlineBatch(allocator, 1, &.{ "alpha", "beta" }, &.{ "one", "two" });
        defer allocator.free(b);
        try w.append(io, .full, b);
        try w.appendSynced(io, 2);
    }
    {
        var w = try @import("wal/writer.zig").Wal.create(tmp.dir, io, "WAL/000002.wal");
        defer w.close(io);
        const b = try inlineBatch(allocator, 3, &.{"gamma"}, &.{"three"});
        defer allocator.free(b);
        try w.append(io, .full, b); // no SYNCED frame: everything here sits past the watermark
    }
    try tmp.dir.createDirPath(io, "SST/000008.sst");

    var rep = try recover(allocator, io, tmp.dir);
    defer rep.deinit(allocator);

    try std.testing.expect(rep.flush_failed);
    try std.testing.expectEqual(@as(u64, 1), rep.log_number); // untouched: generations still needed
    try std.testing.expectEqual(@as(usize, 2), rep.scanned_wals);
    try std.testing.expectEqual(@as(usize, 2), rep.applied_batches);
    for ([_][]const u8{ "WAL/000001.wal", "WAL/000002.wal" }) |n| {
        const f = try tmp.dir.openFile(io, n, .{ .mode = .read_only });
        f.close(io);
    }
}

test "recovery: a successful flush advances log_number, retires WALs, cleans orphans" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try setupRecoveryDirs(io, tmp.dir);
    try initialManifest(allocator, io, tmp.dir, 1, 2);

    {
        var w = try @import("wal/writer.zig").Wal.create(tmp.dir, io, "WAL/000001.wal");
        defer w.close(io);
        const b = try inlineBatch(allocator, 1, &.{ "alpha", "beta" }, &.{ "one", "two" });
        defer allocator.free(b);
        try w.append(io, .full, b);
        try w.appendSynced(io, 2);
    }
    const orphan = try tmp.dir.createFile(io, "VLOG/000099.vlog", .{});
    try disk.pwriteAll(orphan, io, "junk", 0);
    orphan.close(io);

    var rep = try recover(allocator, io, tmp.dir);
    defer rep.deinit(allocator);

    try std.testing.expect(rep.flushed);
    try std.testing.expect(!rep.flush_failed);
    try std.testing.expectEqual(@as(u64, 100), rep.flushed_sst.?);
    try std.testing.expectEqual(@as(u64, 2), rep.log_number); // max replayed WAL id + 1
    try std.testing.expectEqual(@as(u64, 2), rep.last_seq);
    try std.testing.expectEqual(@as(usize, 1), rep.applied_batches);
    // WAL retired, orphan gone, SST present — cleanup landed after the flush
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "WAL/000001.wal", .{ .mode = .read_only }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "VLOG/000099.vlog", .{ .mode = .read_only }));
    const sf = try tmp.dir.openFile(io, "SST/000100.sst", .{ .mode = .read_only });
    sf.close(io);
    // the flushed data is really in the table
    var tr = try @import("sstable/table_reader.zig").TableReader.open(allocator, io, tmp.dir, "SST/000100.sst");
    defer tr.deinit();
    var tbuf: [64]u8 = undefined;
    const tn = try internal_key.encode("alpha", 2, .put, &tbuf);
    const got = (try tr.get(tbuf[0..tn])).?;
    defer allocator.free(got);
    try std.testing.expect(got[0] & 0b010 != 0); // stored as INLINE
    try std.testing.expectEqualStrings("one", got[21..]);
    // second pass finds nothing left to do
    var rep2 = try recover(allocator, io, tmp.dir);
    defer rep2.deinit(allocator);
    try std.testing.expect(!rep2.flushed);
    try std.testing.expectEqual(@as(usize, 0), rep2.scanned_wals);
    try std.testing.expectEqual(@as(usize, 0), rep2.applied_batches);
    try std.testing.expectEqual(@as(u64, 2), rep2.log_number);
}

test "recovery: an unverifiable pointer discards its whole batch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try setupRecoveryDirs(io, tmp.dir);
    try initialManifest(allocator, io, tmp.dir, 1, 2);

    {
        var w = try @import("wal/writer.zig").Wal.create(tmp.dir, io, "WAL/000001.wal");
        defer w.close(io);
        var b: std.ArrayListUnmanaged(u8) = .empty;
        defer b.deinit(allocator);
        var head: [12]u8 = undefined;
        coding.putU64(head[0..8], 1); // first_seq
        coding.putU32(head[8..12], 2);
        try b.appendSlice(allocator, &head);
        // record 1: a perfectly valid inline put
        var rec1: [28]u8 = @splat(0);
        rec1[0] = 0b010;
        coding.putU32(rec1[4..8], 5); // "alpha"
        coding.putU32(rec1[8..12], 3); // "one"
        coding.putU32(rec1[24..28], vfmt.entryCrc("alpha", "one"));
        try b.appendSlice(allocator, &rec1);
        try b.appendSlice(allocator, "alpha");
        try b.appendSlice(allocator, "one");
        // record 2: a pointer at seq 2 whose VLog file does not exist
        var rec2: [28]u8 = @splat(0);
        coding.putU32(rec2[4..8], 4); // "beta"
        coding.putU32(rec2[8..12], 8); // logical value length
        coding.putU64(rec2[12..20], 5); // vlog id 5: never written
        coding.putU32(rec2[20..24], 32); // entry start offset
        try b.appendSlice(allocator, &rec2);
        try b.appendSlice(allocator, "beta");
        try w.append(io, .full, b.items);
    }

    var rep = try recover(allocator, io, tmp.dir);
    defer rep.deinit(allocator);

    // the batch is all-or-nothing: record 1 must not survive alone
    try std.testing.expectEqual(@as(usize, 0), rep.applied_batches);
    try std.testing.expectEqual(@as(u64, 0), rep.last_seq);
    try std.testing.expect(!rep.flushed);
    try std.testing.expectEqual(@as(?u64, 1), rep.truncated_wal);
    try std.testing.expectEqual(@as(u64, 1), rep.log_number);
}

test "recovery: replayed WALs seed the deletion gate's replayable set" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try setupRecoveryDirs(io, tmp.dir);
    try initialManifest(allocator, io, tmp.dir, 1, 3);

    {
        var w = try @import("wal/writer.zig").Wal.create(tmp.dir, io, "WAL/000001.wal");
        defer w.close(io);
        const b = try vlogBatch(allocator, 1, "k1", 7);
        defer allocator.free(b);
        try w.append(io, .full, b);
        const ib = try inlineBatch(allocator, 2, &.{"alpha"}, &.{"one"});
        defer allocator.free(ib);
        try w.append(io, .full, ib);
        try w.appendSynced(io, 3); // everything at or below 3: no pointer validation
    }
    {
        var w = try @import("wal/writer.zig").Wal.create(tmp.dir, io, "WAL/000002.wal");
        defer w.close(io);
        const b = try vlogBatch(allocator, 4, "k2", 7); // same vlog, newer WAL
        defer allocator.free(b);
        try w.append(io, .full, b);
        try w.appendSynced(io, 4);
    }

    var rep = try recover(allocator, io, tmp.dir);
    defer rep.deinit(allocator);

    // newest WAL wins, and the inline put registered nothing
    try std.testing.expectEqual(@as(?u64, 2), rep.replayable.get(7));
    try std.testing.expectEqual(@as(usize, 1), rep.replayable.count());
    try std.testing.expect(rep.flushed);
}
