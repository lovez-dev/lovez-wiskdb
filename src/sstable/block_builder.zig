//! Data block builder: LevelDB-style prefix compression (`shared`,
//! `unshared`, `value_len` varints + delta) with a restart point every
//! `restart_interval` entries. Entries are never split; the caller flushes
//! when the size target is reached.

const std = @import("std");
const coding = @import("../util/coding.zig");
const varint = @import("../util/varint.zig");
const restart_interval = @import("format.zig").restart_interval;

pub const BlockBuilder = struct {
    allocator: std.mem.Allocator,
    data: std.ArrayListUnmanaged(u8) = .empty,
    last_key: std.ArrayListUnmanaged(u8) = .empty,
    restarts: std.ArrayListUnmanaged(u32) = .empty,
    entry_count: usize = 0,
    since_restart: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !BlockBuilder {
        var b: BlockBuilder = .{ .allocator = allocator };
        try b.restarts.ensureTotalCapacity(allocator, 64);
        b.restarts.appendAssumeCapacity(0); // entry 0 always restarts at 0
        return b;
    }

    pub fn add(self: *BlockBuilder, key: []const u8, value: []const u8) error{OutOfMemory}!void {
        var shared: u32 = 0;
        if (self.entry_count == 0) {
            // first key: nothing to share with
        } else if (self.since_restart >= restart_interval) {
            try self.restarts.append(self.allocator, @intCast(self.data.items.len));
            self.since_restart = 0;
        } else {
            shared = @intCast(commonPrefix(self.last_key.items, key));
        }

        const unshared: u32 = @intCast(key.len - shared);
        const value_len: u32 = @intCast(value.len);
        var scratch: [15]u8 = undefined;
        const n1 = varint.putU32(scratch[0..], shared) catch unreachable; // 15 B scratch, u32 ≤ 5 B
        const n2 = varint.putU32(scratch[n1..], unshared) catch unreachable;
        const n3 = varint.putU32(scratch[n1 + n2 ..], value_len) catch unreachable;

        try self.data.appendSlice(self.allocator, scratch[0 .. n1 + n2 + n3]);
        try self.data.appendSlice(self.allocator, key[shared..]);
        try self.data.appendSlice(self.allocator, value);
        self.last_key.clearRetainingCapacity();
        try self.last_key.appendSlice(self.allocator, key);
        self.entry_count += 1;
        self.since_restart += 1;
    }

    /// data bytes + `u32 restarts...` + `u32 count` tail (excludes trailer).
    pub fn estimatedSize(self: *const BlockBuilder) usize {
        return self.data.items.len + self.restarts.items.len * 4 + 4;
    }

    /// Serialize the restart tail into `data`; the block bytes are then
    /// `data.items`. Reuse across blocks via `reset`.
    pub fn finish(self: *BlockBuilder) error{OutOfMemory}!void {
        for (self.restarts.items) |r| {
            var b: [4]u8 = undefined;
            coding.putU32(&b, r);
            try self.data.appendSlice(self.allocator, &b);
        }
        var count: [4]u8 = undefined;
        coding.putU32(&count, @intCast(self.restarts.items.len));
        try self.data.appendSlice(self.allocator, &count);
    }

    pub fn reset(self: *BlockBuilder) void {
        self.data.clearRetainingCapacity();
        self.last_key.clearRetainingCapacity();
        self.restarts.clearRetainingCapacity();
        self.restarts.appendAssumeCapacity(0);
        self.entry_count = 0;
        self.since_restart = 0;
    }

    pub fn deinit(self: *BlockBuilder) void {
        self.data.deinit(self.allocator);
        self.last_key.deinit(self.allocator);
        self.restarts.deinit(self.allocator);
    }
};

fn commonPrefix(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) : (i += 1) {}
    return i;
}

test "block builder: prefix compression, restart cadence, manual walk" {
    const alloc = std.testing.allocator;
    var b = try BlockBuilder.init(alloc);
    defer b.deinit();

    var kbuf: [16]u8 = undefined;
    for (0..17) |i| {
        const key = try std.fmt.bufPrint(&kbuf, "key{d:0>4}", .{i});
        try b.add(key, "value");
    }
    try b.finish();

    // restart tail: [u32 restarts...] || u32 count
    const bytes = b.data.items;
    const count: usize = coding.getU32(bytes[bytes.len - 4 ..][0..4]);
    try std.testing.expectEqual(@as(usize, 2), count); // entry 0 + entry 16
    const restarts = bytes[bytes.len - 4 - count * 4 .. bytes.len - 4];

    // walk all 17 entries; reconstruct keys without the reader
    var pos: usize = 0;
    var prev: [64]u8 = undefined;
    var cur: [64]u8 = undefined;
    for (0..17) |i| {
        const sh = varint.getU32(bytes[pos..]) catch return error.TestUnexpectedResult;
        const un = varint.getU32(bytes[pos + sh.len ..]) catch return error.TestUnexpectedResult;
        const vl = varint.getU32(bytes[pos + sh.len + un.len ..]) catch return error.TestUnexpectedResult;
        const head = sh.len + un.len + vl.len;
        const shared: usize = @intCast(sh.value);
        const unshared: usize = @intCast(un.value);
        if (i == 0 or i == 16) try std.testing.expectEqual(@as(usize, 0), shared) else if (i > 0) try std.testing.expect(shared > 0);
        if (i == 16) try std.testing.expectEqual(
            @as(usize, coding.getU32(restarts[4..8][0..4])),
            pos, // restart points exactly at entry 16
        );
        @memcpy(cur[0..shared], prev[0..shared]);
        @memcpy(cur[shared .. shared + unshared], bytes[pos + head .. pos + head + unshared]);
        const value = bytes[pos + head + unshared .. pos + head + unshared + vl.value];
        try std.testing.expectEqualStrings("value", value);

        var expect: [16]u8 = undefined;
        const exp = try std.fmt.bufPrint(&expect, "key{d:0>4}", .{i});
        try std.testing.expectEqualStrings(exp, cur[0 .. shared + unshared]);
        @memcpy(prev[0 .. shared + unshared], cur[0 .. shared + unshared]);
        pos += head + unshared + vl.value;
    }
    try std.testing.expectEqual(bytes.len - 4 - count * 4, pos); // consumed data, not tail

    b.reset();
    try std.testing.expectEqual(@as(usize, 0), b.entry_count);
}
