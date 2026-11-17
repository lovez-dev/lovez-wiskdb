//! Block read path: restart-array parsing, entry decode with prefix
//! reconstruction, and bidirectional iteration. Unshared keys borrow the
//! immutable block; prefix-compressed keys use two alternating buffers.

const std = @import("std");
const coding = @import("../util/coding.zig");
const varint = @import("../util/varint.zig");
const internal_key = @import("../util/internal_key.zig");
const restart_interval = @import("format.zig").restart_interval;

pub const BlockReader = struct {
    /// Block bytes minus the restart tail.
    entries: []const u8,
    /// `[u32 LE restart_offset × n] || u32 LE n` (validated by `init`).
    tail: []const u8,
    restart_count: usize,

    pub fn init(block_data: []const u8) error{BlockCorrupted}!BlockReader {
        if (block_data.len < 8) return error.BlockCorrupted; // 1 restart + count
        const restart_count: usize = coding.getU32(block_data[block_data.len - 4 ..][0..4]);
        if (restart_count == 0) return error.BlockCorrupted;
        const tail_len = restart_count * 4 + 4;
        if (tail_len > block_data.len) return error.BlockCorrupted;
        const entries = block_data[0 .. block_data.len - tail_len];
        const tail = block_data[block_data.len - tail_len ..];
        if (restartAt(tail, 0) != 0) return error.BlockCorrupted;
        for (0..restart_count) |i| {
            const off = restartAt(tail, i);
            if (off > entries.len or (entries.len != 0 and off == entries.len)) return error.BlockCorrupted;
            if (i != 0 and off <= restartAt(tail, i - 1)) return error.BlockCorrupted;
        }
        return .{ .entries = entries, .tail = tail, .restart_count = restart_count };
    }

    /// `init` bounds-checked every restart; `i < restart_count` keeps `4*i`
    /// clear of the count word.
    pub fn restartAt(tail: []const u8, i: usize) usize {
        const off = i * 4;
        return @intCast(coding.getU32(tail[off .. off + 4][0..4]));
    }
};

const KeyBuffer = struct {
    inline_bytes: [256]u8 = undefined,
    overflow: std.ArrayListUnmanaged(u8) = .empty,
    len: usize = 0,

    fn items(self: *const KeyBuffer) []const u8 {
        return if (self.len <= self.inline_bytes.len) self.inline_bytes[0..self.len] else self.overflow.allocatedSlice()[0..self.len];
    }

    fn resize(self: *KeyBuffer, allocator: std.mem.Allocator, len: usize) error{OutOfMemory}![]u8 {
        if (len > self.inline_bytes.len) try self.overflow.ensureTotalCapacity(allocator, len);
        self.len = len;
        return if (len <= self.inline_bytes.len) self.inline_bytes[0..len] else self.overflow.allocatedSlice()[0..len];
    }

    fn clearRetainingCapacity(self: *KeyBuffer) void {
        self.len = 0;
    }

    fn deinit(self: *KeyBuffer, allocator: std.mem.Allocator) void {
        self.overflow.deinit(allocator);
    }
};

/// Keep the iterator at a stable address after positioning: key may borrow
/// inline storage. The block must outlive the iterator's current position.
/// key/value are valid until repositioning or deinit; init returns no slices.
pub const BlockIter = struct {
    allocator: std.mem.Allocator,
    block: BlockReader = undefined,
    pos: usize = 0,
    current: ?usize = null,
    at_end: bool = true,
    key: []const u8 = &.{},
    value: []const u8 = &.{},
    /// When key needs reconstruction, keys[front] holds it; otherwise key
    /// points into the block. The other buffer never aliases the predecessor.
    keys: [2]KeyBuffer = .{ .{}, .{} },
    front: usize = 0,
    /// Ordinal of the entry `key`/`value` currently point at (restart i
    /// starts at entry `restart_interval × i`, so a seek lands on its
    /// exact entry number without counting).
    ordinal: usize = 0,

    pub fn init(allocator: std.mem.Allocator) BlockIter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BlockIter) void {
        self.keys[0].deinit(self.allocator);
        self.keys[1].deinit(self.allocator);
    }

    pub fn resetTo(self: *BlockIter, block: BlockReader) void {
        self.block = block;
        self.pos = 0;
        self.current = null;
        self.at_end = true;
        self.key = &.{};
        self.value = &.{};
        self.keys[0].clearRetainingCapacity();
        self.keys[1].clearRetainingCapacity();
        self.front = 0;
    }

    /// Borrow a complete key, or rebuild its prefix/delta in the back buffer.
    fn decodeInto(
        self: *BlockIter,
        at: usize,
        previous: []const u8,
    ) error{ BlockCorrupted, OutOfMemory }!struct { next: usize, value: []const u8 } {
        const entries = self.block.entries;
        if (at >= entries.len) return error.BlockCorrupted;
        const sh = varint.getU32(entries[at..]) catch return error.BlockCorrupted;
        const un = varint.getU32(entries[at + sh.len ..]) catch return error.BlockCorrupted;
        const vl = varint.getU32(entries[at + sh.len + un.len ..]) catch return error.BlockCorrupted;
        const head = sh.len + un.len + vl.len;
        const shared: usize = @intCast(sh.value);
        const unshared: usize = @intCast(un.value);
        const value_len: usize = @intCast(vl.value);
        if (shared > previous.len) return error.BlockCorrupted;
        const total = std.math.add(usize, at, head) catch return error.BlockCorrupted;
        const delta_start = total; // delta follows the header; shared only sizes the prev copy
        const delta_end = std.math.add(usize, delta_start, unshared) catch return error.BlockCorrupted;
        const value_end = std.math.add(usize, delta_end, value_len) catch return error.BlockCorrupted;
        if (value_end > entries.len) return error.BlockCorrupted;

        const delta = entries[delta_start..delta_end];
        const value = entries[delta_end..value_end];
        if (shared == 0) {
            self.key = delta;
            return .{ .next = value_end, .value = value };
        }

        const back: usize = self.front ^ 1;
        const buf = &self.keys[back];
        const key_len = std.math.add(usize, shared, unshared) catch return error.BlockCorrupted;
        const bytes = try buf.resize(self.allocator, key_len);
        @memcpy(bytes[0..shared], previous[0..shared]);
        @memcpy(bytes[shared..], delta);
        self.front = back;
        self.key = self.keys[back].items();
        return .{ .next = value_end, .value = value };
    }

    /// Move to the entry at `pos`; false at end of block.
    pub fn advance(self: *BlockIter) error{ BlockCorrupted, OutOfMemory }!bool {
        if (self.at_end) return false;
        if (self.current != null) self.ordinal += 1;
        const previous = self.key;
        const at = self.pos;
        const r = try self.decodeInto(at, previous);
        self.current = at;
        self.pos = r.next;
        self.value = r.value;
        self.at_end = self.pos >= self.block.entries.len;
        return true;
    }

    /// Rewind to the first entry.
    pub fn first(self: *BlockIter) error{ BlockCorrupted, OutOfMemory }!bool {
        self.pos = 0;
        self.current = null;
        self.key = &.{};
        self.value = &.{};
        self.ordinal = 0;
        self.at_end = self.block.entries.len == 0;
        if (self.at_end) return false;
        self.keys[self.front].clearRetainingCapacity();
        return self.advance();
    }

    /// Rebuild only the final restart bucket, retaining no entry index.
    pub fn last(self: *BlockIter) error{ BlockCorrupted, OutOfMemory }!bool {
        if (self.block.entries.len == 0) return self.first();
        const bucket = self.block.restart_count - 1;
        self.pos = BlockReader.restartAt(self.block.tail, bucket);
        self.current = null;
        self.ordinal = bucket * restart_interval;
        self.key = &.{};
        self.keys[self.front].clearRetainingCapacity();
        self.at_end = false;
        while (try self.advance()) {}
        return true;
    }

    /// Prefix compression requires reconstructing from the nearest preceding
    /// restart. Work is bounded by one restart bucket; the block stays valid.
    pub fn prev(self: *BlockIter) error{ BlockCorrupted, OutOfMemory }!bool {
        const target = self.current orelse return false;
        if (target == 0) {
            self.current = null;
            self.at_end = true;
            self.key = &.{};
            self.value = &.{};
            return false;
        }
        var lo: usize = 0;
        var hi = self.block.restart_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (BlockReader.restartAt(self.block.tail, mid) < target) lo = mid + 1 else hi = mid;
        }
        const bucket = lo - 1;
        self.pos = BlockReader.restartAt(self.block.tail, bucket);
        self.current = null;
        self.ordinal = bucket * restart_interval;
        self.key = &.{};
        self.keys[self.front].clearRetainingCapacity();
        self.at_end = false;
        while (true) {
            if (!try self.advance()) return error.BlockCorrupted;
            if (self.pos == target) return true;
            if (self.pos > target) return error.BlockCorrupted;
        }
    }

    /// Position at the first entry whose InternalKey is `>= target`
    /// (`at_end` when none). Binary search the restart buckets, then walk.
    /// target must stay valid throughout the call and must not reference this
    /// iterator's current key/value, which repositioning may replace.
    pub fn seek(self: *BlockIter, target: []const u8) error{ BlockCorrupted, OutOfMemory }!void {
        const block = self.block;
        self.pos = 0;
        self.current = null;
        self.key = &.{};
        self.value = &.{};
        if (block.entries.len == 0) {
            self.at_end = true;
            return;
        }

        // first bucket whose restart key is >= target
        var lo: usize = 0;
        var hi: usize = block.restart_count;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const k = try self.restartKey(mid);
            if (internal_key.compare(k, target) == .lt) lo = mid + 1 else hi = mid;
        }
        // the answer sits in bucket lo-1 (target falls between restarts);
        // lo == 0 → bucket 0 holds it, lo == count → nothing matches
        const bucket = if (lo == 0) 0 else if (lo == block.restart_count) block.restart_count - 1 else lo - 1;
        self.pos = BlockReader.restartAt(block.tail, bucket);
        self.keys[self.front].clearRetainingCapacity(); // restart keys are shared=0
        self.at_end = false;
        self.ordinal = bucket * restart_interval;

        while (true) {
            const previous = self.key;
            const at = self.pos;
            const r = try self.decodeInto(at, previous);
            self.current = at;
            self.pos = r.next;
            self.value = r.value;
            self.at_end = self.pos >= block.entries.len;
            if (internal_key.compare(self.key, target) != .lt) return; // first >= target
            if (self.at_end) return; // target beyond the block
            self.ordinal += 1;
        }
    }

    /// A restart stores its complete key contiguously. Borrow it for binary
    /// search without touching reconstruction buffers or iterator position.
    fn restartKey(self: *const BlockIter, i: usize) error{BlockCorrupted}![]const u8 {
        const entries = self.block.entries;
        const off = BlockReader.restartAt(self.block.tail, i);
        if (off >= entries.len) return error.BlockCorrupted;
        const shared = varint.getU32(entries[off..]) catch return error.BlockCorrupted;
        if (shared.value != 0) return error.BlockCorrupted;
        const key_len = varint.getU32(entries[off + shared.len ..]) catch return error.BlockCorrupted;
        const value_len = varint.getU32(entries[off + shared.len + key_len.len ..]) catch return error.BlockCorrupted;
        const key_start = off + shared.len + key_len.len + value_len.len;
        const key_end = std.math.add(usize, key_start, @intCast(key_len.value)) catch return error.BlockCorrupted;
        const value_end = std.math.add(usize, key_end, @intCast(value_len.value)) catch return error.BlockCorrupted;
        if (value_end > entries.len) return error.BlockCorrupted;
        return entries[key_start..key_end];
    }
};

test "block restart probes: long keys borrow block bytes without changing iterator state" {
    const allocator = std.testing.allocator;
    var builder = try @import("block_builder.zig").BlockBuilder.init(allocator);
    defer builder.deinit();
    var keys: [40][1024]u8 = undefined;
    for (&keys, 0..) |*key, i| {
        var user: [1024 - internal_key.suffix_len]u8 = @splat('k');
        user[user.len - 1] = @intCast(i);
        _ = try internal_key.encode(&user, 1, .put, key);
        try builder.add(key, "payload");
    }
    try builder.finish();
    const block = try BlockReader.init(builder.data.items);
    var no_alloc = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var probes = BlockIter.init(no_alloc.allocator());
    defer probes.deinit();
    probes.resetTo(block);
    for (0..block.restart_count) |i| {
        const key = try probes.restartKey(i);
        try std.testing.expectEqualSlices(u8, &keys[i * restart_interval], key);
        try std.testing.expect(@intFromPtr(key.ptr) >= @intFromPtr(block.entries.ptr));
        try std.testing.expect(@intFromPtr(key.ptr) + key.len <= @intFromPtr(block.entries.ptr) + block.entries.len);
        try std.testing.expectEqual(@as(?usize, null), probes.current);
        try std.testing.expectEqual(@as(usize, 0), probes.pos);
        try std.testing.expectEqual(@as(usize, 0), probes.key.len);
    }
    var it = BlockIter.init(allocator);
    defer it.deinit();
    it.resetTo(block);
    for ([_]usize{ 0, 15, 16, 17, 31, 32, 39 }) |i| {
        try it.seek(&keys[i]);
        try std.testing.expectEqualSlices(u8, &keys[i], it.key);
        try std.testing.expectEqual(i, it.ordinal);
        const previous_key = it.key;
        const previous_pos = it.pos;
        _ = try it.restartKey(0);
        try std.testing.expectEqualSlices(u8, previous_key, it.key);
        try std.testing.expectEqual(previous_pos, it.pos);
    }
}

test "block restart probes: malformed headers key bounds and value bounds are rejected" {
    const malformed = [_][]const u8{
        "\x01\x00\x00", // a restart cannot share predecessor bytes
        "\x80", // truncated shared length
        "\x00\x80", // truncated key length
        "\x00\x01\x80", // truncated value length
        "\x00\x02\x00x", // truncated key
        "\x00\x01\x02xy", // truncated value after a complete key
        "\x00\xff\xff\xff\xff\x0f\x00", // oversized key
        "\x00\x00\xff\xff\xff\xff\x0f", // oversized value
    };
    for (malformed) |entry_bytes| {
        var bytes: [64]u8 = @splat(0);
        @memcpy(bytes[0..entry_bytes.len], entry_bytes);
        coding.putU32(bytes[entry_bytes.len + 4 ..][0..4], 1);
        const block = try BlockReader.init(bytes[0 .. entry_bytes.len + 8]);
        var it = BlockIter.init(std.testing.allocator);
        defer it.deinit();
        it.resetTo(block);
        try std.testing.expectError(error.BlockCorrupted, it.restartKey(0));
        try std.testing.expectError(error.BlockCorrupted, it.seek(""));
    }
}

test "block iterator: reverse prefix chains, restart boundaries and empty blocks" {
    const alloc = std.testing.allocator;
    var builder = try @import("block_builder.zig").BlockBuilder.init(alloc);
    defer builder.deinit();
    try builder.finish();
    var it = BlockIter.init(alloc);
    defer it.deinit();
    it.resetTo(try BlockReader.init(builder.data.items));
    try std.testing.expect(!try it.last());
    try std.testing.expect(!try it.prev());
    builder.reset();
    var keys: [49][32]u8 = undefined;
    var lengths: [49]usize = undefined;
    for (&keys, &lengths, 0..) |*key, *len, i| {
        var user: [16]u8 = undefined;
        len.* = try internal_key.encode(try std.fmt.bufPrint(&user, "prefix-{d:0>3}", .{i}), 1, .put, key);
        try builder.add(key[0..len.*], "value");
    }
    try builder.finish();
    it.resetTo(try BlockReader.init(builder.data.items));
    try std.testing.expect(try it.last());
    var i: usize = keys.len;
    while (i != 0) {
        i -= 1;
        try std.testing.expectEqualSlices(u8, keys[i][0..lengths[i]], it.key);
        try std.testing.expectEqual(i, it.ordinal);
        try std.testing.expectEqualStrings("value", it.value);
        try std.testing.expectEqual(i != 0, try it.prev());
    }
    try std.testing.expect(!try it.prev());
    try std.testing.expect(!try it.advance());
    for ([_]usize{ 1, 16, 17, 32, 48 }) |index| {
        try it.seek(keys[index][0..lengths[index]]);
        try std.testing.expect(try it.prev());
        try std.testing.expectEqualSlices(u8, keys[index - 1][0..lengths[index - 1]], it.key);
        try std.testing.expect(try it.advance());
        try std.testing.expectEqualSlices(u8, keys[index][0..lengths[index]], it.key);
    }
}

test "block iterator: short prefix chains and seeks need no allocations" {
    const alloc = std.testing.allocator;
    var builder = try @import("block_builder.zig").BlockBuilder.init(alloc);
    defer builder.deinit();
    var keys: [40][256]u8 = undefined;
    for (&keys, 0..) |*key, i| {
        var user: [247]u8 = @splat('a');
        user[user.len - 1] = @intCast(i + 1);
        const len = try internal_key.encode(&user, 1, .put, key);
        try std.testing.expectEqual(@as(usize, 256), len);
        try builder.add(key, "v");
    }
    try builder.finish();
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    var it = BlockIter.init(failing.allocator());
    defer it.deinit();
    const block = try BlockReader.init(builder.data.items);
    it.resetTo(block);
    try std.testing.expect(try it.first());
    for (keys, 0..) |key, i| {
        if (i != 0) try std.testing.expect(try it.advance());
        try std.testing.expectEqualSlices(u8, &key, it.key);
    }
    try std.testing.expect(!try it.advance());
    for ([_]usize{ 0, 15, 16, 31, 39, 7 }) |i| {
        try it.seek(&keys[i]);
        try std.testing.expectEqualSlices(u8, &keys[i], it.key);
    }
    it.resetTo(block);
    try std.testing.expect(try it.first());
    try std.testing.expectEqualSlices(u8, &keys[0], it.key);
}

fn exerciseLongKeys(allocator: std.mem.Allocator, block: BlockReader, expected: []const []const u8) !void {
    var it = BlockIter.init(allocator);
    defer it.deinit();
    it.resetTo(block);
    if (!try it.first()) return error.TestUnexpectedResult;
    for (expected, 0..) |key, i| {
        if (i != 0) try std.testing.expect(try it.advance());
        try std.testing.expectEqualSlices(u8, key, it.key);
    }
    try std.testing.expect(!try it.advance());
    for (expected) |key| {
        try it.seek(key);
        try std.testing.expectEqualSlices(u8, key, it.key);
    }
    try std.testing.expect(try it.last());
    var remaining = expected.len;
    while (remaining != 0) {
        remaining -= 1;
        try std.testing.expectEqualSlices(u8, expected[remaining], it.key);
        try std.testing.expectEqual(remaining != 0, try it.prev());
    }
    it.resetTo(block);
    try std.testing.expect(try it.first());
    try std.testing.expectEqualSlices(u8, expected[0], it.key);
}

test "block iterator: inline overflow transitions and all failed growth allocations" {
    const alloc = std.testing.allocator;
    var builder = try @import("block_builder.zig").BlockBuilder.init(alloc);
    defer builder.deinit();
    var keys: [8][4096]u8 = undefined;
    var expected: [8][]const u8 = undefined;
    for ([_]usize{ 256, 257, 32, 512, 257, 1024, 16, 4096 }, 0..) |len, i| {
        var user: [4096]u8 = @splat('x');
        user[0] = @intCast('a' + i / 2);
        user[1] = @intCast('a' + i % 2);
        const n = try internal_key.encode(user[0 .. len - internal_key.suffix_len], 1, .put, &keys[i]);
        expected[i] = keys[i][0..n];
        try builder.add(expected[i], "v");
    }
    try builder.finish();
    const block = try BlockReader.init(builder.data.items);
    try std.testing.checkAllAllocationFailures(alloc, exerciseLongKeys, .{ block, &expected });
}

test "block iterator: complete long keys need no reconstruction allocations" {
    const alloc = std.testing.allocator;
    var builder = try @import("block_builder.zig").BlockBuilder.init(alloc);
    defer builder.deinit();
    var keys: [40][1024]u8 = undefined;
    var expected: [40][]const u8 = undefined;
    for (&keys, &expected, 0..) |*key, *item, i| {
        var user: [1024 - internal_key.suffix_len]u8 = @splat('k');
        user[0] = @intCast(i + 1);
        _ = try internal_key.encode(&user, 1, .put, key);
        item.* = key;
        try builder.add(key, "value");
    }
    try builder.finish();
    const block = try BlockReader.init(builder.data.items);
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try exerciseLongKeys(failing.allocator(), block, &expected);
}

test "block iterator: borrowed long keys transition through prefix chains and restarts" {
    const alloc = std.testing.allocator;
    var builder = try @import("block_builder.zig").BlockBuilder.init(alloc);
    defer builder.deinit();
    var keys: [40][1024]u8 = undefined;
    var expected: [40][]const u8 = undefined;
    for (&keys, &expected, 0..) |*key, *item, i| {
        var user: [1024 - internal_key.suffix_len]u8 = @splat('k');
        user[0] = @intCast('a' + i / 4);
        user[user.len - 1] = @intCast(i % 4);
        _ = try internal_key.encode(&user, 1, .put, key);
        item.* = key;
        try builder.add(key, "value");
    }
    try builder.finish();
    const block = try BlockReader.init(builder.data.items);
    try std.testing.checkAllAllocationFailures(alloc, exerciseLongKeys, .{ block, &expected });
}

test "block iterator: invalid shared prefixes and truncated entries never reach key buffers" {
    var raw: [12]u8 = @splat(0);
    coding.putU32(raw[8..12], 1);
    raw[0] = 1; // first entry cannot share a byte with an empty predecessor
    raw[1] = 1;
    raw[3] = 'x';
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var it = BlockIter.init(failing.allocator());
    defer it.deinit();
    const block = try BlockReader.init(&raw);
    it.resetTo(block);
    try std.testing.expectError(error.BlockCorrupted, it.first());
    raw[0] = 0;
    raw[1] = 127; // unshared bytes extend past the entries region
    it.resetTo(block);
    try std.testing.expectError(error.BlockCorrupted, it.first());
    raw[0] = 0x80;
    raw[1] = 0x80;
    raw[2] = 0x80;
    raw[3] = 0x80;
    it.resetTo(block);
    try std.testing.expectError(error.BlockCorrupted, it.first());
}

test "block round-trip: scan, exact seek, between-keys, past-end" {
    const alloc = std.testing.allocator;
    var builder = try @import("block_builder.zig").BlockBuilder.init(alloc);
    defer builder.deinit();

    var keys: [17][32]u8 = undefined;
    var key_lens: [17]usize = undefined;
    var kbuf: [16]u8 = undefined;
    for (0..17) |i| {
        const user = try std.fmt.bufPrint(&kbuf, "key{d:0>4}", .{i});
        key_lens[i] = try internal_key.encode(user, 100 + i, .put, &keys[i]);
        try builder.add(keys[i][0..key_lens[i]], "value");
    }
    try builder.finish();
    const block = try BlockReader.init(builder.data.items);

    var it = BlockIter.init(alloc);
    defer it.deinit();
    it.resetTo(block);

    var count: usize = 0;
    var ok = try it.first();
    while (ok) : (ok = try it.advance()) {
        try std.testing.expectEqualStrings(keys[count][0..key_lens[count]], it.key);
        try std.testing.expectEqualStrings("value", it.value);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 17), count);

    var tbuf: [64]u8 = undefined;

    it.resetTo(block);
    try it.seek(keys[8][0..key_lens[8]]); // exact hit
    try std.testing.expect(!it.at_end);
    try std.testing.expectEqualStrings(keys[8][0..key_lens[8]], it.key);

    it.resetTo(block);
    const tl = try internal_key.encode("key00035", 0, .put, &tbuf);
    try it.seek(tbuf[0..tl]); // falls between key0003 and key0004
    try std.testing.expect(!it.at_end);
    try std.testing.expectEqualStrings(keys[4][0..key_lens[4]], it.key);

    it.resetTo(block);
    const tz = try internal_key.encode("zzz", 0, .put, &tbuf);
    try it.seek(tbuf[0..tz]);
    try std.testing.expect(it.at_end);

    it.resetTo(block);
    const te = try internal_key.encode("", 0, .put, &tbuf);
    try it.seek(tbuf[0..te]);
    try std.testing.expect(!it.at_end);
    try std.testing.expectEqualStrings(keys[0][0..key_lens[0]], it.key);
}
