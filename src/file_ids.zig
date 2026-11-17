//! Shared WAL/SST/VLog id allocation. Every caller holds Db.write_mutex.
const std = @import("std");
const Db = @import("db.zig").Db;
const Pointer = @import("vlog/writer.zig").Pointer;

pub fn reserveLocked(db: *Db) u64 {
    const id = db.vs.next_file_number;
    db.vs.next_file_number += 1;
    return id;
}

fn reconcileVlogLocked(db: *Db) void {
    // Rotation can install a new writer before the following append fails.
    // Its id remains consumed even when no value pointer was published.
    db.vlog.next_id = db.vlog.writer.file_id + 1;
    db.vs.next_file_number = @max(db.vs.next_file_number, db.vlog.next_id);
}

/// The optional CRC must describe `value` without changes before append returns.
pub fn appendVlogLocked(db: *Db, seq: u64, expire_at: u64, key: []const u8, value: []const u8, value_crc: ?u32) !Pointer {
    db.vlog.writer.next_file_id = db.vs.next_file_number;
    defer reconcileVlogLocked(db);
    return db.vlog.append(db.io, seq, expire_at, key, value, value_crc);
}

pub fn sealVlogLocked(db: *Db) !void {
    db.vlog.writer.next_file_id = db.vs.next_file_number;
    defer reconcileVlogLocked(db);
    if (db.vlog.writer.size != 0) try db.vlog.writer.rotate(db.io);
}

test "file ids: rotation followed by failed append still consumes the active id" {
    const disk = @import("io/io.zig");
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var db = try Db.open(std.testing.allocator, std.testing.io, tmp.dir, .{
        .durability = .async,
        .value_threshold = 0,
        .vlog_file_size = @import("vlog/manager.zig").min_file_size,
    });
    defer db.deinit();

    // An oversized entry guarantees the next append must rotate first.
    const value = try std.testing.allocator.alloc(u8, @intCast(db.options.vlog_file_size));
    defer std.testing.allocator.free(value);
    @memset(value, 'v');
    try db.put("large", value);
    const next_id = db.vs.next_file_number;
    {
        disk.TestWrite.calls = 0;
        disk.TestWrite.fail_at = 0;
        defer disk.TestWrite.fail_at = std.math.maxInt(usize);
        try std.testing.expectError(error.InputOutput, db.put("failed", "value"));
    }
    try std.testing.expectEqual(next_id, db.vlog.writer.file_id);
    try std.testing.expectEqual(@as(u64, 0), db.vlog.writer.size);
    try std.testing.expectEqual(next_id + 1, db.vlog.next_id);
    const failed = try db.get("failed");
    defer if (failed) |bytes| std.testing.allocator.free(bytes);
    try std.testing.expect(failed == null);
    const other_id = blk: {
        db.write_mutex.lockUncancelable(db.io);
        defer db.write_mutex.unlock(db.io);
        break :blk reserveLocked(&db);
    };
    try std.testing.expectEqual(next_id + 1, other_id);

    // The empty active file remains usable, and its next rotation skips the
    // id already reserved by another file type.
    try db.put("retry", value);
    try std.testing.expectEqual(next_id, db.vlog.writer.file_id);
    try db.put("after", "value");
    try std.testing.expectEqual(other_id + 1, db.vlog.writer.file_id);
}
