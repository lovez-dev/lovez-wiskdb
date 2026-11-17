//! The database facade: open (LOCK, then recovery or fresh init,
//! then runtime state) and close (stop workers, release everything).
//! `open` borrows the root directory; `openPath` owns it until close.
//! The database owns the handles it opens beneath that directory. A concurrent
//! second open fails with DbLocked.

const std = @import("std");
const builtin = @import("builtin");
const disk = @import("io/io.zig");
const mf = @import("manifest/format.zig");
const mw = @import("manifest/writer.zig");
const mreader = @import("manifest/reader.zig");
const VersionSet = mreader.VersionSet;
const ReadVersion = @import("manifest/read_version.zig").ReadVersion;
const rp = @import("recovery.zig");
const vlm = @import("vlog/manager.zig");
const wv = @import("wal/writer.zig");
const coding = @import("util/coding.zig");
const internal_value = @import("util/internal_value.zig");
const crc = @import("util/crc.zig");
const lp = @import("util/lock_profile.zig");
const file_ids = @import("file_ids.zig");

/// sync: fsync before acknowledgement; interval: periodic fsync; async:
/// fsync only on explicit sync/flush/close or when retiring a generation.
/// Interval and async may lose recent acknowledged writes on a crash.
pub const Durability = enum { sync, interval, async };

/// Borrowed batch input. Keys and values need only remain valid until
/// writeBatch returns; byte strings, including empty keys/values, are supported.
pub const Op = union(enum) {
    put: struct { key: []const u8, value: []const u8 },
    del: []const u8,
};
const wr = @import("write.zig");
const memlist = @import("memtable/memtable_list.zig");
const MemTable = @import("memtable/memtable.zig").MemTable;
const tcache = @import("cache/table_cache.zig");
const bgw = @import("bg/worker.zig");
const runtime = @import("runtime.zig");

/// Opening-time configuration. Keep db.options unchanged while the database is
/// open: caches, workers and file generations are initialized from these values.
pub const Options = struct {
    /// Positive approximate MemTable byte threshold; an individual write can exceed it.
    write_buffer_size: u64 = 64 * 1024 * 1024,
    /// Rotation threshold in [1 MiB, maxInt(u32)]; oversized entries remain whole.
    vlog_file_size: u64 = 64 * 1024 * 1024,
    /// Retained open SSTs; zero is treated as one. Active readers may retain more.
    table_cache_size: usize = 1024,
    /// Shared SST-block/VLog-record byte budget; active readers may pin excess bytes.
    block_cache_size: usize = 8 * 1024 * 1024,
    /// Power of two, 1 through 16. Total byte budget is divided across shards.
    block_cache_shards: usize = 1,
    /// Pending immutable MemTables, 1 through 64; reaching this cap stalls writers.
    max_immutable_count: usize = 4,
    durability: Durability = .interval,
    /// Values strictly smaller than this stay inline; zero sends all values to VLog.
    value_threshold: u64 = 512,
    /// Positive interval between sync attempts in interval durability mode.
    sync_interval_ns: u64 = 100 * std.time.ns_per_ms,
    /// Positive L0 file count that makes compaction eligible.
    l0_compaction_trigger: u32 = 4,
    /// Positive compaction output size target; entries are never split.
    max_sst_file_size: u64 = 64 * 1024 * 1024,
    /// Finite fraction in (0, 1]; VLogs below this garbage ratio are not rewritten.
    gc_garbage_ratio: f64 = 0.5,
    automatic_gc: bool = true,
    /// Diagnostic timing changes measured contention; disabled for normal use.
    profile_read_locks: bool = false,
    /// Require namespace durability barriers; rejects unsupported platforms.
    require_directory_sync: bool = false,
};

/// Options for path-based Open. Directory creation is opt-in.
pub const OpenOptions = struct {
    db: Options = .{},
    create_if_missing: bool = false,
};

/// Keep this value at a stable address after its first operation, until deinit.
/// Reads, writes and maintenance calls may run concurrently. Finish all calls
/// before close/deinit; the allocator and Io backend must outlive the database
/// and support concurrent use by callers and background workers.
pub const Db = struct {
    allocator: std.mem.Allocator,
    internal_allocator: std.mem.Allocator,
    memory: *@import("util/counting_allocator.zig").CountingAllocator,
    closed_memory: ?@import("util/counting_allocator.zig").CountingAllocator.Stats = null,
    io: std.Io,
    options: Options,
    dir: disk.Dir, // borrowed by Db.open; owned by openPath when owns_dir is true
    owns_dir: bool = false,
    wal_dir: disk.Dir,
    sst_dir: disk.Dir,
    vlog_dir: disk.Dir,
    lock_file: disk.File,
    vs: VersionSet,
    read_version: *ReadVersion.Holder,
    manifest_name: []u8,
    manifest_writer: mw.Writer,
    vlog: vlm.Manager,
    memtables: memlist.List,
    tables: tcache.TableCache,
    sync_worker: ?*bgw.Worker,
    worker: *bgw.Worker, // heap-boxed: the spawned thread holds its address
    runtime_started: bool = false,
    closing: bool = false,
    closed: bool = false,
    durable_seq: std.atomic.Value(u64),
    next_seq: std.atomic.Value(u64),
    last_seq: std.atomic.Value(u64),
    log_number: std.atomic.Value(u64),
    write_mutex: std.Io.Mutex = std.Io.Mutex.init,
    view_capture_profile: lp.Profile = .{},
    view_release_profile: lp.Profile = .{},
    /// Captured read views pin obsolete SSTs and VLogs until all readers exit.
    /// Captures increment under write_mutex; exits decrement after all file
    /// access. Reclamation checks zero under write_mutex, excluding captures.
    active_reads: std.atomic.Value(usize) = .init(0),
    retired_tables_pending: std.atomic.Value(bool) = .init(false),
    obsolete_ssts: std.ArrayListUnmanaged(u64) = .empty,
    write_cond: std.Io.Condition = std.Io.Condition.init,
    // Background jobs borrow this address: do not move Db after first use.
    background_error: ?anyerror = null, // guarded by write_mutex
    wal_id: u64,
    wal: wv.Wal,
    wal_scratch: std.ArrayListUnmanaged(u8) = .empty,
    // One scheduled worker job may drain several immutable generations.
    // The scheduled list is guarded by write_mutex; files stay on disk until
    // the single manifest publication for the drained batch has landed.
    flush_scheduled: bool = false,
    flush_seq: u64 = 0,
    flush_next_wal: u64 = 0,
    flush_wals: std.ArrayListUnmanaged(u64) = .empty,

    /// Requested internal bytes; excludes caller-owned results and process RSS.
    /// Concurrent snapshots are approximate; the final snapshot remains usable after close.
    pub fn stat(self: *Db) @import("util/counting_allocator.zig").CountingAllocator.Stats {
        return self.closed_memory orelse self.memory.stats();
    }
    pub const ReadStats = tcache.TableCache.ReadStats;

    /// Approximate cache/read counters while open. Per-table counters cover only
    /// currently cached SSTs, so eviction can reduce their aggregate values.
    pub fn readStats(self: *Db) ReadStats {
        return self.tables.stats();
    }

    pub const ReadLockStats = struct {
        view_capture: lp.Stats,
        view_release: lp.Stats,
        table_cache: lp.Stats,
        block_lookup: lp.Stats,
        block_insert: lp.Stats,
        block_release: lp.Stats,
    };

    /// Sequential leaf-lock snapshots; not a globally atomic snapshot.
    pub fn readLockStats(self: *Db) ReadLockStats {
        self.write_mutex.lockUncancelable(self.io);
        const capture = self.view_capture_profile.counters;
        const release = self.view_release_profile.counters;
        self.write_mutex.unlock(self.io);
        self.tables.mutex.lockUncancelable(self.io);
        const table = self.tables.acquire_profile.counters;
        self.tables.mutex.unlock(self.io);
        const blocks = self.tables.block_cache.profiles();
        return .{ .view_capture = capture, .view_release = release, .table_cache = table, .block_lookup = blocks.lookup, .block_insert = blocks.insert, .block_release = blocks.release };
    }

    /// Opens a database by path. The returned Db owns its root directory handle.
    pub fn openPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: OpenOptions) !Db {
        const cwd = disk.Dir.cwd();
        const dir = if (options.create_if_missing)
            try cwd.createDirPathOpen(io, path, .{ .open_options = .{ .iterate = true } })
        else
            try cwd.openDir(io, path, .{ .iterate = true });
        errdefer dir.close(io);
        var db = try open(allocator, io, dir, options.db);
        db.owns_dir = true;
        return db;
    }

    /// Open or initialize an existing, iterable directory. The caller keeps dir
    /// open until close returns, and remains responsible for closing dir itself.
    /// Recovery may flush replayed WALs and retire obsolete files before returning.
    pub fn open(parent: std.mem.Allocator, io: std.Io, dir: disk.Dir, options: Options) !Db {
        const memory = try parent.create(@import("util/counting_allocator.zig").CountingAllocator);
        memory.* = .{ .parent = parent };
        errdefer parent.destroy(memory);
        const allocator = memory.allocator();
        if (options.require_directory_sync and !disk.directory_sync_supported) return error.UnsupportedDirectorySync;
        if (options.block_cache_shards == 0 or options.block_cache_shards > 16 or !std.math.isPowerOfTwo(options.block_cache_shards)) return error.InvalidOptions;
        if (options.max_immutable_count == 0 or options.max_immutable_count > 64 or
            options.sync_interval_ns == 0 or options.l0_compaction_trigger == 0 or
            options.max_sst_file_size == 0 or options.write_buffer_size == 0 or options.vlog_file_size > std.math.maxInt(u32) or
            !std.math.isFinite(options.gc_garbage_ratio) or options.gc_garbage_ratio <= 0 or options.gc_garbage_ratio > 1)
            return error.InvalidOptions;
        try dir.createDirPath(io, "WAL");
        try dir.createDirPath(io, "SST");
        try dir.createDirPath(io, "VLOG");
        _ = try disk.syncDirectory(dir, io); // persist WAL/SST/VLOG entries before use
        const wal_dir = try dir.openDir(io, "WAL", .{ .iterate = true });
        errdefer wal_dir.close(io);
        const sst_dir = try dir.openDir(io, "SST", .{ .iterate = true });
        errdefer sst_dir.close(io);
        const vlog_dir = try dir.openDir(io, "VLOG", .{ .iterate = true });
        errdefer vlog_dir.close(io);

        const lock_file = try dir.createFile(io, "LOCK", .{ .read = true, .truncate = false });
        errdefer lock_file.close(io);
        // tryLock, not lock: the blocking variant waits forever for a
        // holder instead of reporting DbLocked.
        const held = lock_file.tryLock(io, .exclusive) catch return error.DbLocked;
        if (!held) return error.DbLocked;

        // Placeholders so every errdefer below is valid from here on:
        // the empty VersionSet allocates nothing, free("") is a no-op.
        var vs = VersionSet.init(allocator);
        errdefer vs.deinit();
        var manifest_name: []u8 = "";
        errdefer allocator.free(manifest_name);
        var manifest_tail: mw.Tail = .{};
        var pending = std.AutoHashMapUnmanaged(u64, u64).empty;
        errdefer pending.deinit(allocator);

        if (rp.recover(allocator, io, dir)) |report| {
            var rep = report;
            if (rep.flush_failed) {
                rep.deinit(allocator);
                return error.RecoveryFlushFailed;
            }
            vs = rep.vs; // move out field by field; the report's own
            manifest_name = rep.manifest_name; // deinit never runs
            manifest_tail = rep.manifest_tail;
            pending = rep.replayable;
        } else |e| switch (e) {
            error.NotFound => {
                vs.log_number = 0;
                vs.next_file_number = 2; // manifest id 1 already drawn
                vs.last_sequence = 0;
                const fresh = try createFreshManifest(allocator, io, dir);
                manifest_name = fresh.name;
                manifest_tail = fresh.tail;
            },
            else => return e,
        }

        var vlog = try vlm.Manager.open(allocator, vlog_dir, io, vs.next_file_number, options.vlog_file_size);
        errdefer vlog.close(io);
        vs.next_file_number += 1; // the manager drew the active file's id

        // Protect VLogs referenced by WALs that recovery has not retired.
        {
            defer pending.deinit(allocator);
            var it = pending.iterator();
            while (it.next()) |e| try vlog.registerReplayable(io, e.key_ptr.*, e.value_ptr.*);
        }
        pending = .empty;
        // One WAL per generation; the first generation starts here.
        const wal_id = vs.next_file_number;
        vs.next_file_number += 1;
        var wal = blk: {
            var namebuf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&namebuf, "{d:0>6}.wal", .{wal_id}) catch unreachable;
            break :blk try wv.Wal.create(wal_dir, io, name);
        };
        errdefer wal.close(io);

        var memtables = try memlist.List.init(allocator, io, vs.last_sequence);
        errdefer memtables.deinit();

        var tables = tcache.TableCache.initSharded(allocator, io, options.table_cache_size, options.block_cache_size, options.block_cache_shards);
        errdefer tables.deinit();
        tables.acquire_profile.enabled = options.profile_read_locks;
        tables.block_cache.enableProfiling(options.profile_read_locks);

        const read_version = try ReadVersion.create(&vs);
        errdefer read_version.release();

        var manifest_writer = try mw.Writer.openAppend(allocator, io, dir, manifest_name, manifest_tail);
        errdefer manifest_writer.close();

        // Heap-boxed: the thread captures this address for its whole
        // life, so it must outlive open's stack frame.
        const worker = try allocator.create(bgw.Worker);
        errdefer allocator.destroy(worker);
        worker.* = bgw.Worker.init(allocator, io);
        errdefer worker.deinit();
        try worker.start();
        const sync_worker: ?*bgw.Worker = if (options.durability == .interval) blk: {
            const timer = try allocator.create(bgw.Worker);
            errdefer allocator.destroy(timer);
            timer.* = bgw.Worker.init(allocator, io);
            errdefer timer.deinit();
            try timer.start();
            break :blk timer;
        } else null;

        return .{
            .allocator = parent,
            .internal_allocator = allocator,
            .memory = memory,
            .io = io,
            .options = options,
            .view_capture_profile = .{ .enabled = options.profile_read_locks },
            .view_release_profile = .{ .enabled = options.profile_read_locks },
            .owns_dir = false,
            .dir = dir,
            .wal_dir = wal_dir,
            .sst_dir = sst_dir,
            .vlog_dir = vlog_dir,
            .lock_file = lock_file,
            .vs = vs,
            .read_version = read_version,
            .manifest_name = manifest_name,
            .manifest_writer = manifest_writer,
            .vlog = vlog,
            .memtables = memtables,
            .tables = tables,
            .worker = worker,
            .sync_worker = sync_worker,
            .wal = wal,
            .wal_id = wal_id,
            .durable_seq = .init(vs.last_sequence),
            .next_seq = .init(vs.last_sequence + 1),
            .last_seq = .init(vs.last_sequence),
            .log_number = .init(vs.log_number),
        };
    }

    /// Publish operations atomically to readers in slice order; the last operation
    /// wins for repeated keys. Persistence follows durability. An I/O failure can
    /// leave a replayable WAL batch, so an error does not prove the batch is absent
    /// after recovery. Inputs are borrowed only for the duration of this call.
    pub fn writeBatch(self: *Db, ops: []const Op) !void {
        return wr.writeBatch(self, ops);
    }

    /// Replace a value; key and value are borrowed until return. Persistence and
    /// failure semantics are the same as writeBatch.
    pub fn put(self: *Db, key: []const u8, value: []const u8) !void {
        return wr.put(self, key, value);
    }

    /// Delete a key; deleting an absent key succeeds. Persistence follows durability.
    pub fn delete(self: *Db, key: []const u8) !void {
        return wr.delete(self, key);
    }

    pub const ScanItem = @import("scan_view.zig").ScanItem;
    pub const ScanOptions = @import("scan_view.zig").ScanOptions;
    /// Owned ascending results in [start, end); null bounds are unbounded.
    /// One snapshot is captured per call; release the result with freeScan.
    pub fn scan(self: *Db, start: ?[]const u8, end: ?[]const u8) ![]ScanItem {
        return @import("scan_view.zig").scan(self, start, end);
    }
    /// Owned results at one snapshot, ordered and limited as requested. The limit
    /// caps returned rows, not source-buffer memory. Release with freeScan.
    pub fn scanWithOptions(self: *Db, options: ScanOptions) ![]ScanItem {
        return @import("scan_view.zig").scanWithOptions(self, options);
    }
    /// Free the result array and every key/value returned by scan/scanWithOptions.
    pub fn freeScan(self: *Db, items: []ScanItem) void {
        @import("scan_view.zig").freeItems(self, items);
    }
    /// Owned value at the acknowledged snapshot, or null if absent/deleted.
    /// Caller frees the result with the database's caller allocator.
    pub fn get(self: *Db, key: []const u8) !?[]const u8 {
        var view = blk: {
            var guard = self.view_capture_profile.lock(&self.write_mutex, self.io);
            defer guard.unlock();
            if (self.closing or self.closed) return error.DbClosed;
            self.startRuntime();
            break :blk try @import("read.zig").View.captureLocked(self, key);
        };
        defer view.deinit(self);
        return view.get(self, key);
    }

    /// Decodes a stored InternalValue into an owned copy of the user
    /// value; a pointer record is read back through the VLog with its
    /// entry CRC and key identity verified.
    pub fn valueFromIv(self: *Db, iv: []const u8, expect_key: []const u8) ![]const u8 {
        return self.valueFromIvAlloc(iv, expect_key, self.allocator);
    }

    pub fn valueFromIvAlloc(self: *Db, iv: []const u8, expect_key: []const u8, result_allocator: std.mem.Allocator) ![]const u8 {
        const view = internal_value.View.decode(iv) catch return error.VLogCorrupted;
        const val_len = view.header.value_len;
        if (view.header.isInline()) return result_allocator.dupe(u8, view.inline_bytes);
        const file_id = view.header.file_id;
        const offset = view.header.offset;
        if (file_id == 0) return error.VLogCorrupted;
        // readAt sizes its buffers from the iv and the search key, and
        // verifies header, payload and entry CRC on the way out.
        // Short keys stay on the stack. Small records may be copied from the
        // shared immutable-byte cache; large records read into caller storage.
        var key_stack: [256]u8 = undefined;
        const key_buf = if (expect_key.len <= key_stack.len) key_stack[0..expect_key.len] else try self.internal_allocator.alloc(u8, expect_key.len);
        defer if (expect_key.len > key_stack.len) self.internal_allocator.free(key_buf);
        const out = try result_allocator.alloc(u8, val_len);
        errdefer result_allocator.free(out);
        const r = try self.vlog.readAtCached(self.io, file_id, offset, key_buf, out, &self.tables.block_cache);
        if (r.value.len != out.len or !std.mem.eql(u8, r.key, expect_key)) return error.VLogCorrupted;
        return out;
    }

    /// Caller holds write_mutex.
    pub fn startRuntime(self: *Db) void {
        if (self.runtime_started) return;
        self.runtime_started = true;
        self.worker.submit(.{ .run = runtime.start, .ctx = self }) catch |err| {
            self.background_error = err;
            return;
        };
        if (self.sync_worker) |timer| timer.setTimer(
            .{ .run = runtime.tick, .ctx = self },
            self.options.sync_interval_ns,
        );
    }

    /// Caller holds write_mutex; writer rotation cannot race fsync.
    pub fn syncThrough(self: *Db, seq: u64) !void {
        if (self.durable_seq.load(.acquire) >= seq) return;
        try self.vlog.sync(self.io);
        try self.wal.appendSynced(self.io, seq);
        try self.wal.sync(self.io);
        try self.wal.syncDirectoryIfDirty(self.wal_dir, self.io);
        self.durable_seq.store(seq, .release);
    }

    /// Prepare an immutable generation for flushing while holding write_mutex.
    /// Async may lose an unsynced WAL, but publishing an SST must never expose
    /// external values whose VLog files are not durable.
    pub fn prepareFlushLocked(self: *Db, seq: u64) !void {
        if (self.options.durability == .async) return self.vlog.sync(self.io);
        return self.syncThrough(seq);
    }

    /// Persist all writes acknowledged before this call's barrier, without
    /// requiring a MemTable flush. Returns any previously recorded background error.
    pub fn sync(self: *Db) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed or self.closing) return error.DbClosed;
        if (self.background_error) |err| return err;
        self.syncThrough(self.last_seq.load(.acquire)) catch |err| {
            self.background_error = err;
            return err;
        };
    }

    /// Persist all writes preceding this call, including a partial MemTable.
    pub fn flush(self: *Db) !void {
        self.write_mutex.lockUncancelable(self.io);
        self.freezeForFlush() catch |err| {
            self.write_mutex.unlock(self.io);
            return err;
        };
        self.write_mutex.unlock(self.io);
        self.worker.waitIdle();
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.background_error) |err| return err;
    }

    fn freezeForFlush(self: *Db) !void {
        if (self.closed or self.closing) return error.DbClosed;
        self.startRuntime();
        while (self.memtables.immutableCount() >= self.options.max_immutable_count and self.background_error == null) {
            self.write_cond.waitUncancelable(self.io, &self.write_mutex);
        }
        if (self.background_error) |err| return err;
        const seq = self.last_seq.load(.acquire);
        try self.syncThrough(seq);
        if (self.memtables.current.data.approx_bytes.load(.monotonic) != 0) try self.freezeCurrent(seq);
    }

    /// Flush, seal the active value log, and run compaction/GC on the worker.
    pub fn collectGarbage(self: *Db) !void {
        try self.flush();
        self.write_mutex.lockUncancelable(self.io);
        if (self.closed or self.closing) {
            self.write_mutex.unlock(self.io);
            return error.DbClosed;
        }
        file_ids.sealVlogLocked(self) catch |err| {
            self.write_mutex.unlock(self.io);
            return err;
        };
        self.worker.submit(.{ .run = runtime.run, .ctx = self }) catch |err| {
            self.write_mutex.unlock(self.io);
            return err;
        };
        self.write_mutex.unlock(self.io);
        self.worker.waitIdle();
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.background_error) |err| return err;
    }

    /// Caller holds write_mutex.
    pub fn freezeCurrent(self: *Db, seq: u64) !void {
        // Reserve all failure-prone allocations before mutating generation
        // state. A pending batch drains every immutable table with one
        // manifest edit, so later rotations only extend it.
        var job: ?*FlushJob = null;
        if (!self.flush_scheduled) job = try self.internal_allocator.create(FlushJob);
        errdefer if (job) |j| self.internal_allocator.destroy(j);
        try self.flush_wals.ensureUnusedCapacity(self.internal_allocator, 1);
        const new_id = file_ids.reserveLocked(self);
        var namebuf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&namebuf, "{d:0>6}.wal", .{new_id});
        var new_wal = try wv.Wal.create(self.wal_dir, self.io, name);
        self.memtables.freeze(self.next_seq.load(.monotonic)) catch |err| {
            new_wal.close(self.io);
            disk.unlink(self.wal_dir, self.io, name) catch {};
            return err;
        };
        const old_wal = self.wal_id;
        self.wal.close(self.io);
        self.wal = new_wal;
        self.wal_id = new_id;
        self.flush_wals.appendAssumeCapacity(old_wal);
        self.flush_seq = @max(self.flush_seq, seq);
        self.flush_next_wal = new_id;
        if (job) |j| {
            j.* = .{ .db = self };
            self.flush_scheduled = true;
            self.worker.submit(.{ .run = FlushJob.run, .ctx = j }) catch |err| {
                self.background_error = err;
                self.write_cond.broadcast(self.io);
                return err;
            };
        }
    }

    /// Drain every immutable generation covered by one scheduled job. SST
    /// bytes are built outside write_mutex, but WAL retirement and manifest
    /// publication stay inside it so log_number never outruns flushed data.
    /// Caller holds write_mutex on entry and the same lock remains held on exit.
    fn flushPending(self: *Db) !void {
        const count = self.memtables.immutable.items.len;
        const wal_count = self.flush_wals.items.len;
        if (count == 0 or wal_count == 0) {
            self.flush_scheduled = false;
            self.flush_wals.clearRetainingCapacity();
            return;
        }
        std.debug.assert(wal_count == count);
        var holders: [64]*MemTable.Holder = undefined;
        @memcpy(holders[0..count], self.memtables.immutable.items);
        var wals: [64]u64 = undefined;
        @memcpy(wals[0..wal_count], self.flush_wals.items);
        const seq = self.flush_seq;
        const next_wal = self.flush_next_wal;
        self.flush_scheduled = false;
        self.flush_wals.clearRetainingCapacity();

        var built = VersionSet.init(self.internal_allocator);
        defer built.deinit();
        built.next_file_number = file_ids.reserveLocked(self);
        try self.prepareFlushLocked(seq);

        var tables: [64]*MemTable = undefined;
        for (holders[0..count], 0..) |holder, i| tables[i] = &holder.data;
        var build_err: ?anyerror = null;
        self.write_mutex.unlock(self.io);
        _ = @import("flush.zig").flushMemtables(self.internal_allocator, self.io, self.sst_dir, tables[0..count], &built) catch |err| {
            build_err = err;
        };
        self.write_mutex.lockUncancelable(self.io);
        if (build_err) |err| return err;

        var next = try self.vs.cloneState();
        defer next.deinit();
        if (built.by_level.get(0)) |lvl| try next.apply(&.{ .adds = lvl.items });
        next.log_number = next_wal;
        next.last_sequence = @max(next.last_sequence, seq);
        try @import("manifest/commit.zig").publishAndInstallLocked(self, &next);

        for (holders[0..count]) |holder| {
            const retired = self.memtables.popHead().?;
            std.debug.assert(retired == holder);
            retired.release();
        }
        _ = self.vlog.purgeReplayable(self.io, self.vs.log_number);
        for (wals[0..wal_count]) |old_wal| {
            var namebuf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&namebuf, "{d:0>6}.wal", .{old_wal});
            disk.unlink(self.wal_dir, self.io, name) catch {};
        }
    }

    /// No other API calls may still be running when close/deinit is called.
    /// Always releases resources; reports background or final persistence errors.
    /// Repeated close calls succeed. Caller-owned values remain the caller's
    /// responsibility and can be freed through their original allocator afterward.
    pub fn close(self: *Db) !void {
        if (self.closed) return;
        defer if (self.owns_dir) self.dir.close(self.io);
        self.write_mutex.lockUncancelable(self.io);
        self.closing = true;
        if (self.sync_worker) |timer| timer.clearTimer();
        self.write_cond.broadcast(self.io);
        self.write_mutex.unlock(self.io);
        if (self.sync_worker) |timer| {
            timer.waitIdle();
            timer.deinit();
            self.internal_allocator.destroy(timer);
            self.sync_worker = null;
        }
        self.worker.waitIdle();
        self.write_mutex.lockUncancelable(self.io);
        if (self.background_error == null) {
            self.syncThrough(self.last_seq.load(.acquire)) catch |err| {
                self.background_error = err;
            };
            if (self.background_error == null and self.memtables.current.data.approx_bytes.load(.monotonic) != 0) {
                self.freezeCurrent(self.last_seq.load(.acquire)) catch |err| {
                    self.background_error = err;
                };
            }
        }
        self.write_mutex.unlock(self.io);
        self.worker.waitIdle();
        const failure = self.background_error;
        std.debug.assert(self.active_reads.load(.acquire) == 0);
        runtime.reclaimTablesLocked(self);
        self.obsolete_ssts.deinit(self.internal_allocator);
        self.closed = true;
        self.worker.deinit();
        self.internal_allocator.destroy(self.worker);
        self.tables.deinit();
        self.memtables.deinit();
        self.vlog.close(self.io);
        self.read_version.release();
        self.vs.deinit();
        self.manifest_writer.close();
        self.internal_allocator.free(self.manifest_name);
        self.wal.close(self.io);
        self.wal_scratch.deinit(self.internal_allocator);
        self.flush_wals.deinit(self.internal_allocator);
        self.wal_dir.close(self.io);
        self.sst_dir.close(self.io);
        self.vlog_dir.close(self.io);
        self.lock_file.close(self.io); // closing the handle releases the lock
        self.closed_memory = self.memory.stats();
        self.allocator.destroy(self.memory);
        if (failure) |err| return err;
    }

    /// Close while discarding persistence errors; call close explicitly when
    /// shutdown durability must be observed. Safe after an explicit close.
    pub fn deinit(self: *Db) void {
        self.close() catch {};
    }
};

const FlushJob = struct {
    db: *Db,

    fn run(raw: *anyopaque) void {
        const job: *FlushJob = @ptrCast(@alignCast(raw));
        const db = job.db;
        defer db.internal_allocator.destroy(job);
        db.write_mutex.lockUncancelable(db.io);
        defer db.write_mutex.unlock(db.io);
        if (db.background_error != null) return;
        db.flushPending() catch |err| {
            // Retain the immutable and WAL; fail writers rather than
            // leaving them asleep forever behind a failed flush.
            db.background_error = err;
        };
        db.write_cond.broadcast(db.io);
        if (db.background_error == null) runtime.maintainLocked(db, db.options.automatic_gc) catch |err| {
            db.background_error = err;
            db.write_cond.broadcast(db.io);
        };
    }
};

const FreshManifest = struct { name: []u8, tail: mw.Tail };

fn createFreshManifest(allocator: std.mem.Allocator, io: std.Io, dir: disk.Dir) !FreshManifest {
    var w = try mw.Writer.create(allocator, io, dir, 1);
    defer w.close();
    const ed = mf.Edit{
        .comparator = mf.comparator_name,
        .format_version = mf.current_version,
        .log_number = 0,
        .next_file_number = 2,
        .last_sequence = 0,
    };
    try w.appendEdit(&ed);
    var buf: [64]u8 = undefined;
    const owned = try allocator.dupe(u8, mw.fileName(1, &buf));
    errdefer allocator.free(owned);
    try mw.publishCurrent(io, dir, owned);
    return .{ .name = owned, .tail = .{ .offset = w.offset, .prev_crc = w.prev_crc } };
}

// ========================= tests =========================

fn testChildPath(dir: disk.Dir, name: []const u8) ![]u8 {
    var buffer: [disk.Dir.max_path_bytes]u8 = undefined;
    const parent = buffer[0..try dir.realPath(std.testing.io, &buffer)];
    return std.fs.path.join(std.testing.allocator, &.{ parent, name });
}

test "internal value: owned reads skip expiry bytes and reject malformed references" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .durability = .async });
    defer db.deinit();
    // Stored layout predates this codec: expiry is metadata, not user payload.
    var bytes: [32]u8 = @splat(0);
    bytes[0] = 0b110;
    coding.putU32(bytes[1..5], 3);
    coding.putU64(bytes[21..29], 123);
    @memcpy(bytes[29..32], "ttl");
    const value = try db.valueFromIv(&bytes, "key");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("ttl", value);
    try std.testing.expectError(error.VLogCorrupted, db.valueFromIv(bytes[0..28], "key"));
    try std.testing.expectError(error.VLogCorrupted, db.valueFromIv(bytes[0..31], "key"));
    @memset(&bytes, 0);
    try std.testing.expectError(error.VLogCorrupted, db.valueFromIv(bytes[0..21], "key"));
}

test "db: invalid cache shard counts are rejected before creating files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_]usize{ 0, 3, 17, 32 }) |count| {
        try std.testing.expectError(error.InvalidOptions, Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .block_cache_shards = count }));
    }
    var entries = tmp.dir.iterate();
    try std.testing.expect((try entries.next(std.testing.io)) == null);
}
test "Open: missing path is not created unless requested" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = std.Io.Dir.cwd();
    const path = try testChildPath(tmp.dir, "database");
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.FileNotFound, Db.openPath(std.testing.allocator, io, path, .{}));
    var db = try Db.openPath(std.testing.allocator, io, path, .{ .create_if_missing = true });
    defer db.deinit();
    try db.close();
    const retained = try cwd.openDir(io, path, .{});
    defer retained.close(io);
    try db.close();
    db.deinit();
    // A repeated shutdown must not close a newly reused directory handle.
    const marker = try retained.createFile(io, "close-idempotent", .{});
    marker.close(io);
}

test "Open: create_if_missing rejects a file at the database path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testChildPath(tmp.dir, "file");
    defer std.testing.allocator.free(path);
    const file = try tmp.dir.createFile(io, "file", .{});
    file.close(io);
    try std.testing.expectError(error.NotDir, Db.openPath(std.testing.allocator, io, path, .{ .create_if_missing = true }));
}

test "db: fresh open lays out the directory and survives a reopen" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var db = try Db.open(allocator, io, tmp.dir, .{});
    for ([_][]const u8{ "CURRENT", "MANIFEST-000001", "LOCK" }) |n| {
        const f = try tmp.dir.openFile(io, n, .{ .mode = .read_only });
        f.close(io);
    }
    for ([_][]const u8{ "WAL", "SST", "VLOG" }) |n| {
        const d = try tmp.dir.openDir(io, n, .{});
        d.close(io);
    }
    try std.testing.expectEqual(@as(u64, 1), db.next_seq.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), db.last_seq.load(.acquire));
    db.deinit();

    // The reopen walks the recovery path over what the first open wrote.
    var again = try Db.open(allocator, io, tmp.dir, .{});
    try std.testing.expectEqual(@as(u64, 1), again.next_seq.load(.acquire));
    again.deinit();
}

test "write path: value routing, delete markers, and the durability ack" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(allocator, io, tmp.dir, .{});
    defer db.deinit();

    try db.put("small", "v1");
    var big: [600]u8 = @splat('x');
    try db.put("big", &big);
    try db.delete("small");

    // Ack contract: put returns only after last_seq covers the batch.
    try std.testing.expectEqual(@as(u64, 3), db.last_seq.load(.acquire));
    try std.testing.expectEqual(@as(u64, 4), db.next_seq.load(.acquire));

    const mt = &db.memtables.current.data;
    const small_iv = mt.get("small", 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(small_iv[0] & 0b010 != 0); // routed inline
    try std.testing.expectEqualStrings("v1", small_iv[21..]);
    const big_iv = mt.get("big", 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(big_iv[0] & 0b010 == 0); // pointer record
    try std.testing.expect(coding.getU64(big_iv[5..13]) != 0);
    try std.testing.expect(mt.get("small", 3) == null); // tombstone at seq 3

    const vf = try tmp.dir.openFile(io, "VLOG/000002.vlog", .{ .mode = .read_only });
    vf.close(io); // the large value landed in the first VLog generation
}

test "write path: freeze flushes the table and retires its WAL generation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(allocator, io, tmp.dir, .{ .write_buffer_size = 1024 });
    defer db.deinit();

    var val: [400]u8 = @splat('y');
    for (0..4) |i| {
        var keybuf: [8]u8 = undefined;
        const k = std.fmt.bufPrint(&keybuf, "k{d}", .{i}) catch unreachable;
        try db.put(k, &val);
    }

    try std.testing.expectEqual(@as(u64, 4), db.last_seq.load(.acquire));
    db.worker.waitIdle();
    try std.testing.expect(db.background_error == null);
    try std.testing.expectEqual(@as(usize, 0), db.memtables.immutableCount());
    try std.testing.expectEqual(@as(usize, 1), db.vs.fileCount(0));
    try std.testing.expectEqual(@as(u64, 4), db.log_number.load(.acquire));
    const new_wal = try tmp.dir.openFile(io, "WAL/000004.wal", .{ .mode = .read_only });
    new_wal.close(io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "WAL/000003.wal", .{ .mode = .read_only }));
}

test "get: read-your-writes over inline and pointer values; a tombstone stops the scan" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(allocator, io, tmp.dir, .{});
    defer db.deinit();

    try db.put("a", "alpha");
    try db.put("c", "gamma");
    var big: [600]u8 = @splat('b');
    try db.put("b", &big);
    try db.delete("a");

    const c = (try db.get("c")) orelse return error.TestUnexpectedResult;
    defer allocator.free(c);
    try std.testing.expectEqualStrings("gamma", c);

    const b = (try db.get("b")) orelse return error.TestUnexpectedResult;
    defer allocator.free(b);
    try std.testing.expectEqual(@as(usize, 600), b.len);
    try std.testing.expect(b[0] == 'b' and b[599] == 'b');

    // The newest entry is a tombstone: it must stop the scan, not
    // fall through to the stale alpha still sitting in the table.
    try std.testing.expect((try db.get("a")) == null);
    try std.testing.expect((try db.get("missing")) == null);
}

test "db: a second open while locked fails with DbLocked" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var db = try Db.open(allocator, io, tmp.dir, .{});
    defer db.deinit();
    // POSIX ties advisory locks to the process, so a same-process
    // second open never conflicts there; Windows locks per handle.
    if (builtin.os.tag == .windows) {
        try std.testing.expectError(error.DbLocked, Db.open(allocator, io, tmp.dir, .{}));
    }
}

test "runtime flush: sustained writes exceed backpressure cap and survive reopen" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const value: [600]u8 = @splat('v');
    for ([_]Durability{ .sync, .async }) |durability| {
        {
            var db = try Db.open(alloc, io, tmp.dir, .{
                .write_buffer_size = 1,
                .max_immutable_count = 1,
                .durability = durability,
            });
            defer db.deinit();
            for (0..12) |i| {
                var buf: [16]u8 = undefined;
                const key = try std.fmt.bufPrint(&buf, "key{d}", .{i});
                try db.put(key, &value);
                const got = (try db.get(key)).?;
                defer alloc.free(got);
                try std.testing.expectEqualSlices(u8, &value, got);
            }
            try db.put("deleted", "old");
            try db.delete("deleted");
            db.worker.waitIdle();
            try std.testing.expect(db.background_error == null);
            try std.testing.expectEqual(@as(usize, 0), db.memtables.immutableCount());
            var it = db.wal_dir.iterate();
            var count: usize = 0;
            while (try it.next(io)) |_| count += 1;
            try std.testing.expectEqual(@as(usize, 1), count);
        }
        var db = try Db.open(alloc, io, tmp.dir, .{});
        defer db.deinit();
        for (0..12) |i| {
            var buf: [16]u8 = undefined;
            const key = try std.fmt.bufPrint(&buf, "key{d}", .{i});
            const got = (try db.get(key)).?;
            defer alloc.free(got);
            try std.testing.expectEqualSlices(u8, &value, got);
        }
        try std.testing.expect((try db.get("deleted")) == null);
    }
}

test "runtime flush: failed SST creation preserves data and fails writers without waiting" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try Db.open(alloc, io, tmp.dir, .{ .write_buffer_size = 1, .max_immutable_count = 1 });
        defer db.deinit();
        // First rotation draws WAL 4; the first flush will draw SST 5.
        try db.sst_dir.createDir(io, "000005.sst", .default_dir);
        try db.put("kept", "value");
        db.worker.waitIdle();
        const failure = db.background_error orelse return error.TestUnexpectedResult;
        try std.testing.expectError(failure, db.put("later", "blocked by error"));
        try std.testing.expectEqual(@as(usize, 1), db.memtables.immutableCount());
        const got = (try db.get("kept")).?;
        defer alloc.free(got);
        try std.testing.expectEqualStrings("value", got);
        const wal = try db.wal_dir.openFile(io, "000003.wal", .{ .mode = .read_only });
        wal.close(io);
    }
    try tmp.dir.deleteDir(io, "SST/000005.sst");
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    const got = (try db.get("kept")).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("value", got);
}

test "db: a zero immutable cap is rejected" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try std.testing.expectError(error.InvalidOptions, Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{ .max_immutable_count = 0 }));
}

const ConcurrentWriter = struct {
    db: *Db,
    id: usize,
    failed: bool = false,

    fn run(ctx: *ConcurrentWriter) void {
        for (0..8) |i| {
            var keybuf: [32]u8 = undefined;
            const key = std.fmt.bufPrint(&keybuf, "writer{d}/key{d}", .{ ctx.id, i }) catch unreachable;
            ctx.db.put(key, "value") catch {
                ctx.failed = true;
                return;
            };
        }
    }
};

test "runtime flush: concurrent writers respect backpressure and close drains jobs" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var db = try Db.open(alloc, io, tmp.dir, .{ .write_buffer_size = 1, .max_immutable_count = 1 });
        defer db.deinit();
        var writers: [3]ConcurrentWriter = undefined;
        var threads: [3]std.Thread = undefined;
        var started: usize = 0;
        {
            defer for (threads[0..started]) |thread| thread.join();
            for (&writers, 0..) |*writer, i| {
                writer.* = .{ .db = &db, .id = i };
                threads[i] = try std.Thread.spawn(.{}, ConcurrentWriter.run, .{writer});
                started += 1;
            }
        }
        for (writers) |writer| try std.testing.expect(!writer.failed);
        // No waitIdle: deinit must drain the final queued flush itself.
    }
    var db = try Db.open(alloc, io, tmp.dir, .{});
    defer db.deinit();
    for (0..3) |writer| {
        for (0..8) |i| {
            var keybuf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&keybuf, "writer{d}/key{d}", .{ writer, i });
            const got = (try db.get(key)).?;
            defer alloc.free(got);
            try std.testing.expectEqualStrings("value", got);
        }
    }
}
