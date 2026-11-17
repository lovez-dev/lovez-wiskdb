const std = @import("std");
const Db = @import("db.zig").Db;
const mf = @import("manifest/format.zig");
const ik = @import("util/internal_key.zig");
const ivfmt = @import("util/internal_value.zig");
const Lookup = union(enum) { miss, deleted, value: []const u8 };
const ReadVersion = @import("manifest/read_version.zig").ReadVersion;

/// No slices point into inline storage: returning a View by value is safe.
const CandidateFiles = struct {
    inline_ids: [8]u64 = undefined,
    len: usize = 0,
    overflow: std.ArrayListUnmanaged(u64) = .empty,

    fn append(self: *CandidateFiles, allocator: std.mem.Allocator, id: u64) !void {
        if (self.len < self.inline_ids.len) {
            self.inline_ids[self.len] = id;
        } else if (self.len == self.inline_ids.len) {
            try self.overflow.ensureUnusedCapacity(allocator, self.inline_ids.len + 1);
            self.overflow.appendSliceAssumeCapacity(&self.inline_ids);
            self.overflow.appendAssumeCapacity(id);
        } else {
            try self.overflow.append(allocator, id);
        }
        self.len += 1;
    }

    fn items(self: *const CandidateFiles) []const u64 {
        return if (self.len <= self.inline_ids.len) self.inline_ids[0..self.len] else self.overflow.items;
    }

    fn deinit(self: *CandidateFiles, allocator: std.mem.Allocator) void {
        self.overflow.deinit(allocator);
    }
};

test "candidate files: inline storage needs no allocation and moves without borrowed slices" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var files = CandidateFiles{};
    defer files.deinit(std.testing.allocator);
    for (0..8) |id| try files.append(failing.allocator(), id);
    const moved = files;
    files.inline_ids[0] = 99;
    try std.testing.expectEqual(@as(u64, 0), moved.items()[0]);
    try std.testing.expectEqual(@as(usize, 8), moved.items().len);
    try std.testing.expectError(error.OutOfMemory, files.append(failing.allocator(), 8));
    try std.testing.expectEqual(@as(usize, 8), files.items().len);
    try files.append(std.testing.allocator, 8);
    try std.testing.expectEqual(@as(u64, 99), files.items()[0]);
    try std.testing.expectEqual(@as(u64, 8), files.items()[8]);
}

fn growCandidates(allocator: std.mem.Allocator) !void {
    var files = CandidateFiles{};
    defer files.deinit(allocator);
    for (0..80) |id| try files.append(allocator, id);
    for (files.items(), 0..) |id, i| try std.testing.expectEqual(@as(u64, @intCast(i)), id);
}

test "candidate files: overflow preserves search order and frees failed growth allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, growCandidates, .{});
}

/// A per-get snapshot, captured while the database write mutex is held.
/// Only pinned immutable entry bytes and metadata escape that mutex.
pub const View = struct {
    snapshot: u64,
    files: CandidateFiles = .{},
    mem_value: ?[]const u8 = null,
    mem_holder: ?*@import("memtable/memtable.zig").MemTable.Holder = null,
    deleted: bool = false,
    version: ?*ReadVersion.Holder = null,
    files_prepared: bool = false,

    /// Caller holds write_mutex. Capturing allocates nothing and owns one
    /// active-read pin plus either a MemTable or immutable-version reference.
    pub fn captureLocked(db: *Db, key: []const u8) !View {
        var view = View{ .snapshot = db.last_seq.load(.acquire) };
        if (db.memtables.acquireEntry(key, view.snapshot)) |found| {
            view.mem_holder = found.holder;
            view.deleted = found.entry.deleted;
            if (!found.entry.deleted) view.mem_value = found.entry.value;
            _ = db.active_reads.fetchAdd(1, .acq_rel);
            return view;
        }
        db.read_version.acquire();
        view.version = db.read_version;
        _ = db.active_reads.fetchAdd(1, .acq_rel);
        return view;
    }

    /// The immutable version and active read pin were captured together.
    /// Selection and overflow allocation require no database write lock.
    pub fn prepareFiles(self: *View, db: *Db, key: []const u8) !void {
        if (self.files_prepared or self.version == null) return;
        var files = CandidateFiles{};
        errdefer files.deinit(db.internal_allocator);
        const vs = &self.version.?.data.vs;
        const l0 = if (vs.by_level.get(0)) |list| list.items else &.{};
        for (0..l0.len) |i| {
            const file = l0[l0.len - 1 - i];
            if (file.min_seq > self.snapshot or std.mem.order(u8, key, file.smallest) == .lt or std.mem.order(u8, key, file.largest) == .gt) continue;
            try files.append(db.internal_allocator, file.file_id);
        }
        var previous: u32 = 0;
        while (true) {
            var next_level: ?u32 = null;
            for (vs.by_level.keys()) |level| {
                if (level > previous and (next_level == null or level < next_level.?)) next_level = level;
            }
            previous = next_level orelse break;
            const file = vs.findRange(previous, key) orelse continue;
            if (file.min_seq <= self.snapshot) try files.append(db.internal_allocator, file.file_id);
        }
        self.files = files;
        self.files_prepared = true;
    }

    pub fn deinit(self: *View, db: *Db) void {
        self.files.deinit(db.internal_allocator);
        if (self.mem_holder) |holder| holder.release();
        if (self.version) |version| version.release();
        // Captures increment under write_mutex; reclamation checks zero under
        // that same mutex. A departing view never accesses files after this RMW.
        const previous = db.active_reads.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous == 1 and db.retired_tables_pending.load(.acquire)) {
            var guard = db.view_release_profile.lock(&db.write_mutex, db.io);
            defer guard.unlock();
            @import("runtime.zig").reclaimTablesLocked(db);
        }
        self.* = undefined;
    }

    /// No database write mutex is held during SST or VLog I/O.
    pub fn get(self: *View, db: *Db, key: []const u8) !?[]const u8 {
        if (self.deleted) return null;
        if (self.mem_value) |iv| return try db.valueFromIv(iv, key);
        try self.prepareFiles(db, key);
        if (self.files.len == 0) return null;
        var target_buffer: [256]u8 = undefined;
        const target_len = try std.math.add(usize, key.len, ik.suffix_len);
        const target = if (target_len <= target_buffer.len) target_buffer[0..target_len] else try db.internal_allocator.alloc(u8, target_len);
        defer if (target_len > target_buffer.len) db.internal_allocator.free(target);
        _ = try ik.encode(key, self.snapshot, .put, target);
        for (self.files.items()) |file_id| {
            switch (try readFile(db, file_id, target, key)) {
                .miss => continue,
                .deleted => return null,
                .value => |value| return value,
            }
        }
        return null;
    }
};

fn readFile(db: *Db, file_id: u64, target: []const u8, key: []const u8) !Lookup {
    const table = try db.tables.acquire(db.sst_dir, file_id);
    defer table.release();
    const Decode = struct {
        db: *Db,
        key: []const u8,
        fn value(ctx: @This(), iv: []const u8) !Lookup {
            const header = ivfmt.Header.decode(iv) catch return error.SSTableCorrupted;
            if (header.isDeleted()) return .deleted;
            return .{ .value = try ctx.db.valueFromIv(iv, ctx.key) };
        }
    };
    return (try table.data.getWith(Lookup, target, Decode{ .db = db, .key = key }, Decode.value)) orelse .miss;
}

test "get: reopened SST values and tombstones remain visible" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try Db.open(alloc, std.testing.io, tmp.dir, .{});
        defer db.deinit();
        try db.put("inline", "value");
        const big: [600]u8 = @splat('x');
        try db.put("pointer", &big);
        try db.put("deleted", "old");
        try db.delete("deleted");
    }
    var db = try Db.open(alloc, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    const small = (try db.get("inline")) orelse return error.TestUnexpectedResult;
    defer alloc.free(small);
    try std.testing.expectEqualStrings("value", small);
    const large = (try db.get("pointer")) orelse return error.TestUnexpectedResult;
    defer alloc.free(large);
    const expected: [600]u8 = @splat('x');
    try std.testing.expectEqualSlices(u8, &expected, large);
    try std.testing.expect((try db.get("deleted")) == null);
    try std.testing.expect((try db.get("missing")) == null);
}

test "read views: pinned memtable entries survive overwrite flush and GC without capture allocation" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    for ([_]usize{ 5, 600 }) |size| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var db = try Db.open(alloc, io, tmp.dir, .{
            .durability = .async,
            .automatic_gc = false,
            .l0_compaction_trigger = 2,
        });
        defer db.deinit();
        const original: [600]u8 = @splat('o');
        try db.put("key", original[0..size]);
        var view = blk: {
            db.write_mutex.lockUncancelable(io);
            defer db.write_mutex.unlock(io);
            var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
            db.allocator = failing.allocator();
            defer db.allocator = alloc;
            break :blk try View.captureLocked(&db, "key");
        };
        defer view.deinit(&db);
        const holder = view.mem_holder.?;
        try std.testing.expectEqual(@as(u32, 2), holder.refCount());
        try db.put("key", "replacement");
        try db.flush();
        try db.put("other", "value");
        try db.flush();
        try db.collectGarbage();
        try std.testing.expectEqual(@as(u32, 1), holder.refCount());
        const old = (try view.get(&db, "key")).?;
        defer alloc.free(old);
        try std.testing.expectEqualStrings(original[0..size], old);
        const current = (try db.get("key")).?;
        defer alloc.free(current);
        try std.testing.expectEqualStrings("replacement", current);
    }
}

test "read views: failed memtable result allocation releases its holder and active pin" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(alloc, std.testing.io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer db.deinit();
    try db.put("key", "value");
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    {
        db.allocator = failing.allocator();
        defer db.allocator = alloc;
        try std.testing.expectError(error.OutOfMemory, db.get("key"));
    }
    try std.testing.expectEqual(@as(u32, 1), db.memtables.current.refCount());
    try std.testing.expectEqual(@as(usize, 0), db.active_reads.load(.acquire));
}

test "read lock profiles: opt in counters match point lookup paths" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |enabled| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var db = try Db.open(alloc, std.testing.io, tmp.dir, .{
            .durability = .async,
            .automatic_gc = false,
            .profile_read_locks = enabled,
            .block_cache_shards = 4,
        });
        defer db.deinit();
        try db.put("key", "value");
        try db.flush();
        for (0..2) |_| {
            const got = (try db.get("key")).?;
            defer alloc.free(got);
            try std.testing.expectEqualStrings("value", got);
        }
        try std.testing.expect((try db.get("zzz")) == null);
        const stats = db.readLockStats();
        try std.testing.expectEqual(@as(u64, if (enabled) 3 else 0), stats.view_capture.acquisitions);
        try std.testing.expectEqual(@as(u64, 0), stats.view_release.acquisitions);
        try std.testing.expectEqual(@as(u64, if (enabled) 3 else 0), stats.table_cache.acquisitions);
        try std.testing.expectEqual(@as(u64, if (enabled) 2 else 0), stats.block_lookup.acquisitions);
        try std.testing.expectEqual(@as(u64, if (enabled) 1 else 0), stats.block_insert.acquisitions);
        try std.testing.expectEqual(@as(u64, if (enabled) 2 else 0), stats.block_release.acquisitions);
        try std.testing.expectEqualDeep(stats, db.readLockStats());
    }
}

test "read views: capture and lookup allocation failures release reclamation pins" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(alloc, std.testing.io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer db.deinit();
    try db.put("key", "value");
    try db.flush();
    const warm = (try db.get("key")).?;
    alloc.free(warm);
    db.worker.waitIdle();
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    {
        db.allocator = failing.allocator();
        defer db.allocator = alloc;
        try std.testing.expectError(error.OutOfMemory, db.get("key"));
    }
    try std.testing.expectEqual(@as(usize, 0), db.active_reads.load(.acquire));
    // A warm short-key inline SST lookup needs only the owned user result
    // from Db.allocator; neither the target nor InternalValue is copied here.
    var one_allocation = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 1 });
    {
        db.allocator = one_allocation.allocator();
        defer db.allocator = alloc;
        const result = (try db.get("key")).?;
        defer db.allocator.free(result);
        try std.testing.expectEqualStrings("value", result);
    }
    const got = (try db.get("key")).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("value", got);
}

test "get: stack target boundary and long-key allocation fallback preserve results" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(alloc, std.testing.io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer db.deinit();
    const key: [1024]u8 = @splat('k');
    for ([_]usize{ 256 - ik.suffix_len, 257 - ik.suffix_len, 1024 }) |len| try db.put(key[0..len], "value");
    try db.flush();
    for ([_]usize{ 256 - ik.suffix_len, 257 - ik.suffix_len, 1024 }) |len| {
        const got = (try db.get(key[0..len])).?;
        defer alloc.free(got);
        try std.testing.expectEqualStrings("value", got);
    }
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    {
        db.allocator = failing.allocator();
        defer db.allocator = alloc;
        try std.testing.expectError(error.OutOfMemory, db.get(&key));
    }
    try std.testing.expectEqual(@as(usize, 0), db.active_reads.load(.acquire));
}

test "read views: lock-free candidate preparation failures can retry and release version pins" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(alloc, std.testing.io, tmp.dir, .{
        .durability = .async,
        .automatic_gc = false,
        .l0_compaction_trigger = 100,
    });
    defer db.deinit();
    for (0..10) |i| {
        const value: [1]u8 = .{@intCast('a' + i)};
        try db.put("key", &value);
        try db.flush();
    }
    db.worker.waitIdle();
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    {
        db.allocator = failing.allocator();
        defer db.allocator = alloc;
        try std.testing.expectError(error.OutOfMemory, db.get("key"));
    }
    try std.testing.expectEqual(@as(usize, 0), db.active_reads.load(.acquire));
    var view = blk: {
        db.write_mutex.lockUncancelable(db.io);
        defer db.write_mutex.unlock(db.io);
        break :blk try View.captureLocked(&db, "key");
    };
    defer view.deinit(&db);
    const version = view.version.?;
    try std.testing.expectEqual(@as(u32, 2), version.refCount());
    try std.testing.expectEqual(@as(usize, 0), view.files.len);
    var retry_failure = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    {
        const saved = db.internal_allocator;
        db.internal_allocator = retry_failure.allocator();
        defer db.internal_allocator = saved;
        try std.testing.expectError(error.OutOfMemory, view.prepareFiles(&db, "key"));
    }
    try std.testing.expect(!view.files_prepared);
    try std.testing.expectEqual(@as(usize, 0), view.files.len);
    try std.testing.expectEqual(@as(usize, 1), db.active_reads.load(.acquire));
    try view.prepareFiles(&db, "key");
    try std.testing.expectEqual(@as(usize, 10), view.files.len);
    const got = (try view.get(&db, "key")).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("j", got);
}

test "get: overlapping levels use level order regardless of insertion order" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    for ([_]u32{ 3, 1, 2 }) |level| {
        var builder = try @import("sstable/table_builder.zig").TableBuilder.init(alloc, .{});
        defer builder.deinit();
        var keybuf: [32]u8 = undefined;
        var iv: [22]u8 = @splat(0);
        iv[0] = 0b010;
        std.mem.writeInt(u32, iv[1..5], 1, .little);
        iv[21] = @intCast('0' + level);
        const len = try ik.encode("key", 4 - level, .put, &keybuf);
        try builder.add(keybuf[0..len], &iv);
        const image = try builder.finish();
        var namebuf: [32]u8 = undefined;
        const id: u64 = 90 + level;
        const name = try std.fmt.bufPrint(&namebuf, "{d:0>6}.sst", .{id});
        const file = try db.sst_dir.createFile(io, name, .{ .read = true, .exclusive = true });
        defer file.close(io);
        try @import("io/io.zig").pwriteAll(file, io, image, 0);
        const adds = [_]mf.FileMeta{.{ .level = level, .file_id = id, .file_size = image.len, .smallest = "key", .largest = "key", .min_seq = 4 - level, .max_seq = 4 - level, .vlog_ids = "" }};
        try db.vs.apply(&.{ .adds = &adds });
    }
    db.last_seq.store(3, .release);
    const version = try ReadVersion.create(&db.vs);
    db.read_version.release();
    db.read_version = version;
    const got = (try db.get("key")).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("1", got);
}

test "get: cached external values retain ownership identity and latest-version visibility" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    var db = try Db.open(alloc, std.testing.io, tmp.dir, .{ .durability = .async, .automatic_gc = false, .block_cache_size = 64 * 1024 });
    defer db.deinit();
    const old: [1024]u8 = @splat('a');
    const fresh: [1024]u8 = @splat('b');
    try db.put("key", &old);
    const iv = db.memtables.current.data.get("key", db.last_seq.load(.acquire)).?;
    var saved: [21]u8 = undefined;
    @memcpy(&saved, iv);
    const first = (try db.get("key")).?;
    defer alloc.free(first);
    const before = db.tables.block_cache.stats();
    const second = (try db.get("key")).?;
    defer alloc.free(second);
    try std.testing.expect(first.ptr != second.ptr);
    try std.testing.expectEqualSlices(u8, &old, second);
    try std.testing.expect(db.tables.block_cache.stats().hits > before.hits);
    try std.testing.expectError(error.VLogCorrupted, db.valueFromIv(&saved, "bad"));
    std.mem.writeInt(u32, saved[1..5], 1023, .little);
    try std.testing.expectError(error.VLogCorrupted, db.valueFromIv(&saved, "key"));
    try db.put("key", &fresh);
    const latest = (try db.get("key")).?;
    defer alloc.free(latest);
    try std.testing.expectEqualSlices(u8, &fresh, latest);
    try db.delete("key");
    try std.testing.expect((try db.get("key")) == null);
    try std.testing.expectEqualSlices(u8, &old, first);
}
