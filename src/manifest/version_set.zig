//! In-memory version state rebuilt by replaying MANIFEST edits: files by
//! level plus the counters recovery must publish. `apply` clones what it
//! stores, so the caller keeps ownership of the edit it passes in.

const std = @import("std");
const mf = @import("format.zig");

fn bySmallest(_: void, a: mf.FileMeta, b: mf.FileMeta) bool {
    return std.mem.order(u8, a.smallest, b.smallest) == .lt;
}

fn byFileId(_: void, a: mf.FileMeta, b: mf.FileMeta) bool {
    return a.file_id < b.file_id;
}

pub const VersionSet = struct {
    allocator: std.mem.Allocator,
    by_level: std.AutoArrayHashMapUnmanaged(u32, std.ArrayListUnmanaged(mf.FileMeta)) = .empty,
    log_number: u64 = 0,
    next_file_number: u64 = 1,
    last_sequence: u64 = 0,
    db_id: ?[16]u8 = null,
    format_version: ?u16 = null,
    /// Vlog ids removed by GC events; live vlogs are the ids referenced by
    /// stored files minus this set.
    dead_vlogs: std.ArrayListUnmanaged(u64) = .empty,

    pub fn init(allocator: std.mem.Allocator) VersionSet {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VersionSet) void {
        var it = self.by_level.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |f| f.deinit(self.allocator);
            entry.value_ptr.deinit(self.allocator);
        }
        self.by_level.deinit(self.allocator);
        self.dead_vlogs.deinit(self.allocator);
        self.* = undefined;
    }

    /// Apply one decoded edit. Counter fields are last-wins (only present
    /// fields change); deletes run before adds, matching how a compaction
    /// commit lists removed inputs then added outputs.
    pub fn apply(self: *VersionSet, edit: *const mf.Edit) error{ ManifestCorrupted, OutOfMemory }!void {
        var next = try self.cloneState();
        errdefer next.deinit();
        try next.applyMutable(edit);
        try next.validateAndSort();
        var old = self.*;
        self.* = next;
        next = undefined;
        old.deinit();
    }

    fn applyMutable(self: *VersionSet, edit: *const mf.Edit) error{ ManifestCorrupted, OutOfMemory }!void {
        if (edit.log_number) |v| self.log_number = v;
        if (edit.next_file_number) |v| self.next_file_number = v;
        if (edit.last_sequence) |v| self.last_sequence = v;
        if (edit.db_id) |v| self.db_id = v;
        if (edit.format_version) |v| self.format_version = v;

        for (edit.deletes) |d| {
            const list = self.by_level.getPtr(d.level) orelse return error.ManifestCorrupted;
            var found = false;
            for (list.items, 0..) |f, i| {
                if (f.file_id == d.file_id) {
                    f.deinit(self.allocator);
                    _ = list.orderedRemove(i);
                    found = true;
                    break;
                }
            }
            if (!found) return error.ManifestCorrupted;
        }

        for (edit.adds) |a| {
            const list = try self.by_level.getOrPut(self.allocator, a.level);
            if (!list.found_existing) list.value_ptr.* = .empty;
            const clone = try self.cloneFile(a);
            errdefer clone.deinit(self.allocator);
            try list.value_ptr.append(self.allocator, clone);
        }

        for (edit.vlog_deletes) |vid| {
            for (self.dead_vlogs.items) |known| {
                if (known == vid) break; // idempotent: an id may die once
            } else {
                try self.dead_vlogs.append(self.allocator, vid);
            }
        }
    }

    pub fn cloneState(self: *const VersionSet) error{OutOfMemory}!VersionSet {
        var copy = VersionSet.init(self.allocator);
        errdefer copy.deinit();
        copy.log_number = self.log_number;
        copy.next_file_number = self.next_file_number;
        copy.last_sequence = self.last_sequence;
        copy.db_id = self.db_id;
        copy.format_version = self.format_version;
        try copy.dead_vlogs.appendSlice(self.allocator, self.dead_vlogs.items);
        var levels = self.by_level.iterator();
        while (levels.next()) |entry| {
            for (entry.value_ptr.items) |file| {
                const slot = try copy.by_level.getOrPut(self.allocator, entry.key_ptr.*);
                if (!slot.found_existing) slot.value_ptr.* = .empty;
                const cloned = try copy.cloneFile(file);
                slot.value_ptr.append(self.allocator, cloned) catch |err| {
                    cloned.deinit(self.allocator);
                    return err;
                };
            }
        }
        return copy;
    }

    fn validateAndSort(self: *VersionSet) error{ManifestCorrupted}!void {
        var levels = self.by_level.iterator();
        while (levels.next()) |entry| {
            if (entry.key_ptr.* == 0) {
                std.sort.heap(mf.FileMeta, entry.value_ptr.items, {}, byFileId);
                continue;
            }
            std.sort.heap(mf.FileMeta, entry.value_ptr.items, {}, bySmallest);
            if (entry.value_ptr.items.len < 2) continue;
            for (1..entry.value_ptr.items.len) |i| {
                const prev = entry.value_ptr.items[i - 1];
                const current = entry.value_ptr.items[i];
                if (std.mem.order(u8, prev.largest, current.smallest) != .lt) return error.ManifestCorrupted;
            }
        }
    }
    fn cloneFile(self: *VersionSet, a: mf.FileMeta) error{OutOfMemory}!mf.FileMeta {
        const smallest = try self.allocator.dupe(u8, a.smallest);
        errdefer self.allocator.free(smallest);
        const largest = try self.allocator.dupe(u8, a.largest);
        errdefer self.allocator.free(largest);
        const vlog_ids = try self.allocator.dupe(u8, a.vlog_ids);
        return .{
            .level = a.level,
            .file_id = a.file_id,
            .file_size = a.file_size,
            .smallest = smallest,
            .largest = largest,
            .min_seq = a.min_seq,
            .max_seq = a.max_seq,
            .vlog_ids = vlog_ids,
        };
    }

    pub fn fileCount(self: *const VersionSet, level: u32) usize {
        const list = self.by_level.get(level) orelse return 0;
        return list.items.len;
    }

    pub fn findFile(self: *const VersionSet, level: u32, file_id: u64) ?mf.FileMeta {
        const list = self.by_level.get(level) orelse return null;
        for (list.items) |f| {
            if (f.file_id == file_id) return f;
        }
        return null;
    }

    pub fn findRange(self: *const VersionSet, level: u32, key: []const u8) ?mf.FileMeta {
        const files = self.by_level.get(level) orelse return null;
        var lo: usize = 0;
        var hi = files.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, files.items[mid].largest, key) == .lt) lo = mid + 1 else hi = mid;
        }
        if (lo == files.items.len) return null;
        const file = files.items[lo];
        if (std.mem.order(u8, key, file.smallest) == .lt) return null;
        return file;
    }
};

test "version set: apply clones strings so the edit can die first" {
    const alloc = std.testing.allocator;
    var vs = VersionSet.init(alloc);
    defer vs.deinit();

    const lit = mf.Edit{
        .log_number = 3,
        .next_file_number = 9,
        .last_sequence = 40,
        .format_version = mf.current_version,
        .adds = &.{
            .{
                .level = 0,
                .file_id = 8,
                .file_size = 100,
                .smallest = "aaa",
                .largest = "mmm",
                .min_seq = 1,
                .max_seq = 20,
                .vlog_ids = &.{ 1, 2 },
            },
            .{
                .level = 1,
                .file_id = 9,
                .file_size = 200,
                .smallest = "nnn",
                .largest = "zzz",
                .min_seq = 21,
                .max_seq = 30,
                .vlog_ids = &.{},
            },
        },
    };
    const bytes = try mf.encode(alloc, &lit);
    defer alloc.free(bytes);
    var edit = try mf.decode(alloc, bytes);
    try vs.apply(&edit);
    edit.deinit(alloc); // nothing in the set points into the edit

    try std.testing.expectEqual(@as(u64, 3), vs.log_number);
    try std.testing.expectEqual(@as(u64, 9), vs.next_file_number);
    try std.testing.expectEqual(@as(u64, 40), vs.last_sequence);
    try std.testing.expectEqual(@as(usize, 1), vs.fileCount(0));
    try std.testing.expectEqual(@as(usize, 1), vs.fileCount(1));
    const f = vs.findFile(0, 8).?;
    try std.testing.expectEqualStrings("aaa", f.smallest);
    try std.testing.expectEqual(@as(u64, 20), f.max_seq);

    var del = mf.Edit{
        .deletes = &.{.{ .level = 0, .file_id = 8 }},
        .vlog_deletes = &.{7},
    };
    try vs.apply(&del);
    try std.testing.expectEqual(@as(usize, 0), vs.fileCount(0));
    try std.testing.expect(vs.findFile(0, 8) == null);
    try std.testing.expectEqual(@as(usize, 1), vs.dead_vlogs.items.len);
    try std.testing.expectEqual(@as(u64, 7), vs.dead_vlogs.items[0]);

    // an id may die once; a second delete event for it stays idempotent
    var del2 = mf.Edit{ .vlog_deletes = &.{7} };
    try vs.apply(&del2);
    try std.testing.expectEqual(@as(usize, 1), vs.dead_vlogs.items.len);
}

test "version set: sorted level range lookup" {
    const alloc = std.testing.allocator;
    var vs = VersionSet.init(alloc);
    defer vs.deinit();
    const adds = [_]mf.FileMeta{
        .{ .level = 2, .file_id = 8, .file_size = 1, .smallest = "m", .largest = "z", .min_seq = 1, .max_seq = 1, .vlog_ids = "" },
        .{ .level = 2, .file_id = 7, .file_size = 1, .smallest = "a", .largest = "k", .min_seq = 1, .max_seq = 1, .vlog_ids = "" },
    };
    var edit = mf.Edit{ .adds = &adds };
    try vs.apply(&edit);
    try std.testing.expectEqualStrings("a", vs.by_level.get(2).?.items[0].smallest);
    try std.testing.expectEqualStrings("k", vs.by_level.get(2).?.items[0].largest);
    try std.testing.expectEqualStrings("m", vs.by_level.get(2).?.items[1].smallest);
    try std.testing.expectEqual(@as(u64, 7), vs.findRange(2, "b").?.file_id);
    try std.testing.expectEqual(@as(u64, 8), vs.findRange(2, "x").?.file_id);
    try std.testing.expect(vs.findRange(2, "l") == null);
}

test "version set: overlapping deep ranges are rejected atomically" {
    const alloc = std.testing.allocator;
    var vs = VersionSet.init(alloc);
    defer vs.deinit();
    const adds = [_]mf.FileMeta{
        .{ .level = 1, .file_id = 1, .file_size = 1, .smallest = "a", .largest = "m", .min_seq = 1, .max_seq = 1, .vlog_ids = "" },
        .{ .level = 1, .file_id = 2, .file_size = 1, .smallest = "k", .largest = "z", .min_seq = 1, .max_seq = 1, .vlog_ids = "" },
    };
    var edit = mf.Edit{ .adds = &adds, .last_sequence = 5 };
    try std.testing.expectError(error.ManifestCorrupted, vs.apply(&edit));
    try std.testing.expectEqual(@as(usize, 0), vs.fileCount(1));
    try std.testing.expectEqual(@as(u64, 0), vs.last_sequence);
}

test "version set: deleting a file the manifest never added is corruption" {
    const alloc = std.testing.allocator;
    var vs = VersionSet.init(alloc);
    defer vs.deinit();

    var edit = mf.Edit{ .deletes = &.{.{ .level = 2, .file_id = 404 }} };
    try std.testing.expectError(error.ManifestCorrupted, vs.apply(&edit));

    // a level that has no list at all fails the same way
    var edit2 = mf.Edit{ .deletes = &.{.{ .level = 5, .file_id = 1 }} };
    try std.testing.expectError(error.ManifestCorrupted, vs.apply(&edit2));
}
