//! Runtime maintenance. Only the worker changes SST versions; writers may
//! append and freeze while merge builds immutable outputs without the db lock.
const std = @import("std");
const Db = @import("db.zig").Db;
const VersionSet = @import("manifest/version_set.zig").VersionSet;
const level = @import("compaction/level.zig");
const merger = @import("compaction/merge.zig");
const disk = @import("io/io.zig");
const ik = @import("util/internal_key.zig");
const internal_value = @import("util/internal_value.zig");
const vids = @import("util/vlog_ids.zig");
const gc = @import("vlog/gc.zig");
const TableReader = @import("sstable/table_reader.zig").TableReader;
const file_ids = @import("file_ids.zig");

pub fn tick(raw: *anyopaque) void {
    const db: *Db = @ptrCast(@alignCast(raw));
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);
    if (db.closing or db.background_error != null) return;
    db.syncThrough(db.last_seq.load(.acquire)) catch |err| {
        db.background_error = err;
    };
    db.write_cond.broadcast(db.io);
}

pub fn start(raw: *anyopaque) void {
    const db: *Db = @ptrCast(@alignCast(raw));
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);
    if (db.background_error != null) return;
    maintainLocked(db, db.options.automatic_gc) catch |err| {
        db.background_error = err;
    };
    db.write_cond.broadcast(db.io);
}

pub fn run(raw: *anyopaque) void {
    const db: *Db = @ptrCast(@alignCast(raw));
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);
    if (db.background_error != null) return;
    maintainLocked(db, true) catch |err| {
        db.background_error = err;
    };
    db.write_cond.broadcast(db.io);
}

fn params(db: *Db) level.Params {
    return .{
        .write_buffer_size = db.options.write_buffer_size,
        .l0_compaction_trigger = db.options.l0_compaction_trigger,
        .max_sst_file_size = db.options.max_sst_file_size,
    };
}

/// Enter and return with write_mutex held. The worker is the sole caller.
pub fn maintainLocked(db: *Db, collect: bool) !void {
    reclaimTablesLocked(db);
    while (true) {
        var snapshot = try db.vs.cloneState();
        defer snapshot.deinit();
        var plan = (try level.pick(db.internal_allocator, &snapshot, params(db))) orelse break;
        defer plan.deinit(db.internal_allocator);
        try mergeAndCommit(db, &snapshot, &plan, null);
    }
    if (collect) try collectLocked(db);
}

const MergeContext = struct {
    db: *Db,
    victim: ?u64,
    output_ids: std.ArrayListUnmanaged(u64) = .empty,
    scratch: [internal_value.expiry_header_len]u8 = undefined,

    fn allocate(raw: *anyopaque) !u64 {
        const ctx: *MergeContext = @ptrCast(@alignCast(raw));
        const db = ctx.db;
        db.write_mutex.lockUncancelable(db.io);
        defer db.write_mutex.unlock(db.io);
        // Reserve only after cleanup tracking can no longer fail.
        try ctx.output_ids.ensureUnusedCapacity(db.internal_allocator, 1);
        const id = file_ids.reserveLocked(db);
        ctx.output_ids.appendAssumeCapacity(id);
        return id;
    }

    fn rewrite(raw: *anyopaque, view: ik.View, iv: []const u8) ![]const u8 {
        const ctx: *MergeContext = @ptrCast(@alignCast(raw));
        var header = internal_value.Header.decode(iv) catch return error.SSTableCorrupted;
        if (header.isDeleted() or header.isInline() or header.file_id != ctx.victim.?) return iv;
        const db = ctx.db;
        db.write_mutex.lockUncancelable(db.io);
        defer db.write_mutex.unlock(db.io);
        const value = try db.valueFromIvAlloc(iv, view.user, db.internal_allocator);
        defer db.internal_allocator.free(value);
        const pointer = try file_ids.appendVlogLocked(db, view.seq, header.expire_at orelse 0, view.user, value, null);
        header.file_id = pointer.file_id;
        header.offset = pointer.offset;
        return internal_value.encode(header, "", &ctx.scratch) catch unreachable;
    }
};

fn tableName(id: u64, buf: *[32]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>6}.sst", .{id}) catch unreachable;
}

fn buildOutsideLock(db: *Db, snapshot: *VersionSet, plan: *level.Plan, ctx: *MergeContext) !merger.Result {
    db.write_mutex.unlock(db.io);
    defer db.write_mutex.lockUncancelable(db.io);
    return merger.mergeWithHooks(db.internal_allocator, db.io, db.sst_dir, snapshot, params(db), plan, .{
        .ctx = ctx,
        .allocate = MergeContext.allocate,
        .rewrite = if (ctx.victim != null) MergeContext.rewrite else null,
    });
}

fn mergeAndCommit(db: *Db, snapshot: *VersionSet, plan: *level.Plan, victim: ?u64) !void {
    if (victim == null and level.canMove(plan, params(db))) {
        try moveAndCommit(db, plan);
        return;
    }
    var ctx = MergeContext{ .db = db, .victim = victim };
    defer ctx.output_ids.deinit(db.internal_allocator);
    var committed = false;
    defer if (!committed) {
        for (ctx.output_ids.items) |id| {
            var buf: [32]u8 = undefined;
            disk.unlink(db.sst_dir, db.io, tableName(id, &buf)) catch {};
        }
    };
    var result = try buildOutsideLock(db, snapshot, plan, &ctx);
    defer result.deinit(db.internal_allocator);
    var next = try db.vs.cloneState();
    defer next.deinit();
    try next.apply(&result.edit());
    // Retirement must not fail after the manifest edit lands.
    try db.obsolete_ssts.ensureUnusedCapacity(db.internal_allocator, result.deletes.items.len);
    // GC may have appended to several VLogs; rotation fsyncs prior files.
    if (victim != null) try db.vlog.sync(db.io);
    @import("manifest/commit.zig").publishAndInstallLocked(db, &next) catch |err| {
        // A complete edit may have landed despite the error: keep outputs.
        committed = true;
        return err;
    };
    committed = true;
    // Old read views may not have opened these files yet. Keep their paths
    // and cache entries until every view predating this publication exits.
    for (result.deletes.items) |deleted| {
        db.obsolete_ssts.appendAssumeCapacity(deleted.file_id);
    }
    db.retired_tables_pending.store(db.obsolete_ssts.items.len != 0, .release);
    reclaimTablesLocked(db);
}

fn moveAndCommit(db: *Db, plan: *const level.Plan) !void {
    const allocator = db.internal_allocator;
    const adds = try allocator.alloc(@import("manifest/format.zig").FileMeta, plan.inputs.items.len);
    defer allocator.free(adds);
    const deletes = try allocator.alloc(@import("manifest/format.zig").DeleteFile, plan.inputs.items.len);
    defer allocator.free(deletes);
    // Metadata borrows the independent planning snapshot until apply clones it.
    // The SST paths, cache keys and old read views keep the same file identity.
    for (plan.inputs.items, adds, deletes) |file, *add, *delete| {
        add.* = file.*;
        add.level = plan.output_level;
        delete.* = .{ .level = plan.level, .file_id = file.file_id };
    }
    var next = try db.vs.cloneState();
    defer next.deinit();
    try next.apply(&.{ .adds = adds, .deletes = deletes });
    // Publication still performs all durability barriers. Never retire the
    // moved files: both installed versions reference their unchanged bytes.
    try @import("manifest/commit.zig").publishAndInstallLocked(db, &next);
}

/// Caller holds write_mutex, or has exclusive ownership during close.
pub fn reclaimTablesLocked(db: *Db) void {
    if (db.active_reads.load(.acquire) != 0) return;
    var kept: usize = 0;
    for (db.obsolete_ssts.items) |id| {
        db.tables.invalidate(id);
        var buf: [32]u8 = undefined;
        disk.unlink(db.sst_dir, db.io, tableName(id, &buf)) catch |err| {
            if (err != error.FileNotFound) {
                db.obsolete_ssts.items[kept] = id;
                kept += 1;
            }
        };
    }
    db.obsolete_ssts.items.len = kept;
    db.retired_tables_pending.store(kept != 0, .release);
}

const Live = struct {
    seqs: std.AutoHashMapUnmanaged(u64, void) = .empty,
    pub fn isLive(self: *Live, key: []const u8, seq: u64, expire_at: u64) bool {
        _ = key;
        _ = expire_at;
        return self.seqs.contains(seq);
    }
};

fn liveReferences(db: *Db, snapshot: *const VersionSet, id: u64, live: *Live) !void {
    db.write_mutex.unlock(db.io);
    defer db.write_mutex.lockUncancelable(db.io);
    for (snapshot.by_level.values()) |files| {
        for (files.items) |file| {
            if (vids.reference(file.vlog_ids, id) == .absent) continue;
            var buf: [32]u8 = undefined;
            var reader = try TableReader.open(db.internal_allocator, db.io, db.sst_dir, tableName(file.file_id, &buf));
            defer reader.deinit();
            var it = TableReader.TableIter.init(&reader);
            defer it.deinit();
            try it.seekToFirst();
            while (it.valid()) : (try it.next()) {
                const iv = it.value();
                const header = internal_value.Header.decode(iv) catch return error.SSTableCorrupted;
                if (!header.isDeleted() and !header.isInline() and header.file_id == id) {
                    const view = try ik.decode(it.key());
                    try live.seqs.put(db.internal_allocator, view.seq, {});
                }
            }
        }
    }
}

fn scanOutsideLock(db: *Db, id: u64, live: *Live) !gc.Scan {
    db.write_mutex.unlock(db.io);
    defer db.write_mutex.lockUncancelable(db.io);
    return gc.scan(db.internal_allocator, db.io, db.vlog_dir, id, 0, live);
}

fn collectLocked(db: *Db) !void {
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    defer ids.deinit(db.internal_allocator);
    var entries = db.vlog_dir.iterate();
    while (try entries.next(db.io)) |entry| {
        if (entry.kind != .file) continue;
        const id = @import("replay.zig").parseIdName(entry.name, ".vlog") orelse continue;
        if (id == db.vlog.writer.file_id or db.vlog.replayableProtected(db.io, id, db.vs.log_number)) continue;
        try ids.append(db.internal_allocator, id);
    }
    for (ids.items) |id| {
        var live = Live{};
        defer live.seqs.deinit(db.internal_allocator);
        var snapshot = try db.vs.cloneState();
        defer snapshot.deinit();
        try liveReferences(db, &snapshot, id, &live);
        if (live.seqs.count() != 0) {
            // Physical references are conservative: stale SST versions count
            // as live until compaction removes them. Never guess liveness.
            const scan = try scanOutsideLock(db, id, &live);
            if (scan.mid_file_damage) return error.VLogCorrupted;
            if (scan.garbageRatio() < db.options.gc_garbage_ratio) continue;
            var plan = level.Plan{ .level = 0, .output_level = params(db).max_levels - 1 };
            defer plan.deinit(db.internal_allocator);
            for (snapshot.by_level.values()) |*files| {
                for (files.items) |*file| try plan.inputs.append(db.internal_allocator, file);
            }
            // All SSTs participate so every surviving victim pointer is
            // relocated in one manifest transaction, preserving sequence ids.
            try mergeAndCommit(db, &snapshot, &plan, id);
        }
        db.vlog.evictReader(id);
    }
    // WAL registrations also cover current and immutable MemTables.
    // An old view can still contain a pointer to a rewritten VLog. A later
    // maintenance pass sweeps it once all read views have left their epoch.
    if (db.active_reads.load(.acquire) == 0) _ = try gc.sweep(db.internal_allocator, db.io, db.vlog_dir, &db.vlog, &db.vs, db.vs.log_number);
}

fn testPrepareMove(db: *Db, external: bool) !void {
    const large: [600]u8 = @splat('v');
    try db.put("a", if (external) &large else "first");
    try db.flush();
    try db.put("z", if (external) &large else "last");
    try db.flush();
    try std.testing.expectEqual(@as(usize, 2), db.vs.fileCount(0));
}

fn testSstBytes(db: *Db, id: u64) ![]u8 {
    var name: [32]u8 = undefined;
    const file = try db.sst_dir.openFile(db.io, tableName(id, &name), .{});
    defer file.close(db.io);
    const bytes = try std.testing.allocator.alloc(u8, @intCast(try file.length(db.io)));
    errdefer std.testing.allocator.free(bytes);
    try disk.preadAll(file, db.io, bytes, 0);
    return bytes;
}

fn testGet(db: *Db, key: []const u8, expected: []const u8) !void {
    const actual = (try db.get(key)) orelse return error.MissingMoveValue;
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "runtime move: unchanged SST identities survive old read views and reopen" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const options: @import("db.zig").Options = .{ .durability = .async, .automatic_gc = false, .l0_compaction_trigger = 64 };
    var ids: [2]u64 = undefined;
    {
        var db = try Db.open(allocator, io, tmp.dir, options);
        defer db.deinit();
        try testPrepareMove(&db, false);
        db.write_mutex.lockUncancelable(io);
        var view = @import("read.zig").View.captureLocked(&db, "a") catch |err| {
            db.write_mutex.unlock(io);
            return err;
        };
        db.write_mutex.unlock(io);
        defer view.deinit(&db);
        var snapshot = try db.vs.cloneState();
        defer snapshot.deinit();
        var plan = (try level.pick(allocator, &snapshot, .{ .l0_compaction_trigger = 2 })).?;
        defer plan.deinit(allocator);
        try std.testing.expect(level.canMove(&plan, params(&db)));
        for (plan.inputs.items, &ids) |file, *id| id.* = file.file_id;
        const before = try testSstBytes(&db, ids[0]);
        defer allocator.free(before);
        {
            db.write_mutex.lockUncancelable(io);
            defer db.write_mutex.unlock(io);
            try mergeAndCommit(&db, &snapshot, &plan, null);
            try std.testing.expectEqual(@as(usize, 0), db.vs.fileCount(0));
            try std.testing.expectEqual(@as(usize, 2), db.vs.fileCount(1));
            try std.testing.expectEqual(@as(usize, 0), db.obsolete_ssts.items.len);
            for (db.vs.by_level.get(1).?.items, ids) |file, id| try std.testing.expectEqual(id, file.file_id);
        }
        const after = try testSstBytes(&db, ids[0]);
        defer allocator.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
        const old_value = (try view.get(&db, "a")).?;
        defer allocator.free(old_value);
        try std.testing.expectEqualStrings("first", old_value);
        try testGet(&db, "a", "first");
        try testGet(&db, "z", "last");
    }
    var reopened = try Db.open(allocator, io, tmp.dir, options);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.vs.fileCount(1));
    for (reopened.vs.by_level.get(1).?.items, ids) |file, id| try std.testing.expectEqual(id, file.file_id);
    try testGet(&reopened, "a", "first");
    try testGet(&reopened, "z", "last");
}

test "runtime move: manifest append failures preserve source files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const options: @import("db.zig").Options = .{ .durability = .async, .automatic_gc = false, .l0_compaction_trigger = 64 };
        var ids: [2]u64 = undefined;
        {
            var db = try Db.open(allocator, io, tmp.dir, options);
            defer db.deinit();
            try testPrepareMove(&db, false);
            var snapshot = try db.vs.cloneState();
            defer snapshot.deinit();
            var plan = (try level.pick(allocator, &snapshot, .{ .l0_compaction_trigger = 2 })).?;
            defer plan.deinit(allocator);
            for (plan.inputs.items, &ids) |file, *id| id.* = file.file_id;
            const original = db.read_version;
            {
                db.write_mutex.lockUncancelable(io);
                defer db.write_mutex.unlock(io);
                disk.TestWrite.target = db.manifest_writer.file.handle;
                disk.TestWrite.calls = 0;
                disk.TestWrite.fail_at = 0;
                defer {
                    disk.TestWrite.target = null;
                    disk.TestWrite.fail_at = std.math.maxInt(usize);
                }
                try std.testing.expectError(error.InputOutput, mergeAndCommit(&db, &snapshot, &plan, null));
                try std.testing.expect(db.read_version == original);
                try std.testing.expectEqual(@as(usize, 2), db.vs.fileCount(0));
                try std.testing.expectEqual(@as(usize, 0), db.vs.fileCount(1));
                try std.testing.expectEqual(@as(usize, 0), db.obsolete_ssts.items.len);
            }
            for (ids) |id| allocator.free(try testSstBytes(&db, id));
            try testGet(&db, "a", "first");
            try testGet(&db, "z", "last");
        }
        var reopened = try Db.open(allocator, io, tmp.dir, options);
        defer reopened.deinit();
        try std.testing.expectEqual(@as(usize, 2), reopened.vs.fileCount(0));
        for (reopened.vs.by_level.get(0).?.items, ids) |file, id| try std.testing.expectEqual(id, file.file_id);
        try testGet(&reopened, "a", "first");
        try testGet(&reopened, "z", "last");
    }
}

test "runtime move: a GC victim forces rewrite even for a move-eligible plan" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const options: @import("db.zig").Options = .{ .durability = .async, .automatic_gc = false, .l0_compaction_trigger = 64 };
    var db = try Db.open(allocator, io, tmp.dir, options);
    defer db.deinit();
    try testPrepareMove(&db, true);
    {
        var snapshot = try db.vs.cloneState();
        defer snapshot.deinit();
        var plan = (try level.pick(allocator, &snapshot, .{ .l0_compaction_trigger = 2 })).?;
        defer plan.deinit(allocator);
        try std.testing.expect(level.canMove(&plan, params(&db)));
        db.write_mutex.lockUncancelable(io);
        defer db.write_mutex.unlock(io);
        const victim = db.vlog.writer.file_id;
        try file_ids.sealVlogLocked(&db);
        try mergeAndCommit(&db, &snapshot, &plan, victim);
        try std.testing.expectEqual(@as(usize, 0), db.vs.fileCount(0));
        const outputs = db.vs.by_level.get(1).?.items;
        try std.testing.expect(outputs.len != 0);
        for (outputs) |file| {
            for (plan.inputs.items) |input| try std.testing.expect(file.file_id != input.file_id);
            try std.testing.expectEqual(vids.Ref.absent, vids.reference(file.vlog_ids, victim));
        }
    }
    const expected: [600]u8 = @splat('v');
    try testGet(&db, "a", &expected);
    try testGet(&db, "z", &expected);
    try db.close();
    var reopened = try Db.open(allocator, io, tmp.dir, options);
    defer reopened.deinit();
    try testGet(&reopened, "a", &expected);
    try testGet(&reopened, "z", &expected);
}
