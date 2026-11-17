//! Captures all scan sources together; retains files until decoding completes.
const std = @import("std");
const Db = @import("db.zig").Db;
const MemTable = @import("memtable/memtable.zig").MemTable;
const ik = @import("util/internal_key.zig");
const tr = @import("sstable/table_reader.zig");
const PointView = @import("read.zig").View;

pub const View = struct {
    pin: PointView,
    tables: []*MemTable.Holder,

    pub fn capture(db: *Db) !View {
        var guard = db.view_capture_profile.lock(&db.write_mutex, db.io);
        defer guard.unlock();
        if (db.closing or db.closed) return error.DbClosed;
        db.startRuntime();
        // Writes and FIFO removals publish under write_mutex; count and acquire
        // therefore describe the same set, including the mutable table.
        const capacity = db.memtables.immutableCount() + 1;
        const tables = try db.internal_allocator.alloc(*MemTable.Holder, capacity);
        errdefer db.internal_allocator.free(tables);
        const count = db.memtables.acquireSet(tables);
        std.debug.assert(count == capacity);
        db.read_version.acquire();
        _ = db.active_reads.fetchAdd(1, .acq_rel);
        return .{ .tables = tables, .pin = .{
            .snapshot = db.last_seq.load(.acquire),
            .version = db.read_version,
        } };
    }

    pub fn deinit(self: *View, db: *Db) void {
        for (self.tables) |table| table.release();
        db.internal_allocator.free(self.tables);
        self.pin.deinit(db);
        self.* = undefined;
    }
};
/// Owned key/value bytes; Db.freeScan releases both fields and the result array.
pub const ScanItem = struct { key: []const u8, value: []const u8 };

/// User-key bounds apply before ordering/limit at one acknowledged snapshot.
/// Bounds are borrowed only during the scan; start >= end produces no rows.
pub const ScanOptions = struct {
    /// Inclusive byte-order lower bound; null starts at the first key.
    start: ?[]const u8 = null,
    /// Exclusive byte-order upper bound; null ends after the last key.
    end: ?[]const u8 = null,
    /// Descending user-key order with the same [start, end) bounds.
    reverse: bool = false,
    /// Maximum visible, non-deleted rows; zero is unlimited. This does not cap
    /// iterator/source buffers or the bytes in an individual key/value.
    limit: usize = 0,
};

const Source = struct {
    mem: ?MemTable.Iterator = null,
    sst: ?tr.TableReader.TableIter = null,
    key: []const u8 = &.{},
    value: []const u8 = &.{},
    holder: ?*tr.RcTable = null,

    fn refresh(self: *Source) void {
        if (!self.valid()) {
            self.key = &.{};
            self.value = &.{};
            return;
        }
        if (self.mem) |*it| {
            self.key = it.key();
            self.value = it.value();
        }
        if (self.sst) |*it| {
            self.key = it.key();
            self.value = it.value();
        }
    }
    fn valid(self: *const Source) bool {
        if (self.mem) |it| return it.valid();
        if (self.sst) |it| return it.valid();
        return false;
    }
    fn move(self: *Source, reverse: bool) !void {
        if (self.mem) |*it| {
            if (reverse) it.prev() else it.next();
        }
        if (self.sst) |*it| {
            if (reverse) try it.prev() else try it.next();
        }
        self.refresh();
    }
    fn deinit(self: *Source) void {
        if (self.sst) |*it| it.deinit();
        if (self.holder) |holder| holder.release();
    }
};

pub fn scan(db: *Db, start: ?[]const u8, end: ?[]const u8) ![]ScanItem {
    return scanWithOptions(db, .{ .start = start, .end = end });
}

pub fn scanWithOptions(db: *Db, options: ScanOptions) ![]ScanItem {
    var view = try View.capture(db);
    defer view.deinit(db);
    return scanCaptured(&view, db, options);
}

fn scanCaptured(view: *View, db: *Db, options: ScanOptions) ![]ScanItem {
    if (options.start) |start| if (options.end) |end| {
        if (std.mem.order(u8, start, end) != .lt) return db.allocator.alloc(ScanItem, 0);
    };
    const version = view.pin.version.?.data.vs;
    var capacity: usize = view.tables.len;
    for (version.by_level.values()) |files| capacity += files.items.len;
    const sources = try db.internal_allocator.alloc(Source, capacity);
    defer db.internal_allocator.free(sources);
    var count: usize = 0;
    defer for (sources[0..count]) |*source| source.deinit();
    for (view.tables) |table| {
        var it = table.data.iterator();
        if (options.reverse) {
            if (options.end) |end| it.seekBefore(end, std.math.maxInt(u64), .put) else it.seekToLast();
        } else if (options.start) |start| {
            it.seek(start, std.math.maxInt(u64), .put);
        } else it.seekToFirst();
        if (it.valid()) {
            sources[count] = .{ .mem = it };
            sources[count].refresh();
            count += 1;
        }
    }
    for (version.by_level.values()) |files| for (files.items) |file| {
        if (file.min_seq > view.pin.snapshot) continue;
        if (options.start) |start| if (std.mem.order(u8, file.largest, start) == .lt) continue;
        if (options.end) |end| if (std.mem.order(u8, file.smallest, end) != .lt) continue;
        const holder = try db.tables.acquire(db.sst_dir, file.file_id);
        const source = &sources[count];
        source.* = .{
            .sst = if (options.limit != 0) tr.TableReader.TableIter.initCached(&holder.data) else tr.TableReader.TableIter.init(&holder.data),
            .holder = holder,
        };
        count += 1;
        const it = &source.sst.?;
        const bound = if (options.reverse) options.end else options.start;
        if (bound) |user| {
            const target = try db.internal_allocator.alloc(u8, user.len + ik.suffix_len);
            defer db.internal_allocator.free(target);
            _ = try ik.encode(user, std.math.maxInt(u64), .put, target);
            if (options.reverse) try it.seekBefore(target) else try it.seek(target);
        } else if (options.reverse) try it.seekToLast() else try it.seekToFirst();
        source.refresh();
    };
    var out: std.ArrayListUnmanaged(ScanItem) = .empty;
    errdefer {
        for (out.items) |item| {
            db.allocator.free(item.key);
            db.allocator.free(item.value);
        }
        out.deinit(db.allocator);
    }
    while (true) {
        var selected: ?usize = null;
        for (sources[0..count], 0..) |*source, i| {
            if (!source.valid()) continue;
            if (selected == null or (if (options.reverse) ik.compare(sources[selected.?].key, source.key) == .lt else ik.compare(source.key, sources[selected.?].key) == .lt)) selected = i;
        }
        const first = selected orelse break;
        const decoded = try ik.decode(sources[first].key);
        if (options.start) |start| if (std.mem.order(u8, decoded.user, start) == .lt) break;
        if (options.end) |end| if (std.mem.order(u8, decoded.user, end) != .lt) {
            if (!options.reverse) break;
            try sources[first].move(true);
            continue;
        };
        // Iterators rebuild keys and release blocks when advancing. Own only
        // this user group and its current winner across those moves.
        const user = try db.internal_allocator.dupe(u8, decoded.user);
        defer db.internal_allocator.free(user);
        var winner: std.ArrayListUnmanaged(u8) = .empty;
        defer winner.deinit(db.internal_allocator);
        var best_seq: u64 = 0;
        var best_deleted = false;
        var have_best = false;
        for (sources[0..count]) |*source| {
            while (source.valid()) {
                const item = try ik.decode(source.key);
                if (!std.mem.eql(u8, item.user, user)) break;
                if (item.seq <= view.pin.snapshot and (!have_best or item.seq > best_seq or (item.seq == best_seq and item.kind == .delete))) {
                    best_seq = item.seq;
                    best_deleted = item.kind == .delete;
                    winner.clearRetainingCapacity();
                    if (!best_deleted) try winner.appendSlice(db.internal_allocator, source.value);
                    have_best = true;
                }
                try source.move(options.reverse);
            }
        }
        if (have_best and !best_deleted) {
            const key = try db.allocator.dupe(u8, user);
            errdefer db.allocator.free(key);
            const value = try db.valueFromIvAlloc(winner.items, user, db.allocator);
            errdefer db.allocator.free(value);
            try out.append(db.allocator, .{ .key = key, .value = value });
            if (options.limit != 0 and out.items.len >= options.limit) break;
        }
    }
    return out.toOwnedSlice(db.allocator);
}

pub fn freeItems(db: *Db, items: []ScanItem) void {
    for (items) |item| {
        db.allocator.free(item.key);
        db.allocator.free(item.value);
    }
    db.allocator.free(items);
}

test "scan: sorted bounded results merge SST and memory with VLog values" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    try db.put("b", "old");
    try db.put("c", "deleted");
    try db.flush();
    try db.put("b", "new");
    try db.delete("c");
    const big: [600]u8 = @splat('x');
    try db.put("d", &big);
    try db.put("z", "excluded");
    const items = try db.scan("b", "z");
    defer db.freeScan(items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("b", items[0].key);
    try std.testing.expectEqualStrings("new", items[0].value);
    try std.testing.expectEqualStrings("d", items[1].key);
    try std.testing.expectEqualSlices(u8, &big, items[1].value);
}

test "scan view: captures sources and sequence; closed database is rejected" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    try db.put("key", "before");
    {
        var view = try View.capture(&db);
        defer view.deinit(&db);
        const captured = view.pin.snapshot;
        try db.put("key", "after");
        try std.testing.expect(db.last_seq.load(.acquire) > captured);
        const snapshot_rows = try scanCaptured(&view, &db, .{});
        defer db.freeScan(snapshot_rows);
        try std.testing.expectEqual(@as(usize, 1), snapshot_rows.len);
        try std.testing.expectEqualStrings("key", snapshot_rows[0].key);
        try std.testing.expectEqualStrings("before", snapshot_rows[0].value);
        const current_rows = try db.scan(null, null);
        defer db.freeScan(current_rows);
        try std.testing.expectEqual(@as(usize, 1), current_rows.len);
        try std.testing.expectEqualStrings("after", current_rows[0].value);
        try std.testing.expect(view.tables.len > 0);
        try std.testing.expectEqual(@as(u32, 1), db.active_reads.load(.acquire));
        try std.testing.expect(view.pin.version != null);
    }
    try std.testing.expectEqual(@as(u32, 0), db.active_reads.load(.acquire));
    try db.close();
    try std.testing.expectError(error.DbClosed, View.capture(&db));
}

test "scan options: reverse limits, bounds, versions, tombstones and captured snapshot" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    try db.put("a", "a");
    try db.put("b", "old");
    try db.put("bb", "prefix");
    try db.put("c", "old-c");
    try db.put("d", "d");
    try db.flush();
    try db.put("b", "new");
    try db.delete("c");
    var view = try View.capture(&db);
    defer view.deinit(&db);
    try db.put("b", "future");
    try db.delete("d");
    try db.put("z", "future-z");
    const items = try scanCaptured(&view, &db, .{ .start = "b", .end = "z", .reverse = true, .limit = 2 });
    defer db.freeScan(items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("d", items[0].key);
    try std.testing.expectEqualStrings("bb", items[1].key);
    const ascending = try scanCaptured(&view, &db, .{ .start = "b", .end = "d", .limit = 1 });
    defer db.freeScan(ascending);
    try std.testing.expectEqual(@as(usize, 1), ascending.len);
    try std.testing.expectEqualStrings("b", ascending[0].key);
    try std.testing.expectEqualStrings("new", ascending[0].value);
    for ([_]bool{ false, true }) |reverse| {
        const empty = try db.scanWithOptions(.{ .start = "z", .end = "b", .reverse = reverse });
        defer db.freeScan(empty);
        try std.testing.expectEqual(@as(usize, 0), empty.len);
        const equal = try db.scanWithOptions(.{ .start = "b", .end = "b", .reverse = reverse });
        defer db.freeScan(equal);
        try std.testing.expectEqual(@as(usize, 0), equal.len);
        const all = try scanCaptured(&view, &db, .{ .reverse = reverse });
        defer db.freeScan(all);
        try std.testing.expectEqual(@as(usize, 4), all.len);
        try std.testing.expectEqualStrings(if (reverse) "d" else "a", all[0].key);
    }
}

test "scan options: reverse limit visits only final SST blocks" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer db.deinit();
    for (0..3000) |i| {
        var key: [16]u8 = undefined;
        try db.put(try std.fmt.bufPrint(&key, "key{d:0>4}", .{i}), "v");
    }
    try db.flush();
    var view = try View.capture(&db);
    defer view.deinit(&db);
    const file = view.pin.version.?.data.vs.by_level.values()[0].items[0];
    const holder = try db.tables.acquire(db.sst_dir, file.file_id);
    defer holder.release();
    const before = holder.data.bytes_read.load(.monotonic);
    const items = try scanCaptured(&view, &db, .{ .reverse = true, .limit = 1 });
    defer db.freeScan(items);
    try std.testing.expectEqualStrings("key2999", items[0].key);
    const read = holder.data.bytes_read.load(.monotonic) - before;
    try std.testing.expect(read < file.file_size / 2);
}

test "scan options: limited pages reuse cached blocks while unlimited scans bypass" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer db.deinit();
    for (0..200) |i| {
        var key: [16]u8 = undefined;
        try db.put(try std.fmt.bufPrint(&key, "key{d:0>4}", .{i}), "value");
    }
    try db.flush();
    for ([_]bool{ false, true }) |reverse| {
        const first = try db.scanWithOptions(.{ .reverse = reverse, .limit = 10 });
        defer db.freeScan(first);
        const before = db.readStats();
        const second = try db.scanWithOptions(.{ .reverse = reverse, .limit = 10 });
        defer db.freeScan(second);
        const after = db.readStats();
        try std.testing.expectEqual(@as(usize, 10), first.len);
        try std.testing.expectEqual(first.len, second.len);
        for (first, second) |a, b| {
            try std.testing.expectEqualStrings(a.key, b.key);
            try std.testing.expectEqualStrings(a.value, b.value);
        }
        try std.testing.expectEqual(before.data_block_reads, after.data_block_reads);
        try std.testing.expect(after.data_cache_hits > before.data_cache_hits);
    }
    const before = db.readStats().data_block_reads;
    const all = try db.scan(null, null);
    defer db.freeScan(all);
    try std.testing.expectEqual(@as(usize, 200), all.len);
    try std.testing.expect(db.readStats().data_block_reads > before);
}

test "scan bounds: long boundaries and changing group sizes preserve snapshots through allocation failures" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(allocator, std.testing.io, tmp.dir, .{ .durability = .async, .automatic_gc = false });
    defer db.deinit();
    const a: [256]u8 = @splat('a');
    const b: [1024]u8 = @splat('b');
    const c: [300]u8 = @splat('c');
    const end: [1024]u8 = @splat('z');
    const large: [600]u8 = @splat('v');
    const medium: [300]u8 = @splat('m');
    try db.put(&a, &medium);
    try db.put(&b, &large);
    try db.put(&c, "deleted");
    try db.put("d", "unchanged");
    try db.flush();
    try db.put(&b, "captured");
    try db.delete(&c);
    try db.put("e", &large);
    var view = try View.capture(&db);
    defer view.deinit(&db);
    try db.put(&b, "future");
    try db.delete("e");

    const Probe = struct {
        fn run(internal_allocator: std.mem.Allocator, target_db: *Db, captured: *View, start: []const u8, finish: []const u8, second: []const u8, reverse: bool) !void {
            const saved = target_db.internal_allocator;
            target_db.internal_allocator = internal_allocator;
            defer target_db.internal_allocator = saved;
            const rows = try scanCaptured(captured, target_db, .{ .start = start, .end = finish, .reverse = reverse });
            defer target_db.freeScan(rows);
            try std.testing.expectEqual(@as(usize, 4), rows.len);
            const expected_keys = [_][]const u8{ start, second, "d", "e" };
            for (rows, 0..) |row, i| {
                const index = if (reverse) rows.len - 1 - i else i;
                try std.testing.expectEqualStrings(expected_keys[index], row.key);
                switch (index) {
                    0 => {
                        try std.testing.expectEqual(@as(usize, 300), row.value.len);
                        for (row.value) |byte| try std.testing.expectEqual(@as(u8, 'm'), byte);
                    },
                    1 => try std.testing.expectEqualStrings("captured", row.value),
                    2 => try std.testing.expectEqualStrings("unchanged", row.value),
                    3 => {
                        try std.testing.expectEqual(@as(usize, 600), row.value.len);
                        for (row.value) |byte| try std.testing.expectEqual(@as(u8, 'v'), byte);
                    },
                    else => unreachable,
                }
            }
        }
    };
    for ([_]bool{ false, true }) |reverse| {
        try std.testing.checkAllAllocationFailures(allocator, Probe.run, .{ &db, &view, &a, &end, &b, reverse });
        try std.testing.expectEqual(@as(u32, 1), db.active_reads.load(.acquire));
    }
}
