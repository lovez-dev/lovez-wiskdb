//! VLog garbage accounting and deletion gates. `scan` measures garbage
//! using the caller's `oracle.isLive`; `sweep` only deletes files that
//! no longer have replay, SST, reader or active-writer references.

const std = @import("std");
const disk = @import("../io/io.zig");
const fmt = @import("format.zig");
const coding = @import("../util/coding.zig");
const vids = @import("../util/vlog_ids.zig");
const writer = @import("writer.zig");
const mgr = @import("manager.zig");
const VersionSet = @import("../manifest/reader.zig").VersionSet;

pub const Scan = struct {
    entries: u64 = 0,
    live_bytes: u64 = 0,
    garbage_bytes: u64 = 0,
    /// The walk stopped at a truncated tail — fewer than a header's
    /// bytes left, or a body running past EOF. Normal end of file.
    tail_fragment: bool = false,
    /// Invalid header or payload CRC in a complete entry. A caller must not
    /// treat an incomplete scan as proof that a file can be deleted.
    mid_file_damage: bool = false,
    consumed: u64 = 0,

    pub fn garbageRatio(self: Scan) f64 {
        const denom = self.live_bytes + self.garbage_bytes;
        if (denom == 0) return 0;
        return @as(f64, @floatFromInt(self.garbage_bytes)) / @as(f64, @floatFromInt(denom));
    }
};

/// Sequential walk of one vlog file: header, payload CRC, then the
/// oracle. Expired entries count as garbage without asking — TTL is
/// reclaimed here as well as on the read path, and the rewrite stage
/// must not carry them forward.
pub fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: disk.Dir,
    file_id: u64,
    now: u64,
    oracle: anytype,
) !Scan {
    var namebuf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&namebuf, "{d:0>6}.vlog", .{file_id}) catch unreachable;
    const file = try dir.openFile(io, name, .{ .mode = .read_only });
    defer file.close(io);
    const size = try file.length(io);

    var out: Scan = .{};
    var pos: u64 = 0;
    var scratch: std.ArrayListUnmanaged(u8) = .empty;
    defer scratch.deinit(allocator);

    while (pos < size) {
        if (size - pos < fmt.header_len) {
            out.tail_fragment = true;
            break;
        }
        var hraw: [fmt.header_len]u8 = undefined;
        _ = try disk.preadAll(file, io, &hraw, pos);
        const h = fmt.decodeHeader(&hraw) catch {
            out.mid_file_damage = true;
            break;
        };
        const total = fmt.entryTotal(h.key_len, h.val_len);
        if (pos + total > size) {
            out.tail_fragment = true; // header fine, body past EOF
            break;
        }
        const kv: usize = @as(usize, h.key_len) + @as(usize, h.val_len);
        try scratch.resize(allocator, kv);
        _ = try disk.preadAll(file, io, scratch.items, pos + fmt.header_len);
        var crcbuf: [fmt.crc_len]u8 = undefined;
        _ = try disk.preadAll(file, io, &crcbuf, pos + fmt.header_len + kv);
        const key = scratch.items[0..h.key_len];
        const value = scratch.items[h.key_len..];
        if (coding.getU32(&crcbuf) != fmt.entryCrc(key, value)) {
            out.mid_file_damage = true;
            break;
        }

        out.entries += 1;
        if (h.expire_at != 0 and now >= h.expire_at) {
            out.garbage_bytes += total;
        } else if (oracle.isLive(key, h.seq, h.expire_at)) {
            out.live_bytes += total;
        } else {
            out.garbage_bytes += total;
        }
        out.consumed += total;
        pos += total;
    }
    return out;
}

pub const Keep = enum { replayable, referenced, open_reader, active_writer };

/// The deletion gate in its mandated order: replayable first, then
/// references, then live handles. The order matters — once the WAL
/// generation has been flushed no new reference source can appear, so
/// each earlier pass makes the passes after it stable.
pub fn gate(io: std.Io, m: *mgr.Manager, vs: *const VersionSet, log_number: u64, id: u64) ?Keep {
    if (m.replayableProtected(io, id, log_number)) return .replayable;
    if (referencedByVersion(vs, id)) return .referenced;
    if (m.hasReader(id)) return .open_reader;
    if (id == m.writer.file_id) return .active_writer;
    return null;
}

fn referencedByVersion(vs: *const VersionSet, id: u64) bool {
    var lv = vs.by_level.iterator();
    while (lv.next()) |lvl| {
        for (lvl.value_ptr.items) |f| {
            // An unparsable id list is a doubt, and a doubt keeps the file.
            if (vids.reference(f.vlog_ids, id) != .absent) return true;
        }
    }
    return false;
}

pub const Swept = struct {
    deleted: usize = 0,
    failed: usize = 0,
    kept_replayable: usize = 0,
    kept_referenced: usize = 0,
    kept_open_reader: usize = 0,
    kept_active: usize = 0,
};

/// Deletion stage: unlink what the gate passes. A file still
/// referenced by SSTs is compaction's business — this never rewrites
/// and never scans. Ids are collected before acting so directory
/// iteration is not disturbed by unlink.
pub fn sweep(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: disk.Dir,
    m: *mgr.Manager,
    vs: *const VersionSet,
    log_number: u64,
) !Swept {
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    defer ids.deinit(allocator);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".vlog")) continue;
        const digits = entry.name[0 .. entry.name.len - ".vlog".len];
        const id = std.fmt.parseInt(u64, digits, 10) catch continue;
        try ids.append(allocator, id);
    }

    var out: Swept = .{};
    for (ids.items) |id| {
        if (gate(io, m, vs, log_number, id)) |k| {
            switch (k) {
                .replayable => out.kept_replayable += 1,
                .referenced => out.kept_referenced += 1,
                .open_reader => out.kept_open_reader += 1,
                .active_writer => out.kept_active += 1,
            }
            continue;
        }
        m.retire(id) catch {
            out.failed += 1;
            continue;
        };
        var namebuf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&namebuf, "{d:0>6}.vlog", .{id}) catch unreachable;
        disk.unlink(dir, io, name) catch {
            out.failed += 1;
            continue;
        };
        out.deleted += 1;
    }
    return out;
}

// ========================= tests =========================

const Oracle = struct {
    dead_seq: u64 = 0,
    asks: usize = 0,
    fn isLive(self: *Oracle, key: []const u8, seq: u64, expire_at: u64) bool {
        _ = key;
        _ = expire_at;
        self.asks += 1;
        return seq != self.dead_seq;
    }
};

fn addFile(vs: *VersionSet, lvl: u32, id: u64, size: u64, smallest: []const u8, largest: []const u8, vlog_ids: []const u8) !void {
    const mf = @import("../manifest/format.zig");
    const f = mf.FileMeta{
        .level = lvl,
        .file_id = id,
        .file_size = size,
        .smallest = smallest,
        .largest = largest,
        .min_seq = 1,
        .max_seq = 1,
        .vlog_ids = vlog_ids,
    };
    const adds = [_]mf.FileMeta{f};
    var e = mf.Edit{ .adds = &adds };
    try vs.apply(&e); // clones what it stores; the literal edit owns nothing
}

test "gc: scanner separates live, dead, and expired entries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var w = try writer.Writer.create(tmp.dir, io, 1, mgr.min_file_size);
    defer w.close(io);
    _ = try w.append(io, 1, 0, "a", "111", null);
    _ = try w.append(io, 2, 0, "b", "2222", null);
    _ = try w.append(io, 3, 10, "c", "33333", null); // expired at now = 10

    var oracle = Oracle{ .dead_seq = 2 };
    const s = try scan(std.testing.allocator, io, tmp.dir, 1, 10, &oracle);
    try std.testing.expectEqual(@as(u64, 3), s.entries);
    try std.testing.expect(!s.tail_fragment);
    try std.testing.expect(!s.mid_file_damage);
    // entryTotal = align8(36 + K + V + 4): 44/45/46 all round to 48.
    try std.testing.expectEqual(@as(u64, 48), s.live_bytes);
    try std.testing.expectEqual(@as(u64, 96), s.garbage_bytes);
    try std.testing.expectEqual(@as(usize, 2), oracle.asks); // expired never asked
    const r = s.garbageRatio();
    try std.testing.expect(r > 0.66 and r < 0.67); // 96 / 144
}

test "gc: a truncated tail stops the walk; mid-file damage is flagged" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // File 1: cut into the second entry's body.
    var w1 = try writer.Writer.create(tmp.dir, io, 1, mgr.min_file_size);
    _ = try w1.append(io, 1, 0, "aa", "1111", null);
    const p2 = try w1.append(io, 2, 0, "bb", "2222", null);
    try w1.file.setLength(io, p2.offset + 10);
    w1.close(io);

    var oracle = Oracle{};
    const s1 = try scan(std.testing.allocator, io, tmp.dir, 1, 0, &oracle);
    try std.testing.expectEqual(@as(u64, 1), s1.entries);
    try std.testing.expect(s1.tail_fragment);
    try std.testing.expect(!s1.mid_file_damage);

    // File 2: smash the second entry's magic — a full header's worth
    // of bytes remains, so this is damage, not a tail.
    var w2 = try writer.Writer.create(tmp.dir, io, 2, mgr.min_file_size);
    defer w2.close(io);
    _ = try w2.append(io, 1, 0, "aa", "1111", null);
    _ = try w2.append(io, 2, 0, "bb", "2222", null);
    const bad: [4]u8 = @splat(0xEE);
    try disk.pwriteAll(w2.file, io, &bad, 48);

    const s2 = try scan(std.testing.allocator, io, tmp.dir, 2, 0, &oracle);
    try std.testing.expectEqual(@as(u64, 1), s2.entries);
    try std.testing.expect(s2.mid_file_damage);
    try std.testing.expect(!s2.tail_fragment);
}

test "gc: the deletion gate checks replayable, references, readers, active in order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var m = try mgr.Manager.open(allocator, tmp.dir, io, 1, mgr.min_file_size);
    defer m.close(io); // active id = 1

    // A second, non-active file so the readers cache can be populated.
    var w5 = try writer.Writer.create(tmp.dir, io, 5, mgr.min_file_size);
    _ = try w5.append(io, 1, 0, "k", "v", null);
    w5.close(io);

    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    const pset = try vids.pack(allocator, &.{10});
    defer allocator.free(pset);
    try addFile(&vs, 0, 1, 100, "a", "b", pset);

    // ④ replayable beats everything: wal 7 is live at log_number 5.
    try m.registerReplayable(io, 10, 7);
    try std.testing.expectEqual(Keep.replayable, gate(io, &m, &vs, 5, 10).?);
    try std.testing.expectEqual(@as(usize, 1), m.purgeReplayable(io, 8)); // wal 7 consumed
    // Falls through to ①: the SST still references it.
    try std.testing.expectEqual(Keep.referenced, gate(io, &m, &vs, 8, 10).?);
    // ③ the active writer's file never leaves.
    try std.testing.expectEqual(Keep.active_writer, gate(io, &m, &vs, 0, 1).?);
    // ② a cached reader handle holds file 5; retire releases it.
    var kb: [8]u8 = undefined;
    var vb: [8]u8 = undefined;
    _ = try m.readAt(io, 5, 0, &kb, &vb);
    try std.testing.expectEqual(Keep.open_reader, gate(io, &m, &vs, 0, 5).?);
    try m.retire(5);
    try std.testing.expectEqual(@as(?Keep, null), gate(io, &m, &vs, 0, 5));
}

test "gc: sweep unlinks only files the gate passes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var m = try mgr.Manager.open(allocator, tmp.dir, io, 1, mgr.min_file_size);
    defer m.close(io);
    _ = try m.append(io, 1, 0, "active", "v", null); // file 1 exists and is active

    // File 3: written, nobody references it → deletable.
    var w3 = try writer.Writer.create(tmp.dir, io, 3, mgr.min_file_size);
    _ = try w3.append(io, 1, 0, "x", "1", null);
    w3.close(io);
    // File 4: referenced by the version → kept.
    var w4 = try writer.Writer.create(tmp.dir, io, 4, mgr.min_file_size);
    _ = try w4.append(io, 1, 0, "y", "2", null);
    w4.close(io);

    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    const pset = try vids.pack(allocator, &.{4});
    defer allocator.free(pset);
    try addFile(&vs, 0, 9, 100, "a", "b", pset);

    const s = try sweep(allocator, io, tmp.dir, &m, &vs, 0);
    try std.testing.expectEqual(@as(usize, 1), s.deleted);
    try std.testing.expectEqual(@as(usize, 0), s.failed);
    try std.testing.expectEqual(@as(usize, 1), s.kept_referenced);
    try std.testing.expectEqual(@as(usize, 1), s.kept_active);

    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "000003.vlog", .{ .mode = .read_only }));
    const a = try tmp.dir.openFile(io, "000001.vlog", .{ .mode = .read_only });
    a.close(io);
    const b = try tmp.dir.openFile(io, "000004.vlog", .{ .mode = .read_only });
    b.close(io);
}
