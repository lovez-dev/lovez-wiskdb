//! K-way compaction merge over per-table block iterators. Inputs are read
//! blockwise; the output builder buffers one complete table. Produces
//! VersionEdit entries without committing them; the caller commits or
//! cleans up the generated files.

const std = @import("std");
const internal_key = @import("../util/internal_key.zig");
const coding = @import("../util/coding.zig");
const ivfmt = @import("../util/internal_value.zig");
const mf = @import("../manifest/format.zig");
const VersionSet = @import("../manifest/reader.zig").VersionSet;
const level = @import("level.zig");
const tmod = @import("../sstable/table_reader.zig");
const tbuild = @import("../sstable/table_builder.zig");
const vids = @import("../util/vlog_ids.zig");
const disk = @import("../io/io.zig");

const TIter = tmod.TableReader.TableIter;

/// Owns everything it hands out: `deinit` frees the added FileMetas'
/// strings; `edit` only borrows, and `VersionSet.apply` clones what it
/// keeps — so Result stays valid (and freeable) after a successful apply.
pub const Result = struct {
    adds: std.ArrayListUnmanaged(mf.FileMeta) = .empty,
    deletes: std.ArrayListUnmanaged(mf.DeleteFile) = .empty,
    vlog_deletes: std.ArrayListUnmanaged(u64) = .empty,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.adds.items) |f| f.deinit(allocator);
        self.adds.deinit(allocator);
        self.deletes.deinit(allocator);
        self.vlog_deletes.deinit(allocator);
    }

    pub fn edit(self: *const Result) mf.Edit {
        return .{
            .adds = self.adds.items,
            .deletes = self.deletes.items,
            .vlog_deletes = self.vlog_deletes.items,
        };
    }
};

/// Hooks run while constructing outputs; the caller controls synchronization.
pub const Hooks = struct {
    ctx: *anyopaque,
    allocate: *const fn (*anyopaque) anyerror!u64,
    rewrite: ?*const fn (*anyopaque, internal_key.View, []const u8) anyerror![]const u8 = null,
};

/// One output file under construction. Metadata owns independent slices,
/// so the abort path can always release the builder.
const OutState = struct {
    tb: ?tbuild.TableBuilder = null,
    id: u64 = 0,

    fn deinit(self: *OutState) void {
        if (self.tb) |*b| b.deinit();
    }

    fn start(self: *OutState, allocator: std.mem.Allocator, vs: *VersionSet, hooks: ?Hooks) !void {
        std.debug.assert(self.tb == null);
        self.tb = try tbuild.TableBuilder.init(allocator, .{});
        if (hooks) |h| {
            self.id = try h.allocate(h.ctx);
        } else {
            self.id = vs.next_file_number;
            vs.next_file_number += 1;
        }
    }

    /// Flush the current builder to disk as one SST and hand back its
    /// FileMeta; the output level is not the builder's business.
    fn finish(self: *OutState, io: std.Io, dir: disk.Dir, output_level: u32) !mf.FileMeta {
        const tb = &self.tb.?;
        const img = try tb.finish();
        const fm = try tb.metadata(output_level, self.id);
        errdefer fm.deinit(tb.allocator);
        var namebuf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&namebuf, "{d:0>6}.sst", .{self.id}) catch unreachable;
        const f = try dir.createFile(io, name, .{ .read = true, .truncate = true, .exclusive = true });
        disk.pwriteAll(f, io, img, 0) catch |e| {
            f.close(io);
            disk.unlink(dir, io, name) catch {};
            return e;
        };
        disk.fsync(f, io) catch |e| {
            f.close(io);
            disk.unlink(dir, io, name) catch {};
            return e;
        };
        f.close(io);
        _ = try disk.syncDirectory(dir, io);

        tb.deinit();
        self.tb = null;
        return fm;
    }
};

fn tableName(id: u64, buf: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>6}.sst", .{id}) catch unreachable;
}

pub fn merge(
    allocator: std.mem.Allocator,
    io: std.Io,
    sst_dir: disk.Dir,
    vs: *VersionSet,
    p: level.Params,
    plan: *const level.Plan,
) !Result {
    return mergeWithHooks(allocator, io, sst_dir, vs, p, plan, null);
}

pub fn mergeWithHooks(
    allocator: std.mem.Allocator,
    io: std.Io,
    sst_dir: disk.Dir,
    vs: *VersionSet,
    p: level.Params,
    plan: *const level.Plan,
    hooks: ?Hooks,
) !Result {
    var result = Result{};
    errdefer result.deinit(allocator);

    // --- open every input and overlap table -------------------------
    var sources: std.ArrayListUnmanaged(*const mf.FileMeta) = .empty;
    defer sources.deinit(allocator);
    try sources.appendSlice(allocator, plan.inputs.items);
    try sources.appendSlice(allocator, plan.overlaps.items);

    const readers = try allocator.alloc(tmod.TableReader, sources.items.len);
    var opened: usize = 0;
    defer {
        for (readers[0..opened]) |*r| r.deinit();
        allocator.free(readers);
    }
    const iters = try allocator.alloc(TIter, sources.items.len);
    var running: usize = 0;
    defer {
        for (iters[0..running]) |*it| it.deinit();
        allocator.free(iters);
    }
    for (sources.items, 0..) |f, idx| {
        var namebuf: [32]u8 = undefined;
        readers[idx] = try tmod.TableReader.open(allocator, io, sst_dir, tableName(f.file_id, &namebuf));
        opened = idx + 1;
        iters[idx] = TIter.init(&readers[idx]);
        running = idx + 1;
        try iters[idx].seekToFirst();
    }

    // --- output state ------------------------------------------------
    var out = OutState{};
    defer out.deinit();
    var written: std.ArrayListUnmanaged(u64) = .empty; // ids any surviving record still points at
    defer written.deinit(allocator);
    var user_buf: std.ArrayListUnmanaged(u8) = .empty; // group user key, reused per group
    defer user_buf.deinit(allocator);
    const size_cap: usize = @intCast(p.max_sst_file_size);

    // --- k-way group loop -------------------------------------------
    while (true) {
        var start: ?usize = null;
        for (iters, 0..) |*it, idx| {
            if (!it.valid()) continue;
            if (start == null or internal_key.compare(it.key(), iters[start.?].key()) == .lt) start = idx;
        }
        const s = start orelse break;
        const gview = internal_key.decode(iters[s].key()) catch return error.InvalidInternalKey;
        user_buf.clearRetainingCapacity();
        try user_buf.appendSlice(allocator, gview.user);
        const user = user_buf.items;

        var newest = true;
        while (true) {
            var take: ?usize = null;
            for (iters, 0..) |*it, idx| {
                if (!it.valid()) continue;
                const k = it.key();
                const kv = internal_key.decode(k) catch return error.InvalidInternalKey;
                if (!std.mem.eql(u8, kv.user, user)) continue;
                if (take == null or internal_key.compare(k, iters[take.?].key()) == .lt) take = idx;
            }
            const t = take orelse break;
            if (newest) {
                newest = false;
                const k = iters[t].key();
                const iv = iters[t].value();
                const view = internal_key.decode(k) catch return error.InvalidInternalKey;
                // The newest entry of a group is the only survivor; a
                // tombstone additionally needs a reason to live on.
                const keep = view.kind == .put or !level.dropTombstone(
                    p,
                    plan.output_level,
                    level.rangeOverlapBelow(vs, p, plan.output_level, view.user, view.user),
                );
                if (keep) try emit(allocator, &out, vs, k, iv, view, &written, hooks);
            }
            try iters[t].next();
        }

        if (out.tb != null and out.tb.?.out.items.len + out.tb.?.data.data.items.len >= size_cap) {
            const fm = try out.finish(io, sst_dir, plan.output_level);
            result.adds.append(allocator, fm) catch |e| {
                fm.deinit(allocator);
                return e;
            };
        }
    }
    if (out.tb != null) {
        const fm = try out.finish(io, sst_dir, plan.output_level);
        result.adds.append(allocator, fm) catch |e| {
            fm.deinit(allocator);
            return e;
        };
    }

    // --- VersionEdit pieces -----------------------------------------
    for (plan.inputs.items) |f| try result.deletes.append(allocator, .{ .level = f.level, .file_id = f.file_id });
    for (plan.overlaps.items) |f| try result.deletes.append(allocator, .{ .level = f.level, .file_id = f.file_id });

    var input_ids: std.ArrayListUnmanaged(u64) = .empty;
    defer input_ids.deinit(allocator);
    for (sources.items) |f| {
        // A range (or unparsable) set yields nothing enumerable: those
        // ids stay out of the candidate list — missing a deletion beats
        // inventing one.
        if (try vids.unpackExact(allocator, f.vlog_ids)) |exact| {
            defer allocator.free(exact);
            for (exact) |id| try vids.insert(allocator, &input_ids, id);
        }
    }
    for (input_ids.items) |id| {
        var survives = false;
        for (written.items) |w| {
            if (w == id) {
                survives = true;
                break;
            }
        }
        if (!survives) try result.vlog_deletes.append(allocator, id);
    }
    return result;
}

fn emit(
    allocator: std.mem.Allocator,
    out: *OutState,
    vs: *VersionSet,
    k: []const u8,
    iv: []const u8,
    view: internal_key.View,
    written: *std.ArrayListUnmanaged(u64),
    hooks: ?Hooks,
) !void {
    _ = ivfmt.Header.decode(iv) catch return error.SSTableCorrupted;
    const value = if (hooks) |h| blk: {
        if (view.kind == .put) {
            if (h.rewrite) |rewrite| break :blk try rewrite(h.ctx, view, iv);
        }
        break :blk iv;
    } else iv;
    if (out.tb == null) try out.start(allocator, vs, hooks);
    try out.tb.?.add(k, value);

    const header = ivfmt.Header.decode(value) catch return error.SSTableCorrupted;
    const vid = header.file_id;
    if (vid != 0) {
        try vids.insert(allocator, written, vid);
    }
}

// ========================= tests =========================

const Entry = struct { user: []const u8, seq: u64, delete: bool, val: []const u8, vid: u64 };

fn ivFor(buf: *[64]u8, e: Entry) []const u8 {
    @memset(buf[0..21], 0);
    if (e.vid != 0) {
        coding.putU64(buf[5..13], e.vid); // pointer form: no inline payload
        return buf[0..21];
    }
    buf[0] = 0b010; // INLINE
    std.mem.writeInt(u32, buf[1..5], @intCast(e.val.len), .little);
    @memcpy(buf[21..][0..e.val.len], e.val);
    return buf[0 .. 21 + e.val.len];
}

fn writeTbl(allocator: std.mem.Allocator, io: std.Io, dir: disk.Dir, id: u64, entries: []const Entry) !void {
    var tb = try tbuild.TableBuilder.init(allocator, .{});
    defer tb.deinit();
    var ikbuf: [128]u8 = undefined;
    var ivbuf: [64]u8 = undefined;
    for (entries) |e| {
        const ikl = try internal_key.encode(e.user, e.seq, if (e.delete) .delete else .put, &ikbuf);
        try tb.add(ikbuf[0..ikl], ivFor(&ivbuf, e));
    }
    const img = try tb.finish();
    var namebuf: [32]u8 = undefined;
    const name = tableName(id, &namebuf);
    const f = try dir.createFile(io, name, .{ .read = true, .truncate = true, .exclusive = true });
    defer f.close(io);
    try disk.pwriteAll(f, io, img, 0);
}

fn addFile(vs: *VersionSet, lvl: u32, id: u64, size: u64, smallest: []const u8, largest: []const u8, vlog_ids: []const u8) !void {
    const f = mf.FileMeta{
        .level = lvl,
        .file_id = id,
        .file_size = size,
        .smallest = smallest,
        .largest = largest,
        .min_seq = 1,
        .max_seq = 99,
        .vlog_ids = vlog_ids,
    };
    const adds = [_]mf.FileMeta{f};
    var e = mf.Edit{ .adds = &adds };
    try vs.apply(&e); // clones what it stores; the literal edit owns nothing
}

fn walkExpect(allocator: std.mem.Allocator, io: std.Io, dir: disk.Dir, id: u64, expect: []const []const u8) !void {
    var namebuf: [32]u8 = undefined;
    var tr = try tmod.TableReader.open(allocator, io, dir, tableName(id, &namebuf));
    defer tr.deinit();
    var it = tmod.TableReader.TableIter.init(&tr);
    defer it.deinit();
    try it.seekToFirst();
    var i: usize = 0;
    while (it.valid()) : (i += 1) {
        if (i >= expect.len) return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, expect[i], it.key());
        try it.next();
    }
    try std.testing.expectEqual(expect.len, i);
}

test "merge: newest wins; a tombstone drops when nothing below can resurrect it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTbl(allocator, io, tmp.dir, 1, &.{
        .{ .user = "a", .seq = 1, .delete = false, .val = "v1", .vid = 7 },
        .{ .user = "b", .seq = 1, .delete = false, .val = "v1", .vid = 9 },
        .{ .user = "c", .seq = 1, .delete = false, .val = "v1", .vid = 7 },
    });
    try writeTbl(allocator, io, tmp.dir, 2, &.{
        .{ .user = "a", .seq = 3, .delete = false, .val = "v3", .vid = 8 },
        .{ .user = "b", .seq = 5, .delete = true, .val = "", .vid = 0 },
    });

    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    const p1 = try vids.pack(allocator, &.{ @as(u64, 7), 9 });
    defer allocator.free(p1);
    const p2 = try vids.pack(allocator, &.{@as(u64, 8)});
    defer allocator.free(p2);
    try addFile(&vs, 1, 1, 100, "a", "c", p1);
    try addFile(&vs, 0, 2, 100, "a", "b", p2);
    vs.next_file_number = 10; // recovery normally loads this above every live file id

    const p = level.Params{ .l0_compaction_trigger = 1 };
    var plan = (try level.pick(allocator, &vs, p)).?;
    defer plan.deinit(allocator);

    var res = try merge(allocator, io, tmp.dir, &vs, p, &plan);
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.adds.items.len);
    try std.testing.expectEqual(@as(u32, 1), res.adds.items[0].level);
    try std.testing.expectEqualStrings("a", res.adds.items[0].smallest);
    try std.testing.expectEqualStrings("c", res.adds.items[0].largest);
    try std.testing.expectEqual(@as(usize, 2), res.deletes.items.len);
    // b's old value pointed at vlog 9 and died under the tombstone → candidate
    try std.testing.expectEqualSlices(u64, &.{9}, res.vlog_deletes.items);

    var e1: [64]u8 = undefined;
    var e2: [64]u8 = undefined;
    const n1 = try internal_key.encode("a", 3, .put, &e1);
    const n2 = try internal_key.encode("c", 1, .put, &e2);
    try walkExpect(allocator, io, tmp.dir, res.adds.items[0].file_id, &.{ e1[0..n1], e2[0..n2] });

    var e = res.edit();
    try vs.apply(&e); // commit: old files gone, one L1 file present
    try std.testing.expectEqual(@as(usize, 0), vs.fileCount(0));
    try std.testing.expectEqual(@as(usize, 1), vs.fileCount(1));
}

test "merge: a tombstone survives when a file below overlaps its key" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTbl(allocator, io, tmp.dir, 1, &.{
        .{ .user = "a", .seq = 1, .delete = false, .val = "v1", .vid = 0 },
        .{ .user = "b", .seq = 1, .delete = false, .val = "v1", .vid = 0 },
        .{ .user = "c", .seq = 1, .delete = false, .val = "v1", .vid = 0 },
    });
    try writeTbl(allocator, io, tmp.dir, 2, &.{
        .{ .user = "b", .seq = 5, .delete = true, .val = "", .vid = 0 },
    });

    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    try addFile(&vs, 1, 1, 100, "a", "c", "");
    try addFile(&vs, 0, 2, 100, "b", "b", "");
    try addFile(&vs, 2, 3, 100, "b", "b", ""); // a live value below b: the tombstone must stay
    vs.next_file_number = 10; // recovery normally loads this above every live file id

    const p = level.Params{ .l0_compaction_trigger = 1 };
    var plan = (try level.pick(allocator, &vs, p)).?;
    defer plan.deinit(allocator);

    var res = try merge(allocator, io, tmp.dir, &vs, p, &plan);
    defer res.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), res.adds.items.len);

    var e1: [64]u8 = undefined;
    var e2: [64]u8 = undefined;
    var e3: [64]u8 = undefined;
    const n1 = try internal_key.encode("a", 1, .put, &e1);
    const n2 = try internal_key.encode("b", 5, .delete, &e2);
    const n3 = try internal_key.encode("c", 1, .put, &e3);
    try walkExpect(allocator, io, tmp.dir, res.adds.items[0].file_id, &.{ e1[0..n1], e2[0..n2], e3[0..n3] });
    try std.testing.expectEqual(@as(usize, 0), res.vlog_deletes.items.len); // no packed refs in the fixtures
}

test "merge: outputs are cut at max_sst_file_size with disjoint ranges" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var entries: [40]Entry = undefined;
    for (0..40) |i| {
        entries[i] = .{ .user = "", .seq = @intCast(i + 1), .delete = false, .val = "v", .vid = 0 };
    }
    // user keys need stable storage: use a side buffer
    var keybuf: [40][8]u8 = undefined;
    for (0..40) |i| {
        const u = try std.fmt.bufPrint(&keybuf[i], "k{d:0>2}", .{i});
        entries[i].user = u;
    }
    try writeTbl(allocator, io, tmp.dir, 1, &entries);

    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    try addFile(&vs, 0, 1, 40 * 40, entries[0].user, entries[39].user, "");
    vs.next_file_number = 10; // recovery normally loads this above every live file id

    const p = level.Params{ .l0_compaction_trigger = 1, .max_sst_file_size = 300 };
    var plan = (try level.pick(allocator, &vs, p)).?;
    defer plan.deinit(allocator);

    var res = try merge(allocator, io, tmp.dir, &vs, p, &plan);
    defer res.deinit(allocator);
    try std.testing.expect(res.adds.items.len >= 2); // the cut actually happened

    var expected: [40][64]u8 = undefined;
    var elen: [40]usize = undefined;
    for (0..40) |i| elen[i] = try internal_key.encode(entries[i].user, entries[i].seq, .put, &expected[i]);

    var idx: usize = 0;
    var prev_largest: []const u8 = "";
    for (res.adds.items) |f| {
        var oname: [32]u8 = undefined;
        var tr = try tmod.TableReader.open(allocator, io, tmp.dir, tableName(f.file_id, &oname));
        defer tr.deinit();
        var it = tmod.TableReader.TableIter.init(&tr);
        defer it.deinit();
        try it.seekToFirst();
        while (it.valid()) {
            if (idx >= 40) return error.TestUnexpectedResult;
            try std.testing.expectEqualSlices(u8, expected[idx][0..elen[idx]], it.key());
            idx += 1;
            try it.next();
        }
        try std.testing.expect(std.mem.order(u8, prev_largest, f.smallest) == .lt); // no range overlap between outputs
        prev_largest = f.largest;
    }
    try std.testing.expectEqual(@as(usize, 40), idx);
}

test "merge: range metadata preserves late vlog bounds and exact dead-id subtraction" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var entries: [68]Entry = undefined;
    var keybuf: [68][16]u8 = undefined;
    for (&entries, 0..) |*entry, i| {
        entry.* = .{
            .user = if (i == 0) "" else try std.fmt.bufPrint(&keybuf[i], "key{d:0>3}", .{i}),
            .seq = @intCast(i + 1),
            .delete = false,
            .val = "",
            .vid = switch (i) {
                65 => 1,
                66 => 1000,
                67 => 500,
                else => @intCast(100 + i),
            },
        };
    }

    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    // Each input has an exact id set; their merged output crosses the cap.
    for (0..2) |part| {
        const batch = entries[part * 34 ..][0..34];
        const id: u64 = @intCast(part + 1);
        try writeTbl(allocator, io, tmp.dir, id, batch);
        var ids: std.ArrayListUnmanaged(u64) = .empty;
        defer ids.deinit(allocator);
        for (batch) |entry| try vids.insert(allocator, &ids, entry.vid);
        const packed_ids = try vids.pack(allocator, ids.items);
        defer allocator.free(packed_ids);
        try addFile(&vs, 0, id, 2048, batch[0].user, batch[33].user, packed_ids);
    }
    try writeTbl(allocator, io, tmp.dir, 3, &.{
        .{ .user = entries[67].user, .seq = 100, .delete = true, .val = "", .vid = 0 },
    });
    try addFile(&vs, 0, 3, 100, entries[67].user, entries[67].user, "\x01\x00");
    vs.next_file_number = 10;
    const p = level.Params{ .l0_compaction_trigger = 1 };
    var plan = (try level.pick(allocator, &vs, p)).?;
    defer plan.deinit(allocator);
    var result = try merge(allocator, io, tmp.dir, &vs, p, &plan);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.adds.items.len);
    const meta = result.adds.items[0];
    try std.testing.expectEqualStrings("", meta.smallest);
    try std.testing.expectEqualStrings(entries[66].user, meta.largest);
    try std.testing.expectEqual(@as(u64, 1), meta.min_seq);
    try std.testing.expectEqual(@as(u64, 67), meta.max_seq);
    try std.testing.expect((try vids.unpackExact(allocator, meta.vlog_ids)) == null);
    for (entries[0..67]) |entry| {
        try std.testing.expectEqual(vids.Ref.referenced, vids.reference(meta.vlog_ids, entry.vid));
    }
    // 500 lies inside the covering range but has no surviving record.
    try std.testing.expectEqualSlices(u64, &.{500}, result.vlog_deletes.items);

    var namebuf: [32]u8 = undefined;
    var reader = try tmod.TableReader.open(allocator, io, tmp.dir, tableName(meta.file_id, &namebuf));
    defer reader.deinit();
    try std.testing.expectEqual(reader.file_size, meta.file_size);
    var iter = TIter.init(&reader);
    defer iter.deinit();
    try iter.seekToFirst();
    for (entries[0..67]) |entry| {
        try std.testing.expect(iter.valid());
        const key = try internal_key.decode(iter.key());
        const value = try ivfmt.Header.decode(iter.value());
        try std.testing.expectEqualStrings(entry.user, key.user);
        try std.testing.expectEqual(entry.seq, key.seq);
        try std.testing.expectEqual(entry.vid, value.file_id);
        try iter.next();
    }
    try std.testing.expect(!iter.valid());
}
