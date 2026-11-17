//! One MemTable owns one ArenaAllocator, and every skip-list node lives in it.
//! The table also carries the byte counter the write path freezes on. The list
//! keeps a pointer into this struct's arena field, so it is only initialized
//! after the table sits at its final (heap) address — value-moving `create`
//! first, backfill second.

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const internal_key = @import("../util/internal_key.zig");
const refcount = @import("../util/refcount.zig");
const skiplist = @import("skiplist.zig");
const coding = @import("../util/coding.zig");
const rand = @import("../util/rand.zig");

const SL = skiplist.SkipList(internal_key.compareParts);

pub const MemTable = struct {
    arena: ArenaAllocator,
    /// `list.arena` points at the field above (see file header).
    list: SL,
    approx_bytes: std.atomic.Value(usize),

    fn destroy(self: *MemTable) void {
        const holder: *Holder = @fieldParentPtr("data", self);
        const gpa = self.arena.child_allocator;
        self.arena.deinit(); // every node at once — no per-node free
        gpa.destroy(holder);
    }

    pub const Holder = refcount.RefCounted(MemTable, destroy);
    pub const Iterator = SL.Iterator;

    /// Borrowed entries remain valid while the caller holds a table reference.
    pub fn iterator(self: *MemTable) Iterator {
        return self.list.iterator();
    }

    pub fn create(gpa: std.mem.Allocator, seed: u64) !*Holder {
        const table = MemTable{
            .arena = ArenaAllocator.init(gpa),
            .list = undefined,
            .approx_bytes = .init(0),
        };
        const holder = try Holder.create(gpa, table);
        errdefer holder.release(); // runs destroy on the SL.init failure below
        holder.data.list = try SL.init(&holder.data.arena, seed);
        return holder;
    }

    pub fn put(self: *MemTable, seq: u64, user_key: []const u8, value: []const u8) !void {
        try self.putParts(seq, user_key, value, "");
    }

    /// Copies both borrowed slices into one contiguous, table-owned value.
    pub fn putParts(self: *MemTable, seq: u64, user_key: []const u8, header: []const u8, payload: []const u8) !void {
        try self.insert(.put, seq, user_key, header, payload);
    }

    /// Tombstone: the stored value is empty; visibility lives in the kind byte.
    pub fn delete(self: *MemTable, seq: u64, user_key: []const u8) !void {
        try self.insert(.delete, seq, user_key, "", "");
    }

    fn insert(
        self: *MemTable,
        kind: internal_key.Kind,
        seq: u64,
        user_key: []const u8,
        header: []const u8,
        payload: []const u8,
    ) !void {
        try self.list.insertParts(user_key, seq, kind, header, payload);
        // +9 suffix, varints and padding are inside the content; +64 is the
        // per-entry index overhead estimate (towers included on average).
        _ = self.approx_bytes.fetchAdd(
            user_key.len + header.len + payload.len + internal_key.suffix_len + 64,
            .monotonic,
        );
    }
    /// The value visible at `snapshot`, or null when the newest visible entry
    /// is a tombstone or nothing here holds the key. With one visibility
    /// watermark the first entry at or after (user, snapshot, .put) IS the
    /// newest visible one, so that single node decides — no same-user scan.
    /// The slice points into the arena: stable while a ref is held.
    pub fn get(self: *MemTable, user_key: []const u8, snapshot: u64) ?[]const u8 {
        const entry = self.getEntry(user_key, snapshot) orelse return null;
        return if (entry.deleted) null else entry.value;
    }

    pub const Entry = struct {
        deleted: bool,
        /// The stored InternalValue bytes for a put; empty for a delete.
        value: []const u8,
    };

    /// Like get, but a tombstone arrives as its own state instead of
    /// being indistinguishable from absence: a multi-table scan must
    /// stop at the newest tombstone rather than fall through to older
    /// tables.
    pub fn getEntry(self: *MemTable, user_key: []const u8, snapshot: u64) ?Entry {
        var it = self.list.iterator();
        it.seek(user_key, snapshot, .put);
        const n = it.node orelse return null;
        const view = internal_key.decode(SL.nodeKey(n)) catch unreachable;
        if (!std.mem.eql(u8, view.user, user_key)) return null;
        return .{ .deleted = view.kind == .delete, .value = SL.nodeValue(n) };
    }
};

test "get: one watermark decides visibility; tombstones shadow" {
    const holder = try MemTable.create(std.testing.allocator, 11);
    defer holder.release();
    try std.testing.expectEqual(@as(u32, 1), holder.refCount());
    const mt = &holder.data;

    try mt.put(1, "k", "v1");
    try mt.put(5, "k", "v2");
    try mt.put(3, "j", "vj");

    try std.testing.expect(mt.get("k", 0) == null); // below every seq
    try std.testing.expectEqualStrings("v1", mt.get("k", 1).?);
    try std.testing.expectEqualStrings("v1", mt.get("k", 4).?); // seq 5 not visible yet
    try std.testing.expectEqualStrings("v2", mt.get("k", 5).?);
    try std.testing.expectEqualStrings("v2", mt.get("k", 99).?);
    try std.testing.expect(mt.get("absent", 99) == null);

    try mt.delete(7, "k");
    try std.testing.expectEqualStrings("v2", mt.get("k", 6).?); // tombstone not visible yet
    try std.testing.expect(mt.get("k", 7) == null);
    try std.testing.expectEqualStrings("vj", mt.get("j", 99).?); // neighbor untouched
}

test "approx bytes include entries and tombstones" {
    const holder = try MemTable.create(std.testing.allocator, 22);
    defer holder.release();
    const mt = &holder.data;

    try mt.put(1, "some-key", "0123456789");
    const put_size = 8 + 10 + internal_key.suffix_len + 64;
    try std.testing.expectEqual(@as(usize, put_size), mt.approx_bytes.load(.monotonic));
    try mt.delete(2, "some-key");
    const delete_size = 8 + internal_key.suffix_len + 64;
    try std.testing.expectEqual(@as(usize, put_size + delete_size), mt.approx_bytes.load(.monotonic));
}

fn checksumValue(out: *[16]u8, idx: usize) []const u8 {
    coding.putU64(out[0..8], idx);
    coding.putU64(out[8..16], ~idx);
    return out;
}

test "memtable: split insertion owns inputs and accounts only successful values" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const holder = try MemTable.create(failing.allocator(), 41);
    defer holder.release();
    const mt = &holder.data;
    var header = [_]u8{ 'h', 'd', 'r' };
    var payload = [_]u8{ 'b', 'o', 'd', 'y' };
    try mt.putParts(1, "k", &header, &payload);
    @memset(&header, 'x');
    @memset(&payload, 'y');
    try std.testing.expectEqualStrings("hdrbody", mt.get("k", 1).?);
    const before = mt.approx_bytes.load(.monotonic);
    try std.testing.expectEqual(@as(usize, 1 + 7 + internal_key.suffix_len + 64), before);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    const large: [64 * 1024]u8 = @splat(0xab);
    try std.testing.expectError(error.OutOfMemory, mt.putParts(2, "k", &header, &large));
    try std.testing.expectEqual(before, mt.approx_bytes.load(.monotonic));
    try std.testing.expectEqualStrings("hdrbody", mt.get("k", 2).?);
    var it = mt.iterator();
    it.seekToFirst();
    try std.testing.expectEqual(@as(u64, 1), (try internal_key.decode(it.key())).seq);
    it.next();
    try std.testing.expect(!it.valid());

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try mt.putParts(2, "k", &header, &large);
    try std.testing.expectEqual(@as(usize, header.len + large.len), mt.get("k", 2).?.len);
}

fn createSplitWithFailures(allocator: std.mem.Allocator) !void {
    const holder = try MemTable.create(allocator, 42);
    defer holder.release();
    const payload: [4096]u8 = @splat('p');
    try holder.data.putParts(1, "key", "header", &payload);
    const stored = holder.data.get("key", 1).?;
    try std.testing.expectEqualStrings("header", stored[0..6]);
    try std.testing.expectEqualSlices(u8, &payload, stored[6..]);
}

test "memtable: split insertion cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createSplitWithFailures, .{});
}

/// Full ordered walk; null = some invariant broke (undecodable node or
/// non-increasing user keys). Readers run this live while the writer inserts.
fn walkVerify(mt: *MemTable) ?usize {
    var it = mt.list.iterator();
    it.seekToFirst();
    var count: usize = 0;
    var prev: ?[]const u8 = null;
    while (it.valid()) : (it.next()) {
        const view = internal_key.decode(SL.nodeKey(it.node.?)) catch return null;
        if (prev) |p| {
            if (std.mem.order(u8, p, view.user) != .lt) return null;
        }
        prev = view.user;
        count += 1;
    }
    return count;
}

fn reader(
    mt: *MemTable,
    failed: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),
    seed: u64,
) void {
    var rng = rand.Rand.init(seed);
    while (!done.load(.acquire)) {
        const idx: usize = @intCast(rng.below(4_000));
        var ub: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&ub, "k{d:0>6}", .{idx}) catch unreachable;
        if (mt.get(key, 5_000)) |v| {
            var want: [16]u8 = undefined;
            _ = checksumValue(&want, idx);
            if (!std.mem.eql(u8, v, &want)) { // a torn or interleaved value
                failed.store(true, .release);
                return;
            }
        }
        if (rng.below(8) == 0) {
            if (walkVerify(mt) == null) {
                failed.store(true, .release);
                return;
            }
        }
    }
}

test "one writer plus lock-free readers: no torn values, order always holds" {
    const holder = try MemTable.create(std.testing.allocator, 0xC0FFEE);
    defer holder.release();
    const mt = &holder.data;

    const n: usize = 4_000;
    var failed = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, reader, .{ mt, &failed, &done, 1000 + i });
    }

    var vbuf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var ub: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&ub, "k{d:0>6}", .{i});
        const value = checksumValue(&vbuf, i);
        try mt.putParts(@intCast(i + 1), key, value[0..8], value[8..]);
    }
    done.store(true, .release);
    for (threads) |t| t.join();

    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, n), walkVerify(mt).?);
    var key_buf: [16]u8 = undefined;
    var c: usize = 0;
    while (c < n) : (c += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "k{d:0>6}", .{c});
        const got = mt.get(key, n + 1);
        try std.testing.expect(got != null);
        var want: [16]u8 = undefined;
        _ = checksumValue(&want, c);
        try std.testing.expectEqualSlices(u8, &want, got.?);
    }
}
