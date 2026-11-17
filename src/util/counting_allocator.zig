const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Atomic = std.atomic.Value(usize);

/// Must remain at a stable address while any wrapped allocation is live.
pub const CountingAllocator = struct {
    parent: Allocator,
    bytes: Atomic = .init(0),
    peak: Atomic = .init(0),
    allocations: Atomic = .init(0),
    failures: Atomic = .init(0),
    pub const Stats = struct { allocated_bytes: usize, peak_allocated_bytes: usize, allocation_count: usize, allocation_failures: usize };
    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    /// Fields are individually atomic; a concurrent snapshot is approximate.
    pub fn stats(self: *const CountingAllocator) Stats {
        return .{ .allocated_bytes = self.bytes.load(.monotonic), .peak_allocated_bytes = self.peak.load(.monotonic), .allocation_count = self.allocations.load(.monotonic), .allocation_failures = self.failures.load(.monotonic) };
    }
    fn account(self: *CountingAllocator, old: usize, new: usize) void {
        if (new <= old) {
            _ = self.bytes.fetchSub(old - new, .monotonic);
            return;
        }
        const current = self.bytes.fetchAdd(new - old, .monotonic) + new - old;
        var peak = self.peak.load(.monotonic);
        while (current > peak) peak = self.peak.cmpxchgWeak(peak, current, .monotonic, .monotonic) orelse break;
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent.rawAlloc(len, alignment, ra) orelse {
            _ = self.failures.fetchAdd(1, .monotonic);
            return null;
        };
        _ = self.allocations.fetchAdd(1, .monotonic);
        self.account(0, len);
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, len, ra)) return false;
        self.account(memory.len, len);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent.rawRemap(memory, alignment, len, ra) orelse return null;
        self.account(memory.len, len);
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ra);
        self.account(memory.len, 0);
    }
};

test "counting allocator balances realloc and release" {
    var counter: CountingAllocator = .{ .parent = std.testing.allocator };
    const a = counter.allocator();
    var bytes = try a.alloc(u8, 64);
    bytes = try a.realloc(bytes, 256);
    try std.testing.expectEqual(@as(usize, 256), counter.stats().allocated_bytes);
    try std.testing.expect(counter.stats().peak_allocated_bytes >= 256);
    a.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), counter.stats().allocated_bytes);
}
test "counting allocator records allocation failure" {
    var storage: [8]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var counter: CountingAllocator = .{ .parent = fixed.allocator() };
    try std.testing.expectError(error.OutOfMemory, counter.allocator().alloc(u8, 16));
    try std.testing.expectEqual(@as(usize, 1), counter.stats().allocation_failures);
    try std.testing.expectEqual(@as(usize, 0), counter.stats().allocated_bytes);
}
