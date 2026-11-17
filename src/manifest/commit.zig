//! Install one runtime version after its manifest publication has succeeded.
//! Flush and compaction keep their own WAL/SST retirement policy.
const std = @import("std");
const Db = @import("../db.zig").Db;
const VersionSet = @import("version_set.zig").VersionSet;
const ReadVersion = @import("read_version.zig").ReadVersion;
const diff = @import("diff.zig");

/// Caller holds write_mutex and owns next, independently of db.vs. On success,
/// next contains the old version and must still be deinitialized by the caller.
/// On error the installed version stays unchanged except for consumed file IDs.
/// A failed append may still have landed a complete edit, so callers must
/// stop writes and preserve both old and new files on every error.
pub fn publishAndInstallLocked(db: *Db, next: *VersionSet) !void {
    std.debug.assert(next != &db.vs);
    errdefer db.vs.next_file_number = @max(db.vs.next_file_number, next.next_file_number);
    const read_version = try ReadVersion.create(next);
    errdefer read_version.release();
    var edit = try diff.deltaEdit(db.internal_allocator, &db.vs, next);
    defer diff.freeEdit(db.internal_allocator, &edit);
    try db.manifest_writer.appendEdit(&edit);

    // All fallible work precedes publication in memory; retirement may only
    // use capacity reserved by the caller before entering this transaction.
    std.mem.swap(VersionSet, &db.vs, next);
    const old_read_version = db.read_version;
    db.read_version = read_version;
    old_read_version.release();
    db.log_number.store(db.vs.log_number, .release);
}

test "manifest commit: candidate allocation failure preserves installed state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(allocator, io, tmp.dir, .{ .durability = .async });
    defer db.deinit();
    db.write_mutex.lockUncancelable(io);
    defer db.write_mutex.unlock(io);
    var next = try db.vs.cloneState();
    defer next.deinit();
    const old_read_version = db.read_version;
    const old_manifest = db.manifest_name;
    const old_log = db.log_number.load(.acquire);
    const before = db.stat().allocated_bytes;
    next.log_number = db.wal_id;
    next.next_file_number += 10;
    var failing = std.testing.FailingAllocator.init(db.internal_allocator, .{ .fail_index = 0 });
    {
        const saved_allocator = next.allocator;
        next.allocator = failing.allocator();
        defer next.allocator = saved_allocator;
        try std.testing.expectError(error.OutOfMemory, publishAndInstallLocked(&db, &next));
    }
    try std.testing.expect(db.read_version == old_read_version);
    try std.testing.expectEqual(@as(u32, 1), old_read_version.refCount());
    try std.testing.expect(db.manifest_name.ptr == old_manifest.ptr);
    try std.testing.expectEqual(old_log, db.vs.log_number);
    try std.testing.expectEqual(old_log, db.log_number.load(.acquire));
    try std.testing.expectEqual(next.next_file_number, db.vs.next_file_number);
    try std.testing.expectEqual(before, db.stat().allocated_bytes);
}

test "manifest commit: failed publication retains the installed version and consumes its file id" {
    const disk = @import("../io/io.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(allocator, io, tmp.dir, .{ .durability = .async });
    defer db.deinit();
    db.write_mutex.lockUncancelable(io);
    defer db.write_mutex.unlock(io);
    var next = try db.vs.cloneState();
    defer next.deinit();
    const old_read_version = db.read_version;
    const old_manifest = db.manifest_name;
    const old_log = db.log_number.load(.acquire);
    next.log_number = db.wal_id;
    const before = db.stat().allocated_bytes;
    {
        disk.TestWrite.target = db.manifest_writer.file.handle;
        disk.TestWrite.calls = 0;
        disk.TestWrite.fail_at = 0;
        defer {
            disk.TestWrite.target = null;
            disk.TestWrite.fail_at = std.math.maxInt(usize);
        }
        try std.testing.expectError(error.InputOutput, publishAndInstallLocked(&db, &next));
        try std.testing.expectEqual(@as(usize, 1), disk.TestWrite.calls);
    }
    try std.testing.expect(db.read_version == old_read_version);
    try std.testing.expectEqual(@as(u32, 1), old_read_version.refCount());
    try std.testing.expect(db.manifest_name.ptr == old_manifest.ptr);
    try std.testing.expectEqual(old_log, db.vs.log_number);
    try std.testing.expectEqual(old_log, db.log_number.load(.acquire));
    try std.testing.expectEqual(next.next_file_number, db.vs.next_file_number);
    try std.testing.expectEqual(before, db.stat().allocated_bytes);
    const current = try @import("reader.zig").readCurrent(allocator, db.dir, io);
    defer allocator.free(current);
    try std.testing.expectEqualStrings(old_manifest, current);
}
