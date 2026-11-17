//! LRU cache of open tables: file_id → one cache-owned RcTable
//! reference. An acquire adds the caller's own reference, so eviction
//! may drop the cache's at any time without disturbing live readers.
//! The lock never wraps I/O: a miss checks, unlocks, opens, relocks
//! and inserts — a racing opener simply wins.

const std = @import("std");
const disk = @import("../io/io.zig");
const tr = @import("../sstable/table_reader.zig");
const block_cache = @import("block_cache.zig");
const lp = @import("../util/lock_profile.zig");

const LruNode = struct {
    lru: std.DoublyLinkedList.Node = .{}, // embedded intrusively; the map keys off the wrapper
    id: u64,
    table: *tr.RcTable,
};

pub const TableCache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    capacity: usize,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    acquire_profile: lp.Profile = .{},
    map: std.AutoHashMap(u64, *LruNode),
    /// First = most recently used; the tail is what evicts.
    lru: std.DoublyLinkedList = .{},
    hits: std.atomic.Value(u64) = .init(0),
    misses: std.atomic.Value(u64) = .init(0),
    block_cache: block_cache.BlockCache,

    /// data_cache_misses/evictions/bytes cover the shared SST/VLog byte cache;
    /// data_cache_hits and data_block_reads remain per-SST reader aggregates.
    pub const ReadStats = struct { cache_hits: u64, cache_misses: u64, bloom_negative: u64, bloom_partition_reads: u64, bloom_partition_bytes: u64, data_block_reads: u64, data_cache_hits: u64, data_cache_misses: u64, data_cache_evictions: u64, data_cache_bytes: usize };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize, block_capacity: usize) TableCache {
        return initSharded(allocator, io, capacity, block_capacity, 1);
    }

    pub fn initSharded(allocator: std.mem.Allocator, io: std.Io, capacity: usize, block_capacity: usize, shards: usize) TableCache {
        return .{
            .allocator = allocator,
            .io = io,
            .capacity = @max(capacity, 1),
            .map = std.AutoHashMap(u64, *LruNode).init(allocator),
            .block_cache = block_cache.BlockCache.initSharded(allocator, io, block_capacity, shards),
        };
    }

    pub fn deinit(self: *TableCache) void {
        self.mutex.lockUncancelable(self.io);
        while (self.lru.last) |lnode| {
            const node: *LruNode = @fieldParentPtr("lru", lnode);
            self.lru.remove(lnode);
            _ = self.map.remove(node.id);
            node.table.release();
            self.allocator.destroy(node);
        }
        self.mutex.unlock(self.io);
        self.map.deinit();
        self.block_cache.deinit();
    }

    /// An owned reference to the table, opening it on a miss.
    pub fn acquire(self: *TableCache, dir: disk.Dir, file_id: u64) !*tr.RcTable {
        var first_guard = self.acquire_profile.lock(&self.mutex, self.io);
        if (self.map.get(file_id)) |node| {
            _ = self.hits.fetchAdd(1, .monotonic);
            node.table.acquire();
            self.lru.remove(&node.lru);
            self.lru.prepend(&node.lru); // touch: most recent first
            first_guard.unlock();
            return node.table;
        }
        first_guard.unlock();
        _ = self.misses.fetchAdd(1, .monotonic);

        var namebuf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&namebuf, "{d:0>6}.sst", .{file_id}) catch unreachable;
        const reader = try tr.TableReader.openWithCache(self.allocator, self.io, dir, name, &self.block_cache, file_id);
        const table = tr.RcTable.create(self.allocator, reader) catch |e| {
            var dying = reader;
            dying.deinit();
            return e;
        };

        errdefer table.release();
        var insert_guard = self.acquire_profile.lock(&self.mutex, self.io);
        defer insert_guard.unlock();
        const gop = try self.map.getOrPut(file_id);
        if (gop.found_existing) {
            // a racer inserted first: keep theirs, discard ours
            gop.value_ptr.*.table.acquire();
            self.lru.remove(&gop.value_ptr.*.lru);
            self.lru.prepend(&gop.value_ptr.*.lru);
            table.release();
            return gop.value_ptr.*.table;
        }
        errdefer _ = self.map.remove(file_id);
        const node = try self.allocator.create(LruNode);
        node.* = .{ .id = file_id, .table = table };
        gop.value_ptr.* = node;
        self.lru.prepend(&node.lru);
        self.evictLocked();
        table.acquire(); // caller's reference, separate from the cache's
        return table;
    }

    pub fn stats(self: *TableCache) ReadStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var bloom_negative: u64 = 0;
        var bloom_partition_reads: u64 = 0;
        var bloom_partition_bytes: u64 = 0;
        var data_block_reads: u64 = 0;
        var data_cache_hits: u64 = 0;
        var it = self.lru.first;
        while (it) |node| : (it = node.next) {
            const entry: *LruNode = @fieldParentPtr("lru", node);
            bloom_negative += entry.table.data.bloom_negative.load(.monotonic);
            bloom_partition_reads += entry.table.data.bloom_partition_reads.load(.monotonic);
            bloom_partition_bytes += entry.table.data.bloom_partition_bytes.load(.monotonic);
            data_block_reads += entry.table.data.data_block_reads.load(.monotonic);
            data_cache_hits += entry.table.data.data_cache_hits.load(.monotonic);
        }
        const block_stats = self.block_cache.stats();
        return .{ .cache_hits = self.hits.load(.monotonic), .cache_misses = self.misses.load(.monotonic), .bloom_negative = bloom_negative, .bloom_partition_reads = bloom_partition_reads, .bloom_partition_bytes = bloom_partition_bytes, .data_block_reads = data_block_reads, .data_cache_hits = data_cache_hits, .data_cache_misses = block_stats.misses, .data_cache_evictions = block_stats.evictions, .data_cache_bytes = block_stats.bytes };
    }

    pub fn invalidate(self: *TableCache, id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.map.fetchRemove(id)) |kv| {
            const node = kv.value;
            self.lru.remove(&node.lru);
            node.table.release();
            self.allocator.destroy(node);
            self.block_cache.invalidateFile(id);
        }
    }

    fn evictLocked(self: *TableCache) void {
        while (self.map.count() > self.capacity) {
            const ltail = self.lru.last.?; // never empty while over capacity
            const tail: *LruNode = @fieldParentPtr("lru", ltail);
            self.lru.remove(ltail);
            _ = self.map.remove(tail.id);
            tail.table.release(); // the cache's ref; live readers keep theirs
            self.allocator.destroy(tail);
        }
    }
};

// ========================= tests =========================

fn buildTable(allocator: std.mem.Allocator, io: std.Io, dir: disk.Dir, id: u64) !void {
    const tb_mod = @import("../sstable/table_builder.zig");
    const ik = @import("../util/internal_key.zig");
    var tb = try tb_mod.TableBuilder.init(allocator, .{});
    defer tb.deinit();
    var ikbuf: [64]u8 = undefined;
    const ikl = try ik.encode("k", 1, .put, &ikbuf);
    var iv: [21]u8 = @splat(0); // inline header, empty value
    iv[0] = 0b010;
    try tb.add(ikbuf[0..ikl], &iv);
    const img = try tb.finish();
    var namebuf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&namebuf, "{d:0>6}.sst", .{id}) catch unreachable;
    const f = try dir.createFile(io, name, .{ .read = true, .truncate = true, .exclusive = true });
    defer f.close(io);
    try disk.pwriteAll(f, io, img, 0);
}

test "table_cache: hits share one table; eviction drops only the cache reference" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try buildTable(allocator, io, tmp.dir, 7);
    try buildTable(allocator, io, tmp.dir, 8);
    try buildTable(allocator, io, tmp.dir, 9);

    var c = TableCache.init(allocator, io, 2, 1024);
    defer c.deinit();

    // Hit: same table, caller ref on top of the cache's.
    const t7 = try c.acquire(tmp.dir, 7);
    const t7b = try c.acquire(tmp.dir, 7);
    try std.testing.expect(t7 == t7b);
    try std.testing.expectEqual(@as(u32, 3), t7.refCount()); // cache + 2 callers
    t7.release();
    t7b.release();
    try std.testing.expectEqual(@as(u32, 1), t7.refCount()); // cache only

    // Insert a third table: the untouched 7 (LRU tail) goes first.
    const t8 = try c.acquire(tmp.dir, 8); // held across the evictions below
    const t9 = try c.acquire(tmp.dir, 9);
    t9.release();
    try std.testing.expectEqual(@as(u32, 2), t8.refCount()); // cache + us

    // Reopening 7 proves it was evicted, and evicts 8 next (LRU order).
    const t7c = try c.acquire(tmp.dir, 7);
    try std.testing.expectEqual(@as(u32, 2), t7c.refCount()); // fresh: cache + us
    t7c.release();
    try std.testing.expectEqual(@as(u32, 1), t8.refCount()); // cache let go; our ref keeps it alive
    t8.release();
}

fn acquireWithFailures(allocator: std.mem.Allocator, dir: disk.Dir) !void {
    var cache = TableCache.init(allocator, std.testing.io, 1, 1024);
    defer cache.deinit();
    const table = try cache.acquire(dir, 7);
    defer table.release();
}

test "table_cache: allocation failures release opened tables and remove incomplete map entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try buildTable(std.testing.allocator, std.testing.io, tmp.dir, 7);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, acquireWithFailures, .{tmp.dir});
}
