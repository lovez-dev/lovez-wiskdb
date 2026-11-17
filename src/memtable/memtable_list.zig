//! The current MemTable plus the FIFO immutable queue behind one leaf
//! mutex. Database-level backpressure uses Db.write_cond. Pointer load and
//! refcount bump are always consecutive under this lock: a flush could
//! otherwise pop and destroy a table between a reader's two steps.

const std = @import("std");
const MemTable = @import("../memtable/memtable.zig").MemTable;

pub const List = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    current: *MemTable.Holder,
    /// Oldest at the head — flush may only pop from it, because
    /// log_number advancement presumes every older WAL flushed first.
    immutable: std.ArrayListUnmanaged(*MemTable.Holder) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, seed: u64) !List {
        return .{
            .allocator = allocator,
            .io = io,
            .current = try MemTable.create(allocator, seed),
        };
    }

    pub fn deinit(self: *List) void {
        self.current.release();
        for (self.immutable.items) |h| h.release();
        self.immutable.deinit(self.allocator);
    }

    /// Snapshot every table a read must scan, current first. Each
    /// returned holder carries its own reference; the caller releases.
    pub fn acquireSet(self: *List, out: []*MemTable.Holder) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        self.current.acquire();
        out[n] = self.current;
        n += 1;
        for (self.immutable.items) |h| {
            h.acquire();
            out[n] = h;
            n += 1;
        }
        return n;
    }

    pub const EntryRef = struct {
        holder: *MemTable.Holder,
        entry: MemTable.Entry,
    };

    /// Caller also excludes writes to the current table (Db.write_mutex).
    /// Search while the list lock prevents flush from removing a holder;
    /// retain only the matching table. Its append-only arena keeps the entry
    /// bytes stable until the caller releases that reference.
    pub fn acquireEntry(self: *List, key: []const u8, snapshot: u64) ?EntryRef {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.current.data.getEntry(key, snapshot)) |entry| {
            self.current.acquire();
            return .{ .holder = self.current, .entry = entry };
        }
        var i = self.immutable.items.len;
        while (i > 0) {
            i -= 1;
            const holder = self.immutable.items[i];
            if (holder.data.getEntry(key, snapshot)) |entry| {
                holder.acquire();
                return .{ .holder = holder, .entry = entry };
            }
        }
        return null;
    }

    /// Freeze inside the write path: the old current joins the queue
    /// and a fresh one takes its place. The fresh table is created
    /// first, so a failed freeze leaves the list untouched.
    pub fn freeze(self: *List, new_seed: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const fresh = try MemTable.create(self.allocator, new_seed);
        errdefer fresh.release();
        try self.immutable.append(self.allocator, self.current);
        self.current = fresh;
    }

    /// Hand the oldest immutable to the flush thread — the queue's
    /// reference transfers to the caller, who releases it outside this
    /// lock. Null when only the current table remains.
    pub fn popHead(self: *List) ?*MemTable.Holder {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.immutable.items.len == 0) return null;
        return self.immutable.orderedRemove(0);
    }

    pub fn immutableCount(self: *List) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.immutable.items.len;
    }
};

// ========================= tests =========================

test "memtable_list: entry references retain only hits and preserve snapshot tombstones" {
    var list = try List.init(std.testing.allocator, std.testing.io, 1);
    defer list.deinit();
    const oldest = list.current;
    try oldest.data.put(1, "key", "old");
    try list.freeze(2);
    try list.current.data.delete(2, "key");
    try list.freeze(3);
    try list.current.data.put(3, "key", "new");
    try std.testing.expect(list.acquireEntry("absent", 3) == null);
    try std.testing.expectEqual(@as(u32, 1), list.current.refCount());
    const old = list.acquireEntry("key", 1).?;
    defer old.holder.release();
    try std.testing.expect(old.holder == oldest);
    try std.testing.expectEqual(@as(u32, 2), oldest.refCount());
    const deleted = list.acquireEntry("key", 2).?;
    defer deleted.holder.release();
    try std.testing.expect(deleted.entry.deleted);
    const newest = list.acquireEntry("key", 3).?;
    defer newest.holder.release();
    try std.testing.expectEqualStrings("new", newest.entry.value);
    const popped = list.popHead().?;
    try std.testing.expect(popped == oldest);
    popped.release();
    try std.testing.expectEqual(@as(u32, 1), old.holder.refCount());
    try std.testing.expectEqualStrings("old", old.entry.value);
}

test "memtable_list: acquireSet snapshots owned refs; freeze is FIFO; pop transfers the head" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var list = try List.init(allocator, io, 1);
    defer list.deinit();

    var buf: [5]*MemTable.Holder = undefined;
    const n0 = list.acquireSet(&buf);
    try std.testing.expectEqual(@as(usize, 1), n0);
    const initial = buf[0];
    try std.testing.expectEqual(@as(u32, 2), initial.refCount()); // list + snapshot
    initial.release();
    try std.testing.expectEqual(@as(u32, 1), initial.refCount());

    try list.freeze(2);
    try list.freeze(3);
    const n = list.acquireSet(&buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(buf[0] != buf[1]); // current (newest) first, queue after
    for (0..n) |i| buf[i].release();

    // FIFO: the first frozen table is the first popped.
    const first = list.popHead().?;
    try std.testing.expect(first == initial); // FIFO: the first frozen table is the first popped
    const second = list.popHead().?;
    try std.testing.expect(list.popHead() == null);
    try std.testing.expectEqual(@as(usize, 0), list.immutableCount());
    first.release();
    second.release();
}
