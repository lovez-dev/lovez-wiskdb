const std = @import("std");
const mf = @import("format.zig");
const VersionSet = @import("version_set.zig").VersionSet;

test "version set: failed edit leaves the original state unchanged" {
    const alloc = std.testing.allocator;
    var vs = VersionSet.init(alloc);
    defer vs.deinit();
    const add = [_]mf.FileMeta{.{ .level = 0, .file_id = 4, .file_size = 1, .smallest = "a", .largest = "z", .min_seq = 1, .max_seq = 1, .vlog_ids = "" }};
    var valid = mf.Edit{ .adds = &add, .last_sequence = 12 };
    try vs.apply(&valid);
    var invalid = mf.Edit{ .deletes = &.{.{ .level = 2, .file_id = 99 }}, .last_sequence = 20 };
    try std.testing.expectError(error.ManifestCorrupted, vs.apply(&invalid));
    try std.testing.expectEqual(@as(u64, 12), vs.last_sequence);
    try std.testing.expect(vs.findFile(0, 4) != null);
}

test "version set: apply sorts L0 by file id" {
    const alloc = std.testing.allocator;
    var vs = VersionSet.init(alloc);
    defer vs.deinit();
    const adds = [_]mf.FileMeta{
        .{ .level = 0, .file_id = 9, .file_size = 1, .smallest = "a", .largest = "z", .min_seq = 1, .max_seq = 1, .vlog_ids = "" },
        .{ .level = 0, .file_id = 3, .file_size = 1, .smallest = "a", .largest = "z", .min_seq = 1, .max_seq = 1, .vlog_ids = "" },
    };
    var edit = mf.Edit{ .adds = &adds };
    try vs.apply(&edit);
    const files = vs.by_level.get(0).?.items;
    try std.testing.expectEqual(@as(u64, 3), files[0].file_id);
    try std.testing.expectEqual(@as(u64, 9), files[1].file_id);
}

fn cloneWithAllocator(allocator: std.mem.Allocator, source: *const VersionSet) !void {
    var borrowed = source.*;
    borrowed.allocator = allocator;
    var copy = try borrowed.cloneState();
    defer copy.deinit();
    try std.testing.expectEqual(@as(usize, 1), copy.fileCount(0));
    try std.testing.expectEqual(@as(usize, 1), copy.fileCount(2));
}

test "version set: staged flush clone releases every partial allocation on OOM" {
    var vs = VersionSet.init(std.testing.allocator);
    defer vs.deinit();
    const adds = [_]mf.FileMeta{
        .{ .level = 0, .file_id = 3, .file_size = 1, .smallest = "a", .largest = "z", .min_seq = 1, .max_seq = 1, .vlog_ids = "ids" },
        .{ .level = 2, .file_id = 4, .file_size = 1, .smallest = "a", .largest = "z", .min_seq = 1, .max_seq = 1, .vlog_ids = "ids" },
    };
    try vs.apply(&.{ .adds = &adds, .vlog_deletes = &.{9} });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneWithAllocator, .{&vs});
    try std.testing.expectEqual(@as(usize, 1), vs.fileCount(0));
    try std.testing.expectEqual(@as(usize, 1), vs.fileCount(2));
}
