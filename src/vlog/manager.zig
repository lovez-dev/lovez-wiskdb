//! VLog manager: the file set for one db — the active writer, on-demand
//! readers for cross-file reads, the shared-id counter, and the `closing`
//! gate that refuses new reads while a file is being retired.

const std = @import("std");
const disk = @import("../io/io.zig");
const Io = std.Io;
const writer = @import("writer.zig");
const reader = @import("reader.zig");

pub const min_file_size: u64 = 1 << 20; // keeps `< threshold` meaningful and u32-safe

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: Io,
    readers_mutex: Io.Mutex = .init,
    dir: disk.Dir,
    writer: writer.Writer,
    next_id: u64,
    threshold: u64,
    /// Retained reader handles keyed by file id; the cache itself is the
    /// "active reader" ref that deletion logic must respect.
    readers: std.AutoHashMap(u64, *reader.Reader.Holder),
    closing: std.AutoHashMap(u64, void),
    /// VLog id → the newest WAL id that points at it. A separate leaf lock lets
    /// the write path register inside its own lock without
    /// inverting order; queries treat `wal_id < log_number` as absent
    /// and the janitor purges those rows lazily.
    replayable: std.AutoHashMap(u64, u64),
    refs_mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn open(
        allocator: std.mem.Allocator,
        dir: disk.Dir,
        io: Io,
        first_id: u64,
        threshold: u64,
    ) (error{InvalidOptions} || disk.File.OpenError || std.fmt.BufPrintError || std.mem.Allocator.Error)!Manager {
        if (threshold < min_file_size or threshold > std.math.maxInt(u32)) return error.InvalidOptions;
        var m = Manager{
            .allocator = allocator,
            .io = io,
            .dir = dir,
            .writer = try writer.Writer.create(dir, io, first_id, threshold),
            .next_id = first_id + 1,
            .threshold = threshold,
            .readers = std.AutoHashMap(u64, *reader.Reader.Holder).init(allocator),
            .closing = std.AutoHashMap(u64, void).init(allocator),
            .replayable = std.AutoHashMap(u64, u64).init(allocator),
        };
        errdefer m.readers.deinit();
        errdefer m.closing.deinit();
        errdefer m.replayable.deinit();
        return m;
    }

    /// `value_crc`, when present, was calculated over the same value bytes.
    pub fn append(
        self: *Manager,
        io: Io,
        seq: u64,
        expire_at: u64,
        key: []const u8,
        value: []const u8,
        value_crc: ?u32,
    ) (Io.File.WritePositionalError || disk.File.OpenError || std.fmt.BufPrintError || Io.File.SyncError)!writer.Pointer {
        const p = try self.writer.append(io, seq, expire_at, key, value, value_crc);
        // The id space is shared with WAL/SST files; a manifest allocator
        // becomes the source once one exists — the local +1 is the bootstrap.
        self.next_id = self.writer.file_id + 1;
        return p;
    }

    /// Persist the active VLog before the WAL records its synced sequence.
    pub fn sync(self: *Manager, io: Io) disk.DirectorySyncError!void {
        try self.writer.sync(io);
    }

    /// All reads pin a separate read-only handle, independent of writer rotation.
    pub fn readAt(
        self: *Manager,
        io: Io,
        file_id: u64,
        offset: u64,
        key_buf: []u8,
        val_buf: []u8,
    ) (error{ FileClosing, VLogCorrupted, UnsupportedFormatVersion } || Io.File.ReadPositionalError || disk.File.OpenError || std.fmt.BufPrintError || std.mem.Allocator.Error)!reader.ReadResult {
        const holder = try self.acquireReader(file_id);
        defer holder.release();
        _ = io;
        return holder.data.readAt(offset, key_buf, val_buf);
    }

    /// Cache hits must pass the same closing gate and temporary reader pin as
    /// disk reads. The byte cache never retains a file handle or GC reference.
    pub fn readAtCached(
        self: *Manager,
        io: Io,
        file_id: u64,
        offset: u64,
        key_buf: []u8,
        val_buf: []u8,
        cache: *@import("../cache/block_cache.zig").BlockCache,
    ) (error{ FileClosing, VLogCorrupted, UnsupportedFormatVersion } || Io.File.ReadPositionalError || disk.File.OpenError || std.fmt.BufPrintError || std.mem.Allocator.Error)!reader.ReadResult {
        const holder = try self.acquireReader(file_id);
        defer holder.release();
        _ = io;
        return holder.data.readAtCached(offset, key_buf, val_buf, cache);
    }

    fn acquireReader(self: *Manager, file_id: u64) !*reader.Reader.Holder {
        self.readers_mutex.lockUncancelable(self.io);
        defer self.readers_mutex.unlock(self.io);
        if (self.closing.contains(file_id)) return error.FileClosing;
        const gop = try self.readers.getOrPut(file_id);
        if (!gop.found_existing) {
            errdefer _ = self.readers.remove(file_id);
            gop.value_ptr.* = try reader.Reader.open(self.allocator, self.dir, self.io, file_id);
        }
        gop.value_ptr.*.acquire();
        return gop.value_ptr.*;
    }

    /// Drop an idle cached handle so the deletion gate can observe no readers.
    pub fn evictReader(self: *Manager, file_id: u64) void {
        self.readers_mutex.lockUncancelable(self.io);
        defer self.readers_mutex.unlock(self.io);
        if (self.readers.get(file_id)) |holder| {
            if (holder.refCount() == 1) {
                _ = self.readers.remove(file_id);
                holder.release();
            }
        }
    }

    pub fn hasReader(self: *Manager, file_id: u64) bool {
        self.readers_mutex.lockUncancelable(self.io);
        defer self.readers_mutex.unlock(self.io);
        return self.readers.contains(file_id);
    }
    /// Retirement gate: once set, new reads of this file fail with
    /// `FileClosing`; holders already in the cache keep working until the
    /// deletion decision releases them.
    pub fn markClosing(self: *Manager, file_id: u64) !void {
        self.readers_mutex.lockUncancelable(self.io);
        defer self.readers_mutex.unlock(self.io);
        try self.closing.put(file_id, {});
    }

    /// Deletion-gate step before unlink: close the gate and drop the
    /// cached handle so no reader can reach the file again. A read
    /// already past this check is covered by the source pin it holds
    /// for the whole pread.
    pub fn retire(self: *Manager, file_id: u64) !void {
        self.readers_mutex.lockUncancelable(self.io);
        defer self.readers_mutex.unlock(self.io);
        try self.closing.put(file_id, {});
        if (self.readers.get(file_id)) |holder| {
            if (holder.refCount() > 1) return error.FileBusy;
        }
        if (self.readers.fetchRemove(file_id)) |kv| kv.value.release();
    }

    /// Record that `wal_id` references `vlog_id`. The newest WAL wins:
    /// protection must hold while ANY replayable WAL points at the
    /// file, and `wal_id >= log_number` for the newest is exactly that.
    pub fn registerReplayable(self: *Manager, io: Io, vlog_id: u64, wal_id: u64) error{OutOfMemory}!void {
        self.refs_mutex.lockUncancelable(io);
        defer self.refs_mutex.unlock(io);
        const gop = try self.replayable.getOrPut(vlog_id);
        if (!gop.found_existing or gop.value_ptr.* < wal_id) gop.value_ptr.* = wal_id;
    }

    /// True while the newest WAL referencing the file still needs replay.
    /// A stale row reads as absent — its WAL
    /// is already consumed, so there is nothing left to protect.
    pub fn replayableProtected(self: *Manager, io: Io, vlog_id: u64, log_number: u64) bool {
        self.refs_mutex.lockUncancelable(io);
        defer self.refs_mutex.unlock(io);
        const wal_id = self.replayable.get(vlog_id) orelse return false;
        return wal_id >= log_number;
    }

    /// Lazy reclamation on janitor cycles: drop rows whose WAL has been
    /// consumed. Best effort — an OOM mid-pass leaves rows that still
    /// read as absent until the next cycle.
    pub fn purgeReplayable(self: *Manager, io: Io, log_number: u64) usize {
        self.refs_mutex.lockUncancelable(io);
        defer self.refs_mutex.unlock(io);
        var stale: std.ArrayListUnmanaged(u64) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.replayable.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* < log_number) stale.append(self.allocator, e.key_ptr.*) catch break;
        }
        for (stale.items) |id| _ = self.replayable.remove(id);
        return stale.items.len;
    }
    pub fn close(self: *Manager, io: Io) void {
        self.writer.close(io);
        var it = self.readers.valueIterator();
        while (it.next()) |holder| holder.*.release();
        self.readers.deinit();
        self.closing.deinit();
        self.replayable.deinit();
    }
};

test "manager: options validation refuses tiny or over-u32 thresholds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try std.testing.expectError(
        error.InvalidOptions,
        Manager.open(std.testing.allocator, tmp.dir, io, 1, 1024),
    );
    try std.testing.expectError(
        error.InvalidOptions,
        Manager.open(std.testing.allocator, tmp.dir, io, 1, @as(u64, std.math.maxInt(u32)) + 1),
    );
    var m = try Manager.open(std.testing.allocator, tmp.dir, io, 1, min_file_size);
    m.close(io); // no readers, no writers — just releases
}

test "manager: 1 MiB threshold with 32 KiB values rotates; cross-file reads work" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var m = try Manager.open(std.testing.allocator, tmp.dir, io, 1, min_file_size);
    defer m.close(io);

    // 32816 B per entry: 31 fit in 1 MiB, the 32nd rotates — multi-entry
    // batches per file, pre-write rotation, start offsets always below min.
    const value: [32768]u8 = @splat('v');
    var ptrs: [40]writer.Pointer = undefined;
    for (0..40) |i| {
        var kbuf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&kbuf, "key{d}", .{i});
        ptrs[i] = try m.append(io, @intCast(i + 1), 0, key, &value, null);
        try std.testing.expect(ptrs[i].offset < min_file_size);
        try std.testing.expect(ptrs[i].offset % 8 == 0);
    }
    try std.testing.expect(ptrs[39].file_id >= 2); // rotation really happened

    var kout: [16]u8 = undefined;
    var vout: [32768]u8 = undefined;

    // Old file: goes through the cached read-only handle.
    const old = ptrs[0];
    const r1 = try m.readAt(io, old.file_id, old.offset, &kout, &vout);
    try std.testing.expectEqual(@as(u64, 1), r1.seq);
    try std.testing.expectEqualStrings("key0", r1.key);
    try std.testing.expectEqualSlices(u8, &value, r1.value);

    // The active file also uses an independently owned read handle.
    const last = ptrs[39];
    const r2 = try m.readAt(io, last.file_id, last.offset, &kout, &vout);
    try std.testing.expectEqual(@as(u64, 40), r2.seq);
    try std.testing.expectEqualStrings("key39", r2.key);

    // Retirement gate.
    try m.markClosing(old.file_id);
    try std.testing.expectError(
        error.FileClosing,
        m.readAt(io, old.file_id, old.offset, &kout, &vout),
    );
}

test "manager: retirement waits for pinned reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var m = try Manager.open(std.testing.allocator, tmp.dir, io, 1, min_file_size);
    defer m.close(io);
    const p = try m.append(io, 1, 0, "key", "value", null);
    {
        const held = try m.acquireReader(p.file_id);
        defer held.release();
        try std.testing.expectError(error.FileBusy, m.retire(p.file_id));
        try std.testing.expectError(error.FileClosing, m.acquireReader(p.file_id));
        var key: [3]u8 = undefined;
        var value: [5]u8 = undefined;
        const result = try held.data.readAt(p.offset, &key, &value);
        try std.testing.expectEqualStrings("value", result.value);
    }
    try m.retire(p.file_id);
    try std.testing.expect(!m.hasReader(p.file_id));
}

test "manager cache: retirement gates hits without cache-owned reader pins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var manager = try Manager.open(a, tmp.dir, io, 1, min_file_size);
    defer manager.close(io);
    var cache = @import("../cache/block_cache.zig").BlockCache.init(a, io, 4096);
    defer cache.deinit();
    const p = try manager.append(io, 1, 0, "key", "value", null);
    var key: [3]u8 = undefined;
    var value: [5]u8 = undefined;
    _ = try manager.readAtCached(io, p.file_id, p.offset, &key, &value, &cache);
    _ = try manager.readAtCached(io, p.file_id, p.offset, &key, &value, &cache);
    try std.testing.expectEqual(@as(u64, 1), cache.stats().hits);
    try manager.markClosing(p.file_id);
    try std.testing.expectError(error.FileClosing, manager.readAtCached(io, p.file_id, p.offset, &key, &value, &cache));
    try manager.retire(p.file_id);
    try std.testing.expect(!manager.hasReader(p.file_id));
    try std.testing.expectError(error.FileClosing, manager.readAtCached(io, p.file_id, p.offset, &key, &value, &cache));
    // Cached copies outlive reader retirement without keeping the file busy.
    try std.testing.expect(cache.stats().bytes > 0);
}
