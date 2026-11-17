//! Owned immutable metadata for point-read file selection. Publish under the
//! database write mutex; readers retain it there and search after unlocking.
const std = @import("std");
const VersionSet = @import("version_set.zig").VersionSet;
const refcount = @import("../util/refcount.zig");

pub const ReadVersion = struct {
    vs: VersionSet,
    pub const Holder = refcount.RefCounted(ReadVersion, destroy);

    fn destroy(self: *ReadVersion) void {
        const holder: *Holder = @fieldParentPtr("data", self);
        const allocator = self.vs.allocator;
        self.vs.deinit();
        allocator.destroy(holder);
    }

    pub fn create(vs: *const VersionSet) !*Holder {
        var copy = try vs.cloneState();
        errdefer copy.deinit();
        return Holder.create(vs.allocator, .{ .vs = copy });
    }
};

fn cloneWithFailures(allocator: std.mem.Allocator, original: *const VersionSet) !void {
    var source = original.*;
    source.allocator = allocator;
    const holder = try ReadVersion.create(&source);
    defer holder.release();
    holder.acquire();
    holder.release();
    try std.testing.expectEqual(@as(u64, 9), holder.data.vs.findRange(2, "key").?.file_id);
}

test "read version: owned metadata survives source destruction and failed clone allocations" {
    const alloc = std.testing.allocator;
    var source = VersionSet.init(alloc);
    defer source.deinit();
    const adds = [_]@import("format.zig").FileMeta{.{ .level = 2, .file_id = 9, .file_size = 100, .smallest = "key", .largest = "key", .min_seq = 1, .max_seq = 1, .vlog_ids = "" }};
    try source.apply(&.{ .adds = &adds });
    try std.testing.checkAllAllocationFailures(alloc, cloneWithFailures, .{&source});
    const holder = try ReadVersion.create(&source);
    defer holder.release();
    try source.apply(&.{ .deletes = &.{.{ .level = 2, .file_id = 9 }} });
    try std.testing.expectEqualStrings("key", holder.data.vs.findRange(2, "key").?.smallest);
}
