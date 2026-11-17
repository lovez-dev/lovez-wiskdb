//! Byte-budgeted cache of immutable SST blocks and validated VLog records.
//! Shared concurrent use requires an allocator that supports concurrent calls.
const std = @import("std");
const lp = @import("../util/lock_profile.zig");

pub const Key = struct { file_id: u64, offset: u64 };
/// Immutable block bytes and their complete allocation, including any trailer.
/// allocator must remain valid until the cache releases this allocation.
pub const OwnedBytes = struct {
    data: []u8,
    allocation: []u8,
    allocator: std.mem.Allocator,
};
const Entry = struct {
    key: Key,
    data: []u8,
    allocation: []u8,
    data_allocator: std.mem.Allocator,
    refs: usize = 0,
    lru: std.DoublyLinkedList.Node = .{},
};

pub const Handle = struct {
    cache: *Shard,
    entry: *Entry,

    pub fn bytes(self: Handle) []const u8 {
        return self.entry.data;
    }
    pub fn release(self: *Handle) void {
        var guard = self.cache.release_profile.lock(&self.cache.mutex, self.cache.io);
        self.entry.refs -= 1;
        guard.unlock();
        self.* = undefined;
    }
};

pub const Stats = struct { hits: u64, misses: u64, evictions: u64, bytes: usize };

pub const Shard = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    capacity: usize,
    used: usize = 0,
    map: std.AutoHashMap(Key, *Entry),
    lru: std.DoublyLinkedList = .{},
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    lookup_profile: lp.Profile = .{},
    insert_profile: lp.Profile = .{},
    release_profile: lp.Profile = .{},
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) Shard {
        return .{ .allocator = allocator, .io = io, .capacity = @max(capacity, 1), .map = std.AutoHashMap(Key, *Entry).init(allocator) };
    }

    pub fn deinit(self: *Shard) void {
        self.mutex.lockUncancelable(self.io);
        var it = self.map.valueIterator();
        while (it.next()) |entry| {
            entry.*.data_allocator.free(entry.*.allocation);
            self.allocator.destroy(entry.*);
        }
        self.mutex.unlock(self.io);
        self.map.deinit();
    }

    pub fn acquire(self: *Shard, key: Key) ?Handle {
        var guard = self.lookup_profile.lock(&self.mutex, self.io);
        defer guard.unlock();
        if (self.map.get(key)) |entry| {
            self.hits += 1;
            entry.refs += 1;
            self.lru.remove(&entry.lru);
            self.lru.prepend(&entry.lru);
            return .{ .cache = self, .entry = entry };
        }
        self.misses += 1;
        return null;
    }

    pub fn insertCopy(self: *Shard, key: Key, bytes: []const u8) !Handle {
        const data = try self.allocator.dupe(u8, bytes);
        return self.insertOwned(key, .{ .data = data, .allocation = data, .allocator = self.allocator });
    }

    /// Always consumes owned, including allocation failures and duplicate losers.
    /// data must be contained in allocation, which must be the complete slice
    /// returned by owned.allocator. The budget counts retained allocation bytes.
    pub fn insertOwned(self: *Shard, key: Key, owned: OwnedBytes) !Handle {
        const candidate = self.allocator.create(Entry) catch |err| {
            owned.allocator.free(owned.allocation);
            return err;
        };
        candidate.* = .{ .key = key, .data = owned.data, .allocation = owned.allocation, .data_allocator = owned.allocator, .refs = 1 };
        var published = false;
        // Registered before the guard: failures and duplicate losers free
        // their private candidate only AFTER releasing the cache mutex.
        defer if (!published) {
            owned.allocator.free(owned.allocation);
            self.allocator.destroy(candidate);
        };
        var retired: std.DoublyLinkedList = .{};
        // The list owns detached, unreferenced entries; no allocation is
        // needed to defer their destruction until after the guard unlocks.
        defer self.destroyRetired(&retired);
        var guard = self.insert_profile.lock(&self.mutex, self.io);
        defer guard.unlock();
        if (self.map.get(key)) |entry| {
            entry.refs += 1;
            return .{ .cache = self, .entry = entry };
        }
        try self.map.put(key, candidate);
        published = true;
        self.lru.prepend(&candidate.lru);
        self.used += owned.allocation.len;
        self.evictLocked(&retired);
        return .{ .cache = self, .entry = candidate };
    }

    fn evictLocked(self: *Shard, retired: *std.DoublyLinkedList) void {
        while (self.used > self.capacity) {
            var node = self.lru.last orelse break;
            var victim: ?*Entry = null;
            while (true) : (node = node.prev orelse break) {
                const entry: *Entry = @fieldParentPtr("lru", node);
                if (entry.refs == 0) {
                    victim = entry;
                    break;
                }
            }
            const entry = victim orelse break;
            self.lru.remove(&entry.lru);
            _ = self.map.remove(entry.key);
            self.used -= entry.allocation.len;
            self.evictions += 1;
            retired.append(&entry.lru);
        }
    }

    fn destroyRetired(self: *Shard, retired: *std.DoublyLinkedList) void {
        while (retired.pop()) |node| {
            const entry: *Entry = @fieldParentPtr("lru", node);
            entry.data_allocator.free(entry.allocation);
            self.allocator.destroy(entry);
        }
    }

    pub fn stats(self: *Shard) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .hits = self.hits, .misses = self.misses, .evictions = self.evictions, .bytes = self.used };
    }

    pub fn invalidateFile(self: *Shard, file_id: u64) void {
        self.mutex.lockUncancelable(self.io);
        var keys: std.ArrayListUnmanaged(Key) = .empty;
        var it = self.map.iterator();
        while (it.next()) |item| {
            if (item.key_ptr.file_id != file_id) continue;
            const entry = item.value_ptr.*;
            if (entry.refs != 0) continue;
            keys.append(self.allocator, item.key_ptr.*) catch continue;
        }
        for (keys.items) |key| {
            if (self.map.fetchRemove(key)) |kv| {
                const entry = kv.value;
                self.lru.remove(&entry.lru);
                self.used -= entry.allocation.len;
                entry.data_allocator.free(entry.allocation);
                self.allocator.destroy(entry);
            }
        }
        keys.deinit(self.allocator);
        self.mutex.unlock(self.io);
    }
};

/// Independently locked byte-budgeted LRUs. Keep this object at a stable
/// address while any returned handle exists. Hashing never depends on padding.
pub const BlockCache = struct {
    pub const max_shards = 16;
    shards: [max_shards]Shard = undefined,
    shard_count: usize,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) BlockCache {
        return initSharded(allocator, io, capacity, 1);
    }

    pub fn initSharded(allocator: std.mem.Allocator, io: std.Io, capacity: usize, count: usize) BlockCache {
        std.debug.assert(count > 0 and count <= max_shards and std.math.isPowerOfTwo(count));
        var cache = BlockCache{ .shard_count = count };
        for (cache.shards[0..count], 0..) |*shard, i| {
            shard.* = Shard.init(allocator, io, capacity / count);
            shard.capacity = capacity / count + @intFromBool(i < capacity % count);
        }
        return cache;
    }

    fn shardIndex(self: *const BlockCache, key: Key) usize {
        if (self.shard_count == 1) return 0;
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u64, bytes[0..8], key.file_id, .little);
        std.mem.writeInt(u64, bytes[8..16], key.offset, .little);
        return @intCast(std.hash.Wyhash.hash(0, &bytes) & (self.shard_count - 1));
    }

    pub fn acquire(self: *BlockCache, key: Key) ?Handle {
        return self.shards[self.shardIndex(key)].acquire(key);
    }

    /// Immutable shard budgets can be checked without locking. Admission callers
    /// can bypass zero budgets and entries that cannot fit even in an empty shard.
    pub fn canStore(self: *const BlockCache, key: Key, len: usize) bool {
        const capacity = self.shards[self.shardIndex(key)].capacity;
        return capacity > 0 and len <= capacity;
    }

    pub fn insertCopy(self: *BlockCache, key: Key, bytes: []const u8) !Handle {
        return self.shards[self.shardIndex(key)].insertCopy(key, bytes);
    }

    /// Always consumes owned, including on failure; see Shard.insertOwned.
    pub fn insertOwned(self: *BlockCache, key: Key, owned: OwnedBytes) !Handle {
        return self.shards[self.shardIndex(key)].insertOwned(key, owned);
    }

    pub fn deinit(self: *BlockCache) void {
        for (self.shards[0..self.shard_count]) |*shard| shard.deinit();
    }

    pub fn invalidateFile(self: *BlockCache, id: u64) void {
        for (self.shards[0..self.shard_count]) |*shard| shard.invalidateFile(id);
    }

    /// Sequential per-shard snapshots; not globally atomic.
    pub fn stats(self: *BlockCache) Stats {
        var total = Stats{ .hits = 0, .misses = 0, .evictions = 0, .bytes = 0 };
        for (self.shards[0..self.shard_count]) |*shard| {
            const s = shard.stats();
            total.hits += s.hits;
            total.misses += s.misses;
            total.evictions += s.evictions;
            total.bytes += s.bytes;
        }
        return total;
    }

    pub fn enableProfiling(self: *BlockCache, enabled: bool) void {
        for (self.shards[0..self.shard_count]) |*shard| {
            shard.lookup_profile.enabled = enabled;
            shard.insert_profile.enabled = enabled;
            shard.release_profile.enabled = enabled;
        }
    }

    pub const Profiles = struct { lookup: lp.Stats = .{}, insert: lp.Stats = .{}, release: lp.Stats = .{} };

    pub fn profiles(self: *BlockCache) Profiles {
        var total = Profiles{};
        for (self.shards[0..self.shard_count]) |*shard| {
            shard.mutex.lockUncancelable(shard.io);
            defer shard.mutex.unlock(shard.io);
            addProfile(&total.lookup, shard.lookup_profile.counters);
            addProfile(&total.insert, shard.insert_profile.counters);
            addProfile(&total.release, shard.release_profile.counters);
        }
        return total;
    }

    fn addProfile(total: *lp.Stats, source: lp.Stats) void {
        inline for (.{ "acquisitions", "wait_ns", "hold_ns", "wait_ge_1us", "wait_ge_10us" }) |name| {
            @field(total, name) += @field(source, name);
        }
        total.max_wait_ns = @max(total.max_wait_ns, source.max_wait_ns);
        total.max_hold_ns = @max(total.max_hold_ns, source.max_hold_ns);
    }
};

test "cache admission respects zero and per-shard byte budgets" {
    var cache = BlockCache.initSharded(std.testing.allocator, std.testing.io, 3, 4);
    defer cache.deinit();
    var saw_zero = false;
    var saw_nonzero = false;
    for (0..100) |offset| {
        const key = Key{ .file_id = 1, .offset = offset };
        const capacity = cache.shards[cache.shardIndex(key)].capacity;
        try std.testing.expect(!cache.canStore(key, 2));
        if (capacity == 0) {
            saw_zero = true;
            try std.testing.expect(!cache.canStore(key, 0));
        } else {
            saw_nonzero = true;
            try std.testing.expect(cache.canStore(key, 1));
        }
    }
    try std.testing.expect(saw_zero and saw_nonzero);
}

test "sharded cache: exact total budget routing invalidation and aggregated profiles" {
    var cache = BlockCache.initSharded(std.testing.allocator, std.testing.io, 19, 4);
    defer cache.deinit();
    cache.enableProfiling(true);
    var budget: usize = 0;
    for (cache.shards[0..4]) |shard| budget += shard.capacity;
    try std.testing.expectEqual(@as(usize, 19), budget);
    var offsets: [4]u64 = undefined;
    var seen: [4]bool = @splat(false);
    for (0..1000) |offset| {
        const index = cache.shardIndex(.{ .file_id = 7, .offset = offset });
        seen[index] = true;
        offsets[index] = offset;
    }
    for (seen) |value| try std.testing.expect(value);
    for (offsets) |offset| {
        const key = Key{ .file_id = 7, .offset = offset };
        var handle = try cache.insertCopy(key, "abcd");
        handle.release();
        var hit = cache.acquire(key).?;
        hit.release();
    }
    try std.testing.expectEqual(@as(usize, 16), cache.stats().bytes);
    try std.testing.expectEqual(@as(u64, 4), cache.stats().hits);
    const profiles = cache.profiles();
    try std.testing.expectEqual(@as(u64, 4), profiles.lookup.acquisitions);
    try std.testing.expectEqual(@as(u64, 4), profiles.insert.acquisitions);
    try std.testing.expectEqual(@as(u64, 8), profiles.release.acquisitions);
    cache.invalidateFile(7);
    try std.testing.expectEqual(@as(usize, 0), cache.stats().bytes);
    for (offsets) |offset| try std.testing.expect(cache.acquire(.{ .file_id = 7, .offset = offset }) == null);
}

test "sharded cache: tiny budgets never round total capacity upward" {
    var cache = BlockCache.initSharded(std.testing.allocator, std.testing.io, 2, 16);
    defer cache.deinit();
    var sum: usize = 0;
    for (cache.shards[0..16]) |shard| sum += shard.capacity;
    try std.testing.expectEqual(@as(usize, 2), sum);
}

test "sharded cache: per shard budgets cannot borrow unused capacity" {
    var cache = BlockCache.initSharded(std.testing.allocator, std.testing.io, 16, 4);
    defer cache.deinit();
    var offsets: [2]u64 = undefined;
    var found: usize = 0;
    for (0..100) |offset| {
        if (cache.shardIndex(.{ .file_id = 1, .offset = offset }) != 0) continue;
        offsets[found] = offset;
        found += 1;
        if (found == offsets.len) break;
    }
    try std.testing.expectEqual(@as(usize, 2), found);
    for (offsets) |offset| {
        var handle = try cache.insertCopy(.{ .file_id = 1, .offset = offset }, "abcd");
        handle.release();
    }
    try std.testing.expectEqual(@as(u64, 1), cache.stats().evictions);
    try std.testing.expectEqual(@as(usize, 4), cache.stats().bytes);
    try std.testing.expect(cache.acquire(.{ .file_id = 1, .offset = offsets[0] }) == null);
    var newest = cache.acquire(.{ .file_id = 1, .offset = offsets[1] }).?;
    newest.release();
}

test "sharded cache: profile totals sum and maxima do not" {
    var cache = BlockCache.initSharded(std.testing.allocator, std.testing.io, 16, 2);
    defer cache.deinit();
    cache.shards[0].lookup_profile.counters = .{ .acquisitions = 3, .wait_ns = 10, .max_wait_ns = 7, .max_hold_ns = 4 };
    cache.shards[1].lookup_profile.counters = .{ .acquisitions = 5, .wait_ns = 20, .max_wait_ns = 11, .max_hold_ns = 3 };
    const profile = cache.profiles().lookup;
    try std.testing.expectEqual(@as(u64, 8), profile.acquisitions);
    try std.testing.expectEqual(@as(u64, 30), profile.wait_ns);
    try std.testing.expectEqual(@as(u64, 11), profile.max_wait_ns);
    try std.testing.expectEqual(@as(u64, 4), profile.max_hold_ns);
}

fn fillShards(allocator: std.mem.Allocator) !void {
    var cache = BlockCache.initSharded(allocator, std.testing.io, 256, 4);
    defer cache.deinit();
    for (0..64) |offset| {
        var handle = try cache.insertCopy(.{ .file_id = 1, .offset = offset }, "abcd");
        handle.release();
    }
}

test "sharded cache: all insertion allocation failures release shard state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, fillShards, .{});
}

test "block cache: handles keep entries alive across eviction" {
    var cache = Shard.init(std.testing.allocator, std.testing.io, 4);
    defer cache.deinit();
    var first = try cache.insertCopy(.{ .file_id = 1, .offset = 0 }, "abcd");
    var second = try cache.insertCopy(.{ .file_id = 1, .offset = 4 }, "efgh");
    try std.testing.expectEqualStrings("abcd", first.bytes());
    try std.testing.expectEqual(@as(usize, 8), cache.stats().bytes);
    first.release();
    second.release();
    var third = try cache.insertCopy(.{ .file_id = 1, .offset = 8 }, "ijkl");
    third.release();
    const stats = cache.stats();
    try std.testing.expect(stats.evictions > 0);
}

test "block cache: misses hits and evictions account for a byte limited workload" {
    var cache = Shard.init(std.testing.allocator, std.testing.io, 4);
    defer cache.deinit();
    const first_key = Key{ .file_id = 1, .offset = 0 };
    try std.testing.expect(cache.acquire(first_key) == null);
    var first = try cache.insertCopy(first_key, "abcd");
    first.release();
    var hit = cache.acquire(first_key).?;
    hit.release();
    var second = try cache.insertCopy(.{ .file_id = 2, .offset = 0 }, "efgh");
    second.release();
    const counters = cache.stats();
    try std.testing.expectEqual(@as(u64, 1), counters.hits);
    try std.testing.expectEqual(@as(u64, 1), counters.misses);
    try std.testing.expectEqual(@as(u64, 1), counters.evictions);
    try std.testing.expectEqual(@as(usize, 4), counters.bytes);
}

fn insertWithFailures(allocator: std.mem.Allocator) !void {
    var cache = Shard.init(allocator, std.testing.io, 4);
    defer cache.deinit();
    for (0..20) |i| {
        var handle = try cache.insertCopy(.{ .file_id = 1, .offset = i }, "abcd");
        defer handle.release();
        try std.testing.expectEqualStrings("abcd", handle.bytes());
    }
}

test "block cache: allocation failures free candidates before and during map publication" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, insertWithFailures, .{});
}

test "block cache: owned slices retain their backing allocator and budget trailers" {
    const CountingAllocator = @import("../util/counting_allocator.zig").CountingAllocator;
    var owner = CountingAllocator{ .parent = std.testing.allocator };
    var cache = BlockCache.init(std.testing.allocator, std.testing.io, 9);
    {
        defer cache.deinit();
        const allocation = try owner.allocator().dupe(u8, "!dataTAIL");
        var first = try cache.insertOwned(.{ .file_id = 1, .offset = 0 }, .{ .data = allocation[1..5], .allocation = allocation, .allocator = owner.allocator() });
        defer first.release();
        try std.testing.expectEqual(allocation.ptr + 1, first.bytes().ptr);
        try std.testing.expectEqualStrings("data", first.bytes());
        try std.testing.expectEqual(@as(usize, 9), cache.stats().bytes);
        const ignored = try owner.allocator().dupe(u8, "ignored");
        var duplicate = try cache.insertOwned(.{ .file_id = 1, .offset = 0 }, .{ .data = ignored, .allocation = ignored, .allocator = owner.allocator() });
        defer duplicate.release();
        try std.testing.expectEqual(first.entry, duplicate.entry);
        try std.testing.expectEqual(@as(usize, 9), owner.stats().allocated_bytes);
        // Both handles protect the complete allocation, even over budget.
        var other = try cache.insertCopy(.{ .file_id = 2, .offset = 0 }, "other");
        other.release();
        try std.testing.expectEqual(@as(usize, 14), cache.stats().bytes);
        try std.testing.expectEqualStrings("data", first.bytes());
        cache.invalidateFile(1);
        try std.testing.expectEqual(@as(usize, 9), owner.stats().allocated_bytes);
    }
    try std.testing.expectEqual(@as(usize, 0), owner.stats().allocated_bytes);
}

fn ownedWithFailures(allocator: std.mem.Allocator) !void {
    const CountingAllocator = @import("../util/counting_allocator.zig").CountingAllocator;
    var owner = CountingAllocator{ .parent = std.testing.allocator };
    defer std.testing.expectEqual(@as(usize, 0), owner.stats().allocated_bytes) catch @panic("owned allocation leaked");
    var cache = Shard.init(allocator, std.testing.io, 9);
    defer cache.deinit();
    for (0..20) |i| {
        const allocation = try owner.allocator().dupe(u8, "dataTAIL");
        var handle = try cache.insertOwned(.{ .file_id = 1, .offset = i }, .{ .data = allocation[0..4], .allocation = allocation, .allocator = owner.allocator() });
        handle.release();
    }
}

test "block cache: owned insertion consumes input through every cache allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownedWithFailures, .{});
}

test "block cache: concurrent duplicate insertions share one immutable entry" {
    const Context = struct {
        cache: *Shard,
        start: *std.atomic.Value(bool),
        handle: ?Handle = null,
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            while (!ctx.start.load(.acquire)) std.atomic.spinLoopHint();
            ctx.handle = ctx.cache.insertCopy(.{ .file_id = 7, .offset = 0 }, "abcd") catch |err| {
                ctx.failure = err;
                return;
            };
        }
    };
    var cache = Shard.init(std.testing.allocator, std.testing.io, 4);
    defer cache.deinit();
    var start = std.atomic.Value(bool).init(false);
    var contexts: [8]Context = undefined;
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    {
        defer {
            start.store(true, .release);
            for (threads[0..started]) |thread| thread.join();
        }
        for (&contexts, 0..) |*ctx, i| {
            ctx.* = .{ .cache = &cache, .start = &start };
            threads[i] = try std.Thread.spawn(.{}, Context.run, .{ctx});
            started += 1;
        }
    }
    defer for (contexts[0..started]) |*ctx| if (ctx.handle) |*handle| handle.release();
    for (contexts[0..started]) |ctx| if (ctx.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), cache.map.count());
    try std.testing.expectEqual(@as(usize, 4), cache.stats().bytes);
    for (contexts[0..started]) |ctx| {
        try std.testing.expectEqual(contexts[0].handle.?.entry, ctx.handle.?.entry);
        try std.testing.expectEqualStrings("abcd", ctx.handle.?.bytes());
    }
    try std.testing.expectEqual(@as(usize, 8), contexts[0].handle.?.entry.refs);
    // All holders remain valid while a different inserted block exceeds budget.
    var other = try cache.insertCopy(.{ .file_id = 8, .offset = 0 }, "efgh");
    other.release();
    for (contexts[0..started]) |ctx| try std.testing.expectEqualStrings("abcd", ctx.handle.?.bytes());
    for (contexts[0..started]) |*ctx| {
        ctx.handle.?.release();
        ctx.handle = null;
    }
    var final = try cache.insertCopy(.{ .file_id = 9, .offset = 0 }, "ijkl");
    final.release();
    try std.testing.expectEqual(@as(usize, 4), cache.stats().bytes);
    try std.testing.expect(cache.stats().evictions >= 2);
}

test "block cache: candidate allocation duplicate cleanup and victim frees run outside mutex" {
    const WatchingAllocator = struct {
        mutex: *std.Io.Mutex = undefined,
        allocations: usize = 0,
        check_frees: bool = false,
        frees: usize = 0,
        locked_allocation: bool = false,
        locked_free: bool = false,

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.allocations < 2) {
                if (self.mutex.tryLock()) self.mutex.unlock(std.testing.io) else self.locked_allocation = true;
            }
            self.allocations += 1;
            return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
        }
        fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.check_frees) {
                if (self.mutex.tryLock()) self.mutex.unlock(std.testing.io) else self.locked_free = true;
                self.frees += 1;
            }
            std.testing.allocator.rawFree(bytes, alignment, ret_addr);
        }
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
    };
    var watching = WatchingAllocator{};
    var cache = Shard.init(watching.allocator(), std.testing.io, 1024);
    watching.mutex = &cache.mutex;
    defer cache.deinit();
    var first = try cache.insertCopy(.{ .file_id = 1, .offset = 0 }, "original");
    defer first.release();
    try std.testing.expect(!watching.locked_allocation);
    watching.allocations = 0;
    watching.check_frees = true;
    var duplicate = try cache.insertCopy(.{ .file_id = 1, .offset = 0 }, "ignored");
    watching.check_frees = false;
    defer duplicate.release();
    try std.testing.expectEqual(first.entry, duplicate.entry);
    try std.testing.expectEqualStrings("original", duplicate.bytes());
    try std.testing.expectEqual(@as(usize, 2), watching.frees);
    try std.testing.expect(!watching.locked_allocation);
    try std.testing.expect(!watching.locked_free);
    // Keep the original pinned while several other entries accumulate.
    for (2..5) |id| {
        var extra = try cache.insertCopy(.{ .file_id = id, .offset = 0 }, "abcd");
        extra.release();
    }
    cache.capacity = 4;
    watching.frees = 0;
    watching.check_frees = true;
    var last = try cache.insertCopy(.{ .file_id = 5, .offset = 0 }, "efgh");
    watching.check_frees = false;
    defer last.release();
    try std.testing.expectEqual(@as(usize, 6), watching.frees);
    try std.testing.expect(!watching.locked_free);
    try std.testing.expectEqual(@as(u64, 3), cache.stats().evictions);
    try std.testing.expectEqualStrings("original", first.bytes());
    try std.testing.expectEqualStrings("original", duplicate.bytes());
}

test "block cache: concurrent churn keeps pinned bytes valid during detached destruction" {
    const Context = struct {
        cache: *Shard,
        id: u64,
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            ctx.exercise() catch |err| {
                ctx.failure = err;
            };
        }
        fn exercise(ctx: *@This()) !void {
            for (0..200) |i| {
                var bytes: [32]u8 = @splat(@as(u8, @intCast(ctx.id)));
                var handle = try ctx.cache.insertCopy(.{ .file_id = ctx.id, .offset = i }, &bytes);
                defer handle.release();
                try std.testing.expectEqualSlices(u8, &bytes, handle.bytes());
            }
        }
    };
    var cache = Shard.init(std.testing.allocator, std.testing.io, 64);
    defer cache.deinit();
    var contexts: [4]Context = undefined;
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    {
        defer for (threads[0..started]) |thread| thread.join();
        for (&contexts, 0..) |*ctx, i| {
            ctx.* = .{ .cache = &cache, .id = i };
            threads[i] = try std.Thread.spawn(.{}, Context.run, .{ctx});
            started += 1;
        }
    }
    for (contexts) |ctx| if (ctx.failure) |err| return err;
    var last = try cache.insertCopy(.{ .file_id = 100, .offset = 0 }, "final");
    last.release();
    try std.testing.expect(cache.stats().bytes <= 64);
    try std.testing.expect(cache.stats().evictions > 0);
}
