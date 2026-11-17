const std = @import("std");
const Db = @import("db.zig").Db;
const disk = @import("io/io.zig");

fn expectValue(db: *Db, key: []const u8, expected: []const u8) !void {
    const value = (try db.get(key)) orelse return error.TestUnexpectedResult;
    defer db.allocator.free(value);
    try std.testing.expectEqualSlices(u8, expected, value);
}

fn countFiles(db: *Db) !void {
    var live: usize = 0;
    for (db.vs.by_level.values()) |files| live += files.items.len;
    var entries = db.sst_dir.iterate();
    var actual: usize = 0;
    while (try entries.next(db.io)) |entry| if (entry.kind == .file) {
        actual += 1;
    };
    try std.testing.expectEqual(live, actual);
}

fn expectRetainedOutput(db: *Db) !void {
    var live: usize = 0;
    for (db.vs.by_level.values()) |files| live += files.items.len;
    var entries = db.sst_dir.iterate();
    var actual: usize = 0;
    while (try entries.next(db.io)) |entry| if (entry.kind == .file) {
        actual += 1;
    };
    try std.testing.expect(actual > live);
}

const ManifestFault = struct {
    handle: disk.File.Handle,

    fn arm(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        disk.TestWrite.target = self.handle;
        disk.TestWrite.calls = 0;
        disk.TestWrite.fail_at = 0;
    }

    fn disarm(_: *anyopaque) void {
        disk.TestWrite.target = null;
        disk.TestWrite.fail_at = std.math.maxInt(usize);
    }
};

fn armManifestFault(db: *Db, fault: *ManifestFault) !void {
    fault.* = .{ .handle = db.manifest_writer.file.handle };
    try db.worker.submit(.{ .run = ManifestFault.arm, .ctx = fault });
}

fn disarmManifestFault(db: *Db, fault: *ManifestFault) void {
    if (!db.closed and !db.closing) {
        db.worker.submit(.{ .run = ManifestFault.disarm, .ctx = fault }) catch unreachable;
        db.worker.waitIdle();
        return;
    }
    ManifestFault.disarm(fault);
}

test "grouped batches: mixed fallback and rotation survive reopen" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(alloc, io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer db.deinit();
    const value: [1024]u8 = @splat('v');
    const puts = [_]@import("db.zig").Op{
        .{ .put = .{ .key = "a", .value = &value } },
        .{ .put = .{ .key = "b", .value = &value } },
    };
    try db.writeBatch(&puts);
    // Repeated keys span several groups; the last sequence must win after replay.
    var many: [1024]@import("db.zig").Op = undefined;
    const newer: [1024]u8 = @splat('n');
    for (&many, 0..) |*op, i| op.* = .{ .put = .{ .key = "repeated", .value = if (i == many.len - 1) &newer else &value } };
    try db.writeBatch(&many);
    try expectValue(&db, "repeated", &newer);
    try db.writeBatch(&puts);
    try db.writeBatch(&.{ .{ .del = "a" }, .{ .put = .{ .key = "small", .value = "inline" } }, .{ .put = .{ .key = "c", .value = &value } } });
    // A late delete or inline value disables VLog grouping for the whole batch.
    var mixed: [300]@import("db.zig").Op = undefined;
    var mixed_keys: [298][8]u8 = undefined;
    for (&mixed, 0..) |*op, i| {
        if (i >= mixed_keys.len) break;
        std.mem.writeInt(u64, &mixed_keys[i], 1000 + i, .big);
        op.* = .{ .put = .{ .key = &mixed_keys[i], .value = &value } };
    }
    mixed[298] = .{ .del = "b" };
    mixed[299] = .{ .put = .{ .key = "tail-inline", .value = "inline" } };
    try db.writeBatch(&mixed);
    try std.testing.expect((try db.get("b")) == null);
    try db.close();
    var again = try Db.open(alloc, io, tmp.dir, .{ .automatic_gc = false });
    defer again.deinit();
    try std.testing.expect((try again.get("a")) == null);
    try std.testing.expect((try again.get("b")) == null);
    try expectValue(&again, "c", &value);
    try expectValue(&again, "small", "inline");
    try expectValue(&again, "tail-inline", "inline");
    try expectValue(&again, "repeated", &newer);
}
test "mixed batches: external runs preserve operation order after reopen" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(alloc, io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer db.deinit();
    const large_a: [1024]u8 = @splat('a');
    const large_b: [1024]u8 = @splat('b');
    try db.writeBatch(&.{
        .{ .put = .{ .key = "first", .value = &large_a } },
        .{ .put = .{ .key = "switch", .value = "inline-old" } },
        .{ .put = .{ .key = "second", .value = &large_b } },
        .{ .del = "first" },
        .{ .put = .{ .key = "first", .value = &large_b } },
        .{ .del = "switch" },
        .{ .put = .{ .key = "switch", .value = "inline-final" } },
    });
    try expectValue(&db, "first", &large_b);
    try expectValue(&db, "second", &large_b);
    try expectValue(&db, "switch", "inline-final");
    var fragmented: [514]@import("db.zig").Op = undefined;
    var fragment_keys: [257][8]u8 = undefined;
    for (0..257) |i| {
        std.mem.writeInt(u64, &fragment_keys[i], 2000 + i, .big);
        fragmented[2 * i] = .{ .put = .{ .key = &fragment_keys[i], .value = &large_a } };
        fragmented[2 * i + 1] = .{ .put = .{ .key = "separator", .value = "x" } };
    }
    try db.writeBatch(&fragmented);
    try expectValue(&db, &fragment_keys[256], &large_a);
    try expectValue(&db, "separator", "x");
    try db.close();
    var reopened = try Db.open(alloc, io, tmp.dir, .{ .automatic_gc = false });
    defer reopened.deinit();
    try expectValue(&reopened, "first", &large_b);
    try expectValue(&reopened, "second", &large_b);
    try expectValue(&reopened, "switch", "inline-final");
    try expectValue(&reopened, &fragment_keys[256], &large_a);
    try expectValue(&reopened, "separator", "x");
}
test "read views: old SST and VLog values survive overwrite compaction and GC" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    for ([_]usize{ 8, 600 }) |size| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var db = try Db.open(alloc, io, tmp.dir, .{
            .durability = .async,
            .automatic_gc = false,
            .l0_compaction_trigger = 100,
        });
        defer db.deinit();
        const old: [600]u8 = @splat('a');
        const newer: [600]u8 = @splat('b');
        try db.put("key", old[0..size]);
        try db.flush();
        const old_vlog = db.vlog.writer.file_id;
        {
            var view = blk: {
                db.write_mutex.lockUncancelable(io);
                defer db.write_mutex.unlock(io);
                break :blk try @import("read.zig").View.captureLocked(&db, "key");
            };
            defer view.deinit(&db);
            try std.testing.expectEqual(@as(usize, 1), db.active_reads.load(.acquire));
            try std.testing.expectEqual(@as(usize, 0), view.files.len);
            const old_version = view.version.?;
            try std.testing.expectEqual(@as(usize, 1), old_version.data.vs.fileCount(0));
            try db.put("key", newer[0..size]);
            try db.flush();
            db.options.l0_compaction_trigger = 2;
            try db.collectGarbage();
            try std.testing.expect(old_version != db.read_version);
            try std.testing.expect(db.obsolete_ssts.items.len != 0);
            // The view has not opened the old SST until AFTER its replacement.
            const got = (try view.get(&db, "key")).?;
            defer alloc.free(got);
            try std.testing.expectEqualSlices(u8, old[0..size], got);
            try expectValue(&db, "key", newer[0..size]);
            if (size == 600) {
                var name: [32]u8 = undefined;
                const file = try db.vlog_dir.openFile(io, try std.fmt.bufPrint(&name, "{d:0>6}.vlog", .{old_vlog}), .{});
                file.close(io);
            }
        }
        try std.testing.expectEqual(@as(usize, 0), db.active_reads.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), db.obsolete_ssts.items.len);
        try db.collectGarbage();
        try countFiles(&db);
        try expectValue(&db, "key", newer[0..size]);
        if (size == 600) {
            var name: [32]u8 = undefined;
            try std.testing.expectError(error.FileNotFound, db.vlog_dir.openFile(io, try std.fmt.bufPrint(&name, "{d:0>6}.vlog", .{old_vlog}), .{}));
        }
    }
}

test "read views: captured MemTable bytes and tombstones outlive flush" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(alloc, io, tmp.dir, .{ .durability = .async });
    defer db.deinit();
    try db.put("key", "old");
    var value_view = blk: {
        db.write_mutex.lockUncancelable(io);
        defer db.write_mutex.unlock(io);
        break :blk try @import("read.zig").View.captureLocked(&db, "key");
    };
    defer value_view.deinit(&db);
    try db.delete("key");
    var tombstone_view = blk: {
        db.write_mutex.lockUncancelable(io);
        defer db.write_mutex.unlock(io);
        break :blk try @import("read.zig").View.captureLocked(&db, "key");
    };
    defer tombstone_view.deinit(&db);
    try db.put("key", "new");
    try db.flush();
    const old = (try value_view.get(&db, "key")).?;
    defer alloc.free(old);
    try std.testing.expectEqualStrings("old", old);
    try std.testing.expect((try tombstone_view.get(&db, "key")) == null);
    try expectValue(&db, "key", "new");
}

test "read views: only the final old view triggers pending table reclamation" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(alloc, io, tmp.dir, .{
        .durability = .async,
        .automatic_gc = false,
        .l0_compaction_trigger = 100,
        .profile_read_locks = true,
        .block_cache_shards = 4,
    });
    defer db.deinit();
    try db.put("key", "old");
    try db.flush();
    const View = @import("read.zig").View;
    var views: [2]View = undefined;
    var held: usize = 0;
    defer while (held > 0) {
        held -= 1;
        views[held].deinit(&db);
    };
    for (&views) |*view| {
        db.write_mutex.lockUncancelable(io);
        defer db.write_mutex.unlock(io);
        view.* = try View.captureLocked(&db, "key");
        held += 1;
    }
    try db.put("key", "new");
    try db.flush();
    db.options.l0_compaction_trigger = 2;
    try db.collectGarbage();
    try std.testing.expect(db.retired_tables_pending.load(.acquire));
    held -= 1;
    views[held].deinit(&db);
    try std.testing.expectEqual(@as(u64, 0), db.readLockStats().view_release.acquisitions);
    try std.testing.expect(db.obsolete_ssts.items.len > 0);
    const old = (try views[0].get(&db, "key")).?;
    defer alloc.free(old);
    try std.testing.expectEqualStrings("old", old);
    held -= 1;
    views[held].deinit(&db);
    try std.testing.expectEqual(@as(u64, 1), db.readLockStats().view_release.acquisitions);
    try std.testing.expect(!db.retired_tables_pending.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), db.obsolete_ssts.items.len);
    try expectValue(&db, "key", "new");
    try std.testing.expectEqual(@as(u64, 1), db.readLockStats().view_release.acquisitions);
}

test "maintenance: automatic multi-level compaction retires inputs and preserves updates" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try Db.open(alloc, io, tmp.dir, .{
            .write_buffer_size = 128,
            .max_sst_file_size = 300,
            .l0_compaction_trigger = 2,
            .automatic_gc = false,
        });
        defer db.deinit();
        for (0..30) |i| {
            var buf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&buf, "key{d:0>3}", .{i});
            try db.put(key, "old");
            // Populate cache entries before automatic retirement.
            try expectValue(&db, key, "old");
        }
        for (0..30) |i| {
            var buf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&buf, "key{d:0>3}", .{i});
            if (i % 2 == 0) try db.delete(key) else try db.put(key, "new");
        }
        try db.flush();
        try std.testing.expect(db.vs.fileCount(0) < 2);
        try std.testing.expect(db.vs.fileCount(1) + db.vs.fileCount(2) + db.vs.fileCount(3) != 0);
        try countFiles(&db);
    }
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    for (0..30) |i| {
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "key{d:0>3}", .{i});
        if (i % 2 == 0) try std.testing.expect((try db.get(key)) == null) else try expectValue(&db, key, "new");
    }
}

test "durability: sync, interval, async and explicit sync have distinct watermarks" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_]@import("db.zig").Durability{ .sync, .interval, .async }) |mode| {
        var db = try Db.open(alloc, io, tmp.dir, .{ .durability = mode, .sync_interval_ns = std.time.ns_per_hour });
        defer db.deinit();
        const before = db.durable_seq.load(.acquire);
        try db.put("durability", "value");
        if (mode == .sync) {
            try std.testing.expectEqual(db.last_seq.load(.acquire), db.durable_seq.load(.acquire));
        } else {
            try std.testing.expectEqual(before, db.durable_seq.load(.acquire));
        }
        try db.sync();
        try std.testing.expectEqual(db.last_seq.load(.acquire), db.durable_seq.load(.acquire));
    }
}

test "durability: interval timer syncs an idle database without another write" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .sync_interval_ns = 10 * std.time.ns_per_ms });
    defer db.deinit();
    try db.put("idle", "value");
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);
    const deadline: std.Io.Clock.Timestamp = .fromNow(db.io, .{ .clock = .awake, .raw = .{ .nanoseconds = 3 * std.time.ns_per_s } });
    while (db.durable_seq.load(.acquire) < db.last_seq.load(.acquire)) {
        try db.write_cond.waitTimeout(db.io, &db.write_mutex, .{ .deadline = deadline });
    }
}

test "durability: async rotation flushes without advancing the WAL watermark" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const options: @import("db.zig").Options = .{
        .durability = .async,
        .automatic_gc = false,
        .write_buffer_size = 1,
        .sync_interval_ns = std.time.ns_per_hour,
    };
    var db = try Db.open(alloc, io, tmp.dir, options);
    defer db.deinit();
    for (0..8) |i| {
        var keybuf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&keybuf, "key{d}", .{i});
        try db.put(key, "value");
    }
    db.worker.waitIdle();
    try std.testing.expect(db.background_error == null);
    try std.testing.expectEqual(@as(usize, 0), db.memtables.immutableCount());
    var sst_files: usize = 0;
    for (db.vs.by_level.values()) |files| sst_files += files.items.len;
    try std.testing.expect(sst_files > 0);
    try std.testing.expectEqual(@as(u64, 0), db.durable_seq.load(.acquire));
    try db.close();
    try std.testing.expectEqual(db.last_seq.load(.acquire), db.durable_seq.load(.acquire));
    var reopened = try Db.open(alloc, io, tmp.dir, options);
    defer reopened.deinit();
    for (0..8) |i| {
        var keybuf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&keybuf, "key{d}", .{i});
        try expectValue(&reopened, key, "value");
    }
}

test "close: flushes partial tables, is idempotent, and rejects later operations" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async });
    defer db.deinit();
    try db.put("partial", "saved");
    try db.close();
    try db.close();
    try std.testing.expectError(error.DbClosed, db.put("closed", "no"));
    try std.testing.expectError(error.DbClosed, db.get("partial"));
    try std.testing.expectError(error.DbClosed, db.flush());
    try std.testing.expectError(error.DbClosed, db.sync());
    var again = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer again.deinit();
    try expectValue(&again, "partial", "saved");
}

test "write: fragmented WAL batches reopen intact" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const value: [70000]u8 = @splat('x');
    {
        var db = try Db.open(alloc, io, tmp.dir, .{ .value_threshold = 100000 });
        defer db.deinit();
        try db.put("fragmented", &value);
        // Exercise recovery before a normal close flushes it: explicitly
        // inject a terminal failure so close retains this generation's WAL.
        db.write_mutex.lockUncancelable(io);
        db.background_error = error.WriteFailed;
        db.write_mutex.unlock(io);
        try std.testing.expectError(error.WriteFailed, db.close());
    }
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    try expectValue(&db, "fragmented", &value);
}

test "GC: relocates surviving values, commits pointers, deletes source, and reopens" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const value: [600]u8 = @splat('v');
    {
        var db = try Db.open(alloc, io, tmp.dir, .{
            .l0_compaction_trigger = 2,
            .automatic_gc = false,
            .gc_garbage_ratio = 0.4,
        });
        defer db.deinit();
        try db.put("survivor", &value);
        for (0..6) |_| try db.put("overwritten", &value);
        // Two explicit generations trigger compaction regardless of how
        // the worker coalesces automatic flushes. Stale SST pointers must
        // disappear before GC can classify the old VLog entries as garbage.
        try db.flush();
        try db.delete("overwritten");
        try db.flush();
        // Pin a cached VLog reader; GC must release its idle cache handle.
        try expectValue(&db, "survivor", &value);
        const old_id = db.vlog.writer.file_id;
        const before = db.last_seq.load(.acquire);
        try db.collectGarbage();
        try std.testing.expectEqual(before, db.last_seq.load(.acquire));
        try expectValue(&db, "survivor", &value);
        try std.testing.expect((try db.get("overwritten")) == null);
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "{d:0>6}.vlog", .{old_id});
        try std.testing.expectError(error.FileNotFound, db.vlog_dir.openFile(io, name, .{}));
        try countFiles(&db);
    }
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    try expectValue(&db, "survivor", &value);
    try std.testing.expect((try db.get("overwritten")) == null);
}

test "automatic GC: rotated logs with dead values are reclaimed without an explicit call" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const value = try alloc.alloc(u8, 400 * 1024);
    defer alloc.free(value);
    @memset(value, 'v');
    {
        var db = try Db.open(alloc, io, tmp.dir, .{
            .write_buffer_size = 1,
            .max_immutable_count = 1,
            .l0_compaction_trigger = 2,
            .vlog_file_size = 1 << 20,
            .gc_garbage_ratio = 0.4,
        });
        defer db.deinit();
        const source = db.vlog.writer.file_id;
        try db.put("survivor", value);
        for (0..3) |_| try db.put("hot", value);
        try db.flush();
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "{d:0>6}.vlog", .{source});
        try std.testing.expectError(error.FileNotFound, db.vlog_dir.openFile(io, name, .{}));
        try expectValue(&db, "survivor", value);
        try expectValue(&db, "hot", value);
    }
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    try expectValue(&db, "survivor", value);
    try expectValue(&db, "hot", value);
}

test "GC: unflushed WAL protects a sealed VLog even before SST references exist" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    const value: [600]u8 = @splat('x');
    try db.put("unflushed", &value);
    const source = db.vlog.writer.file_id;
    try std.testing.expect(db.vlog.replayableProtected(io, source, db.vs.log_number));
    db.write_mutex.lockUncancelable(io);
    try db.vlog.writer.rotate(io);
    db.vlog.next_id = db.vlog.writer.file_id + 1;
    db.vs.next_file_number = @max(db.vs.next_file_number, db.vlog.next_id);
    db.write_mutex.unlock(io);
    try db.worker.submit(.{ .run = @import("runtime.zig").run, .ctx = &db });
    db.worker.waitIdle();
    try std.testing.expect(db.background_error == null);
    try expectValue(&db, "unflushed", &value);
}

test "flush: failed manifest append retains the old version and recovery data" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try Db.open(alloc, io, tmp.dir, .{ .write_buffer_size = 1 });
        defer db.deinit();
        var fault: ManifestFault = undefined;
        try armManifestFault(&db, &fault);
        defer disarmManifestFault(&db, &fault);
        try db.put("retained", "value");
        db.worker.waitIdle();
        const failure = db.background_error orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 0), db.vs.fileCount(0));
        try std.testing.expectEqual(@as(usize, 1), db.memtables.immutableCount());
        try expectValue(&db, "retained", "value");
        try std.testing.expectError(failure, db.close());
    }
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    try expectValue(&db, "retained", "value");
}

test "flush: failed manifest append retains WAL and immutable data for recovery" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const large: [600]u8 = @splat('v');
    {
        var db = try Db.open(allocator, io, tmp.dir, .{
            .durability = .async,
            .automatic_gc = false,
            .l0_compaction_trigger = 100,
        });
        defer db.deinit();
        try db.put("inline", "value");
        try db.put("external", &large);
        try db.put("deleted", "old");
        try db.delete("deleted");
        db.worker.waitIdle();
        const old_log = db.log_number.load(.acquire);
        const old_wal = db.wal_id;
        {
            // The next positional write is the delta manifest append.
            var fault: ManifestFault = undefined;
            try armManifestFault(&db, &fault);
            defer disarmManifestFault(&db, &fault);
            try std.testing.expectError(error.InputOutput, db.flush());
        }
        try std.testing.expectEqual(@as(usize, 0), db.vs.fileCount(0));
        try std.testing.expectEqual(@as(usize, 1), db.memtables.immutableCount());
        try std.testing.expectEqual(old_log, db.log_number.load(.acquire));
        var wal_name: [32]u8 = undefined;
        const retained_name = try std.fmt.bufPrint(&wal_name, "{d:0>6}.wal", .{old_wal});
        const retained = try db.wal_dir.openFile(io, retained_name, .{});
        retained.close(io);
        var recovered = try @import("manifest/reader.zig").recover(allocator, io, tmp.dir);
        defer recovered.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), recovered.vs.fileCount(0));
        try expectValue(&db, "inline", "value");
        try expectValue(&db, "external", &large);
        try std.testing.expect((try db.get("deleted")) == null);
        try std.testing.expectError(error.InputOutput, db.put("later", "rejected"));
        try std.testing.expectError(error.InputOutput, db.close());
    }
    var reopened = try Db.open(allocator, io, tmp.dir, .{});
    defer reopened.deinit();
    try expectValue(&reopened, "inline", "value");
    try expectValue(&reopened, "external", &large);
    try std.testing.expect((try reopened.get("deleted")) == null);
}

test "compaction: failed manifest append retains outputs and committed inputs" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try Db.open(alloc, io, tmp.dir, .{ .l0_compaction_trigger = 100, .automatic_gc = false });
        defer db.deinit();
        try db.put("key", "old");
        try db.flush();
        try db.put("key", "new");
        try db.flush();
        db.options.l0_compaction_trigger = 2;
        var fault: ManifestFault = undefined;
        try armManifestFault(&db, &fault);
        defer disarmManifestFault(&db, &fault);
        try db.worker.submit(.{ .run = @import("runtime.zig").run, .ctx = &db });
        db.worker.waitIdle();
        const failure = db.background_error orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 2), db.vs.fileCount(0));
        try expectRetainedOutput(&db);
        try expectValue(&db, "key", "new");
        try std.testing.expectError(failure, db.close());
    }
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    try expectValue(&db, "key", "new");
}

test "open: recovery flush failure refuses to expose a database missing replayed data" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try Db.open(alloc, io, tmp.dir, .{ .durability = .sync });
        defer db.deinit();
        try db.put("key", "value");
        db.write_mutex.lockUncancelable(io);
        db.background_error = error.WriteFailed;
        db.write_mutex.unlock(io);
        try std.testing.expectError(error.WriteFailed, db.close());
    }
    // WAL 3 is newer than manifest 1; recovery reserves above it, drawing SST 4.
    try tmp.dir.createDirPath(io, "SST/000004.sst");
    try std.testing.expectError(error.RecoveryFlushFailed, Db.open(alloc, io, tmp.dir, .{}));
    try tmp.dir.deleteDir(io, "SST/000004.sst");
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    try expectValue(&db, "key", "value");
}

const StressWriter = struct {
    db: *Db,
    id: usize,
    failure: ?anyerror = null,
    fn run(ctx: *StressWriter) void {
        ctx.exercise() catch |err| {
            ctx.failure = err;
        };
    }
    fn exercise(ctx: *StressWriter) !void {
        var keybuf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&keybuf, "thread{d}", .{ctx.id});
        var value: [16384]u8 = undefined;
        for (0..32) |round| {
            @memset(&value, @intCast(round));
            try ctx.db.put(key, &value);
            try expectValue(ctx.db, key, &value);
            if (round % 8 == 7) {
                try ctx.db.delete(key);
                try std.testing.expect((try ctx.db.get(key)) == null);
            }
        }
    }
};

const SharedReader = struct {
    db: *Db,
    stop: *std.atomic.Value(bool),
    ready: *std.atomic.Value(usize),
    failure: ?anyerror = null,
    reads: usize = 0,

    fn run(ctx: *SharedReader) void {
        _ = ctx.ready.fetchAdd(1, .release);
        ctx.exercise() catch |err| {
            ctx.failure = err;
        };
    }

    fn exercise(ctx: *SharedReader) !void {
        while (!ctx.stop.load(.acquire)) {
            const value = try ctx.db.get("shared");
            if (value) |got| {
                defer ctx.db.allocator.free(got);
                try std.testing.expectEqual(@as(usize, 600), got.len);
                for (got) |byte| try std.testing.expectEqual(got[0], byte);
            }
            ctx.reads += 1;
        }
    }
};

test "read views: simultaneous readers see whole values during writes flushes and GC" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try Db.open(alloc, io, tmp.dir, .{
            .durability = .async,
            .automatic_gc = false,
            .write_buffer_size = 2048,
            .block_cache_shards = 4,
            .l0_compaction_trigger = 2,
        });
        defer db.deinit();
        var value: [600]u8 = @splat(0);
        try db.put("shared", &value);
        try db.flush();
        var stop = std.atomic.Value(bool).init(false);
        var ready = std.atomic.Value(usize).init(0);
        var readers: [3]SharedReader = undefined;
        var threads: [3]std.Thread = undefined;
        var started: usize = 0;
        {
            defer {
                stop.store(true, .release);
                for (threads[0..started]) |thread| thread.join();
            }
            for (&readers, 0..) |*reader, i| {
                reader.* = .{ .db = &db, .stop = &stop, .ready = &ready };
                threads[i] = try std.Thread.spawn(.{}, SharedReader.run, .{reader});
                started += 1;
            }
            while (ready.load(.acquire) != readers.len) std.atomic.spinLoopHint();
            for (1..25) |round| {
                @memset(&value, @intCast(round));
                try db.put("shared", &value);
                if (round % 3 == 0) try db.delete("shared");
                if (round % 6 == 0) try db.collectGarbage();
            }
        }
        for (readers) |reader| {
            if (reader.failure) |err| return err;
            try std.testing.expect(reader.reads > 0);
        }
        try std.testing.expectEqual(@as(usize, 0), db.active_reads.load(.acquire));
        try db.collectGarbage();
        try countFiles(&db);
        try std.testing.expect((try db.get("shared")) == null);
    }
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    try std.testing.expect((try db.get("shared")) == null);
}

test "stress: concurrent writes and reads remain consistent during compaction and GC" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try Db.open(alloc, io, tmp.dir, .{
            .write_buffer_size = 256,
            .max_immutable_count = 2,
            .l0_compaction_trigger = 2,
            .vlog_file_size = 1 << 20,
            .sync_interval_ns = std.time.ns_per_ms,
        });
        defer db.deinit();
        var writers: [3]StressWriter = undefined;
        var threads: [3]std.Thread = undefined;
        var started: usize = 0;
        {
            defer for (threads[0..started]) |thread| thread.join();
            for (&writers, 0..) |*writer, id| {
                writer.* = .{ .db = &db, .id = id };
                threads[id] = try std.Thread.spawn(.{}, StressWriter.run, .{writer});
                started += 1;
            }
        }
        for (writers) |writer| if (writer.failure) |err| return err;
        try db.flush();
        try countFiles(&db);
    }
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    for (0..3) |id| {
        var keybuf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&keybuf, "thread{d}", .{id});
        try std.testing.expect((try db.get(key)) == null);
    }
}

test "model: mixed updates, deletes, explicit GC, and repeated reopen match a reference map" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var model: [8]?u8 = @splat(null);
    var state: u64 = 20261113;
    for (0..4) |_| {
        var db = try Db.open(alloc, io, tmp.dir, .{
            .write_buffer_size = 512,
            .max_immutable_count = 2,
            .l0_compaction_trigger = 2,
            .max_sst_file_size = 512,
        });
        defer db.deinit();
        for (0..64) |step| {
            state = state *% 6364136223846793005 +% 1;
            const slot: usize = @intCast((state >> 32) % model.len);
            const tag: u8 = @intCast((state >> 48) & 255);
            const key: [1]u8 = .{@intCast('a' + slot)};
            if (tag % 4 == 0) {
                try db.delete(&key);
                model[slot] = null;
            } else {
                const value: [600]u8 = @splat(tag);
                try db.put(&key, &value);
                model[slot] = tag;
            }
            if (step % 32 == 31) try db.collectGarbage();
            if (step % 8 == 7) {
                for (model, 0..) |expected, i| {
                    const probe: [1]u8 = .{@intCast('a' + i)};
                    if (expected) |byte| {
                        const value: [600]u8 = @splat(byte);
                        try expectValue(&db, &probe, &value);
                    } else try std.testing.expect((try db.get(&probe)) == null);
                }
            }
        }
        try db.flush();
        try countFiles(&db);
    }
}

const Blocker = struct {
    io: std.Io,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    fn run(raw: *anyopaque) void {
        const blocker: *Blocker = @ptrCast(@alignCast(raw));
        blocker.entered.set(blocker.io);
        blocker.release.waitUncancelable(blocker.io);
    }
};

test "durability: interval synchronization continues while the maintenance worker is occupied" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, io, tmp.dir, .{ .sync_interval_ns = 10 * std.time.ns_per_ms });
    defer db.deinit();
    try db.put("first", "value");
    var blocker = Blocker{ .io = io };
    defer {
        blocker.release.set(io);
        db.worker.waitIdle();
    }
    try db.worker.submit(.{ .run = Blocker.run, .ctx = &blocker });
    try blocker.entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .{ .nanoseconds = 3 * std.time.ns_per_s } } });
    try db.put("while-compacting", "value");
    db.write_mutex.lockUncancelable(io);
    defer db.write_mutex.unlock(io);
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .{ .nanoseconds = 3 * std.time.ns_per_s } });
    while (db.durable_seq.load(.acquire) < db.last_seq.load(.acquire)) {
        try db.write_cond.waitTimeout(io, &db.write_mutex, .{ .deadline = deadline });
    }
}

test "GC: manifest append failure retains source pointers and rewritten outputs" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const value: [600]u8 = @splat('g');
    {
        var db = try Db.open(alloc, io, tmp.dir, .{ .l0_compaction_trigger = 2, .automatic_gc = false, .gc_garbage_ratio = 0.4 });
        defer db.deinit();
        try db.put("survivor", &value);
        for (0..5) |_| try db.put("hot", &value);
        // Remove stale SST references before injecting the GC commit failure.
        try db.flush();
        try db.delete("hot");
        try db.flush();
        const source = db.vlog.writer.file_id;
        // Seal the source, then fail the manifest append performed by GC.
        db.write_mutex.lockUncancelable(io);
        db.vlog.writer.next_file_id = db.vs.next_file_number;
        try db.vlog.writer.rotate(io);
        db.vlog.next_id = db.vlog.writer.file_id + 1;
        db.vs.next_file_number = @max(db.vs.next_file_number, db.vlog.next_id);
        var fault: ManifestFault = undefined;
        try armManifestFault(&db, &fault);
        defer disarmManifestFault(&db, &fault);
        try db.worker.submit(.{ .run = @import("runtime.zig").run, .ctx = &db });
        db.write_mutex.unlock(io);
        db.worker.waitIdle();
        const failure = db.background_error orelse return error.TestUnexpectedResult;
        try expectRetainedOutput(&db);
        try expectValue(&db, "survivor", &value);
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "{d:0>6}.vlog", .{source});
        const file = try db.vlog_dir.openFile(io, name, .{});
        file.close(io);
        try std.testing.expectError(failure, db.close());
    }
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    try expectValue(&db, "survivor", &value);
    try std.testing.expect((try db.get("hot")) == null);
}

test "durability: strict directory barriers reject unsupported hosts before creating files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    if (!disk.directory_sync_supported) {
        try std.testing.expectError(error.UnsupportedDirectorySync, Db.open(std.testing.allocator, io, tmp.dir, .{ .require_directory_sync = true }));
        var entries = tmp.dir.iterate();
        try std.testing.expect((try entries.next(io)) == null);
    } else {
        var db = try Db.open(std.testing.allocator, io, tmp.dir, .{ .require_directory_sync = true });
        defer db.deinit();
        try db.put("strict", "value");
        try db.close();
    }
}

test "durability: manifest fsync failure keeps compaction and GC outputs recoverable" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |gc| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const value: [600]u8 = @splat('v');
        {
            var db = try Db.open(alloc, io, tmp.dir, .{
                .l0_compaction_trigger = 100,
                .automatic_gc = false,
                .gc_garbage_ratio = 0.4,
            });
            defer db.deinit();
            try db.put("survivor", &value);
            for (0..5) |_| try db.put("hot", &value);
            try db.flush();
            try db.delete("hot");
            try db.flush();
            // A complete edit can be visible even though its fsync fails.
            // Inject on this thread while periodic syncing is idle.
            db.sync_worker.?.clearTimer();
            db.sync_worker.?.waitIdle();
            if (gc) {
                db.options.l0_compaction_trigger = 2;
                @import("runtime.zig").start(&db);
                db.options.l0_compaction_trigger = 100;
                try std.testing.expect(db.background_error == null);
                db.vlog.writer.next_file_id = db.vs.next_file_number;
                try db.vlog.writer.rotate(io);
                db.vlog.next_id = db.vlog.writer.file_id + 1;
                db.vs.next_file_number = @max(db.vs.next_file_number, db.vlog.next_id);
            } else db.options.l0_compaction_trigger = 2;
            {
                disk.TestSync.target = db.manifest_writer.file.handle;
                disk.TestSync.calls = 0;
                disk.TestSync.fail_at = 0;
                defer {
                    disk.TestSync.target = null;
                    disk.TestSync.fail_at = std.math.maxInt(usize);
                }
                @import("runtime.zig").run(&db);
                try std.testing.expectEqual(@as(usize, 1), disk.TestSync.calls);
            }
            try std.testing.expectEqual(error.InputOutput, db.background_error.?);
            var manifest = try @import("manifest/reader.zig").recover(alloc, io, tmp.dir);
            defer manifest.deinit(alloc);
            try std.testing.expectEqualStrings(db.manifest_name, manifest.manifest_name);
            for (manifest.vs.by_level.values()) |files| for (files.items) |file| {
                var namebuf: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&namebuf, "{d:0>6}.sst", .{file.file_id});
                const output = try db.sst_dir.openFile(io, name, .{});
                output.close(io);
            };
            try expectValue(&db, "survivor", &value);
            try std.testing.expectError(error.InputOutput, db.put("later", "rejected"));
            try std.testing.expectError(error.InputOutput, db.close());
        }
        var again = try Db.open(alloc, io, tmp.dir, .{});
        defer again.deinit();
        try expectValue(&again, "survivor", &value);
        try std.testing.expect((try again.get("hot")) == null);
    }
}

test "durability: failed WAL or VLog namespace barrier never advances the durable watermark" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |value_log| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const value: [600]u8 = @splat('v');
        {
            var db = try Db.open(alloc, io, tmp.dir, .{ .durability = .async });
            defer db.deinit();
            try db.put("recoverable", &value);
            db.worker.waitIdle();
            const before = db.durable_seq.load(.acquire);
            {
                disk.TestBarrier.target = if (value_log) db.vlog_dir.handle else db.wal_dir.handle;
                disk.TestBarrier.calls = 0;
                disk.TestBarrier.fail_at = 0;
                defer disk.TestBarrier.target = null;
                try std.testing.expectError(error.InputOutput, db.sync());
            }
            try std.testing.expectEqual(before, db.durable_seq.load(.acquire));
            try expectValue(&db, "recoverable", &value);
            try std.testing.expectError(error.InputOutput, db.close());
        }
        var again = try Db.open(alloc, io, tmp.dir, .{});
        defer again.deinit();
        try expectValue(&again, "recoverable", &value);
    }
}

test "durability: SST directory failure prevents its installation in a version" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const holder = try @import("memtable/memtable.zig").MemTable.create(alloc, 1);
    defer holder.release();
    var iv: [22]u8 = @splat(0);
    iv[0] = 0b010;
    std.mem.writeInt(u32, iv[1..5], 1, .little);
    iv[21] = 'v';
    try holder.data.put(1, "key", &iv);
    var version = @import("manifest/version_set.zig").VersionSet.init(alloc);
    defer version.deinit();
    {
        disk.TestBarrier.target = tmp.dir.handle;
        disk.TestBarrier.calls = 0;
        disk.TestBarrier.fail_at = 0;
        defer disk.TestBarrier.target = null;
        try std.testing.expectError(error.InputOutput, @import("flush.zig").flushMemtable(alloc, io, tmp.dir, &holder.data, &version));
    }
    try std.testing.expectEqual(@as(usize, 0), version.fileCount(0));
    try std.testing.expectEqualSlices(u8, &iv, holder.data.get("key", 1).?);
    const id = try @import("flush.zig").flushMemtable(alloc, io, tmp.dir, &holder.data, &version);
    try std.testing.expect(id != null);
    try std.testing.expectEqual(@as(usize, 1), version.fileCount(0));
}
