//! Shared-object refcount: the last release runs the type's own destructor
//! callback. Contract: only acquire while you already hold a reference — a zero
//! count is final, it never resurrects.

const std = @import("std");

pub fn RefCounted(comptime T: type, comptime on_zero: *const fn (*T) void) type {
    return struct {
        data: T,
        /// 1 at creation: the creator owns the first reference.
        refs: std.atomic.Value(u32) = .init(1),

        const Self = @This();

        pub fn create(allocator: std.mem.Allocator, value: T) !*Self {
            const self = try allocator.create(Self);
            self.* = .{ .data = value };
            return self;
        }

        pub inline fn acquire(self: *Self) void {
            _ = self.refs.fetchAdd(1, .monotonic);
        }

        pub inline fn release(self: *Self) void {
            // Acquire makes earlier releasers' writes visible to on_zero.
            const prev = self.refs.fetchSub(1, .acq_rel);
            std.debug.assert(prev > 0);
            if (prev == 1) on_zero(&self.data);
        }

        pub inline fn refCount(self: *const Self) u32 {
            return self.refs.load(.monotonic);
        }
    };
}

test "last release runs the destructor exactly once" {
    const testing = std.testing;
    var hits: usize = 0;

    const Payload = struct { alloc: std.mem.Allocator, hits: *usize };

    const Pair = struct {
        fn destroy(p: *Payload) void {
            p.hits.* += 1;
            const holder: *Holder = @fieldParentPtr("data", p);
            p.alloc.destroy(holder);
        }
        const Holder = RefCounted(Payload, destroy);
    };

    const h = try Pair.Holder.create(
        testing.allocator,
        .{ .alloc = testing.allocator, .hits = &hits },
    );

    try testing.expectEqual(@as(u32, 1), h.refCount());
    h.acquire();
    h.acquire();
    try testing.expectEqual(@as(u32, 3), h.refCount());
    h.release();
    h.release();
    try testing.expectEqual(@as(u32, 1), h.refCount());
    try testing.expectEqual(@as(usize, 0), hits);
    h.release(); // hits zero -> destroy runs (allocator leak-checked by testing)
    try testing.expectEqual(@as(usize, 1), hits);
}
