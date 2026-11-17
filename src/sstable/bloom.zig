//! Partitioned Bloom filter: hashing and probing. One filter serves one
//! data block, so a negative lookup reads only that filter. The user key
//! is hashed (seq/kind already stripped by the caller); `h2` is forced odd
//! so the second stride cannot collapse onto `h1`.

const std = @import("std");
const coding = @import("../util/coding.zig");

pub const filter_type_bloom: u8 = 1;
pub const default_bits_per_key: u32 = 10;

pub fn hashUserKey(user_key: []const u8) u64 {
    var h = std.hash.XxHash64.init(0);
    h.update(user_key);
    return h.final();
}

/// Bit position of probe `j` inside a filter of `nbits` bits.
pub inline fn bitIndex(h: u64, j: usize, nbits: u64) u64 {
    const h1 = h & 0xFFFF_FFFF;
    const h2 = (h >> 32) | 1;
    return (h1 + @as(u64, j) * h2) % nbits;
}

/// k = round(bits_per_key * ln2); callers validate `1 <= bits_per_key <= 64`.
pub fn probeCount(bits_per_key: u32) u8 {
    const k: f64 = @round(@as(f64, @floatFromInt(bits_per_key)) * 0.6931471805599453);
    return @intCast(@max(1, @as(u64, @intFromFloat(k))));
}

/// Set all `probe` bits for `user_key` in `bits` (the builder's per-block
/// core; sizing is the caller's job).
pub fn addKey(bits: []u8, user_key: []const u8, probe: u8) void {
    if (bits.len == 0) return;
    addHash(bits, hashUserKey(user_key), probe);
}

fn addHash(bits: []u8, h: u64, probe: u8) void {
    if (bits.len == 0) return;
    const nbits: u64 = bits.len * 8;
    for (0..probe) |j| {
        const bit = bitIndex(h, j, nbits);
        bits[bit / 8] |= @as(u8, 1) << @intCast(bit & 7);
    }
}

/// View over one partition's bits. An empty extent fails open: a malformed
/// filter must never cause data to be skipped.
pub const Filter = struct {
    bits: []const u8,
    probe: u8,

    pub fn mayContain(self: Filter, user_key: []const u8) bool {
        if (self.bits.len == 0) return true;
        if (self.probe == 0) return true; // malformed header: fail open
        const nbits: u64 = self.bits.len * 8;
        const h = hashUserKey(user_key);
        for (0..self.probe) |j| {
            const bit = bitIndex(h, j, nbits);
            const mask = @as(u8, 1) << @intCast(bit & 7);
            if (self.bits[bit / 8] & mask == 0) return false;
        }
        return true;
    }
};

/// Collects one data block's user keys, sizes the partition exactly
/// `ceil(n * bits_per_key / 8)` bytes (minimum 1), and emits the bits.
/// The exact sizing needs the count up front. Retain hashes, not caller key
/// bytes; partition resets reuse their storage without per-key allocations.
pub const FilterBuilder = struct {
    allocator: std.mem.Allocator,
    bits_per_key: u32,
    probe: u8,
    hashes: std.ArrayListUnmanaged(u64) = .empty,

    pub fn init(allocator: std.mem.Allocator, bits_per_key: u32) error{InvalidOptions}!FilterBuilder {
        if (bits_per_key < 1 or bits_per_key > 64) return error.InvalidOptions;
        return .{ .allocator = allocator, .bits_per_key = bits_per_key, .probe = probeCount(bits_per_key) };
    }

    pub fn add(self: *FilterBuilder, user_key: []const u8) error{OutOfMemory}!void {
        try self.hashes.append(self.allocator, hashUserKey(user_key));
    }

    /// Append the sized bit array to `out`, then `reset` for the next block.
    pub fn finishInto(self: *FilterBuilder, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
        const count: u64 = @intCast(self.hashes.items.len);
        const byte_len: usize = @intCast(@max(@as(u64, 1), (count * self.bits_per_key + 7) / 8));
        const start = out.items.len;
        try out.appendNTimes(self.allocator, 0, byte_len);
        const bits = out.items[start .. start + byte_len];
        for (self.hashes.items) |h| addHash(bits, h, self.probe);
        self.reset();
    }

    pub fn reset(self: *FilterBuilder) void {
        self.hashes.clearRetainingCapacity();
    }

    pub fn deinit(self: *FilterBuilder) void {
        self.hashes.deinit(self.allocator);
    }
};

pub const header_base = 10; // type + probe + bpk + num_filters

pub fn headerSize(num_filters: u32) usize {
    return header_base + (@as(usize, num_filters) + 1) * 4;
}

/// Parsed filter-block header. `probe = 0` marks "cannot evaluate" (unknown
/// filter type or malformed probe count): every query fails open.
pub const FilterHeader = struct {
    probe: u8,
    bits_per_key: u32,
    num_filters: u32,
    /// Raw LE u32 offsets, `num_filters + 1` entries.
    offsets: []const u8,
    /// Whole block data (header + filter bits), needed by `filterBits`.
    data: []const u8,

    /// Filter `i`'s bits; `i < num_filters` (decode validated the extents).
    pub fn filterBits(self: FilterHeader, i: usize) []const u8 {
        std.debug.assert(i < self.num_filters);
        const a = offsetAt(self.offsets, i);
        const b = offsetAt(self.offsets, i + 1);
        return self.data[a..b];
    }
};

pub fn offsetAt(offsets: []const u8, i: usize) usize {
    const off = i * 4;
    return @intCast(coding.getU32(offsets[off .. off + 4][0..4]));
}

/// Structural damage here is `SSTableCorrupted` (fail closed): an offset
/// array that does not fit, a descending pair, an extent reaching past the
/// data, or filters overlapping the header would otherwise steer a query at
/// arbitrary bytes — and an all-zero fake filter would skip live data.
///
/// `header` holds just `header_base + 4×(n+1)` bytes (what a TableReader
/// caches at open); `block_data_len` is the full block length, so extent
/// checks still see the whole picture without reading it.
pub fn decodeFilterHeader(header: []const u8, block_data_len: u64) error{SSTableCorrupted}!FilterHeader {
    if (header.len < header_base) return error.SSTableCorrupted;
    if (header[0] != filter_type_bloom) {
        // unknown kind: nothing to verify, so nothing to trust — fail open
        return .{ .probe = 0, .bits_per_key = 0, .num_filters = 0, .offsets = &.{}, .data = header };
    }
    const probe = header[1];
    const bits_per_key = coding.getU32(header[2..6]);
    const num: u32 = coding.getU32(header[6..10]);
    const need = headerSize(num);
    if (need > header.len) return error.SSTableCorrupted;
    const offsets = header[header_base..need];
    var prev: usize = need; // filters may not overlap the header
    var i: usize = 0;
    while (i <= num) : (i += 1) {
        const cur = offsetAt(offsets, i);
        if (cur < prev) return error.SSTableCorrupted; // first or descending
        prev = cur;
    }
    if (prev > block_data_len) return error.SSTableCorrupted;
    return .{ .probe = probe, .bits_per_key = bits_per_key, .num_filters = num, .offsets = offsets, .data = header };
}

/// Whole-block parse: header checks against the actual data (tests and
/// single-buffer readers; `filterBits` works only with the full data).
pub fn decodeFilterBlock(data: []const u8) error{SSTableCorrupted}!FilterHeader {
    if (data.len < header_base) return error.SSTableCorrupted;
    const num: u32 = coding.getU32(data[6..10]);
    const need = headerSize(num);
    if (need > data.len) return error.SSTableCorrupted;
    var h = try decodeFilterHeader(data[0..need], data.len);
    h.data = data;
    return h;
}

test "bloom: exact sizing, all present, false-positive rate on target" {
    const alloc = std.testing.allocator;
    var fb = try FilterBuilder.init(alloc, default_bits_per_key);
    defer fb.deinit();
    var kbuf: [24]u8 = undefined;
    for (0..1000) |i| {
        const key = try std.fmt.bufPrint(&kbuf, "user{d}", .{i});
        try fb.add(key);
    }
    var bits: std.ArrayListUnmanaged(u8) = .empty;
    defer bits.deinit(alloc);
    try fb.finishInto(&bits);
    try std.testing.expectEqual(@as(usize, 1250), bits.items.len); // 1000×10/8

    // assemble the full block the way table_builder will
    var full: std.ArrayListUnmanaged(u8) = .empty;
    defer full.deinit(alloc);
    try full.append(alloc, filter_type_bloom);
    try full.append(alloc, fb.probe);
    var word: [4]u8 = undefined;
    coding.putU32(&word, default_bits_per_key);
    try full.appendSlice(alloc, &word);
    coding.putU32(&word, 1);
    try full.appendSlice(alloc, &word);
    const base: u32 = @intCast(headerSize(1));
    coding.putU32(&word, base);
    try full.appendSlice(alloc, &word);
    coding.putU32(&word, base + 1250);
    try full.appendSlice(alloc, &word);
    try full.appendSlice(alloc, bits.items);

    const h = try decodeFilterBlock(full.items);
    try std.testing.expectEqual(@as(u32, 7), h.probe);
    try std.testing.expectEqual(@as(u32, 1), h.num_filters);
    try std.testing.expectEqual(@as(usize, 1250), h.filterBits(0).len);
    const f = Filter{ .bits = h.filterBits(0), .probe = h.probe };

    for (0..1000) |i| {
        const key = try std.fmt.bufPrint(&kbuf, "user{d}", .{i});
        try std.testing.expect(f.mayContain(key));
    }
    // theoretical FPR at 10 bpk, k=7 ≈ 0.8% — allow 1.5% headroom
    var fp: usize = 0;
    for (0..10000) |i| {
        const key = try std.fmt.bufPrint(&kbuf, "miss{d}", .{i});
        if (f.mayContain(key)) fp += 1;
    }
    try std.testing.expect(fp <= 150);
}

test "bloom: structural damage fails closed, unknown kind fails open" {
    var buf: [32]u8 = undefined;

    try std.testing.expectError(error.SSTableCorrupted, decodeFilterBlock(buf[0..9]));

    const hdr = struct {
        fn write(b: []u8, off0: u32, off1: u32) void {
            @memset(b, 0);
            b[0] = filter_type_bloom;
            b[1] = 7;
            coding.putU32(b[2..6], 10);
            coding.putU32(b[6..10], 1);
            coding.putU32(b[10..14], off0);
            coding.putU32(b[14..18], off1);
        }
    }.write;

    hdr(&buf, 20, 19); // descending pair
    try std.testing.expectError(error.SSTableCorrupted, decodeFilterBlock(&buf));
    hdr(&buf, 10, 18); // filter_0 would overlap the header
    try std.testing.expectError(error.SSTableCorrupted, decodeFilterBlock(&buf));
    hdr(&buf, 18, 99); // extent past the block data
    try std.testing.expectError(error.SSTableCorrupted, decodeFilterBlock(&buf));
    hdr(&buf, 18, 32); // valid: filter_0 = data[18..32]
    const ok = try decodeFilterBlock(&buf);
    try std.testing.expectEqual(@as(usize, 14), ok.filterBits(0).len);

    @memset(&buf, 0);
    buf[0] = 9; // unknown kind → probe 0, every query fails open
    const unk = try decodeFilterBlock(&buf);
    try std.testing.expectEqual(@as(u8, 0), unk.probe);
}

test "bloom: probe count follows round(bits_per_key × ln2)" {
    try std.testing.expectEqual(@as(u8, 7), probeCount(10));
    try std.testing.expectEqual(@as(u8, 1), probeCount(1));
    try std.testing.expectEqual(@as(u8, 44), probeCount(64));
}

test "bloom builder preserves partition bytes and owns hashes of mutable keys" {
    const allocator = std.testing.allocator;
    var long_key: [4096]u8 = undefined;
    for (&long_key, 0..) |*byte, index| byte.* = @truncate(index *% 37);
    const keys: []const []const u8 = &.{ "", "repeat", "repeat", &long_key, "tail" };
    for ([_]u32{ 1, 10, 64 }) |bits_per_key| {
        var builder = try FilterBuilder.init(allocator, bits_per_key);
        defer builder.deinit();
        var output: std.ArrayListUnmanaged(u8) = .empty;
        defer output.deinit(allocator);
        try output.appendSlice(allocator, "prefix");
        const partition_len = (keys.len * bits_per_key + 7) / 8;
        var reference: [40]u8 = @splat(0);
        for (keys) |key| {
            addKey(reference[0..partition_len], key, builder.probe);
            try builder.add(key);
        }
        try builder.finishInto(&output);
        try std.testing.expectEqualStrings("prefix", output.items[0..6]);
        try std.testing.expectEqualSlices(u8, reference[0..partition_len], output.items[6..]);

        var mutable = [_]u8{ 'o', 'w', 'n' };
        var next: [8]u8 = @splat(0);
        const next_len = (bits_per_key + 7) / 8;
        addKey(next[0..next_len], &mutable, builder.probe);
        try builder.add(&mutable);
        @memset(&mutable, 'x');
        const next_start = output.items.len;
        try builder.finishInto(&output);
        try std.testing.expectEqualSlices(u8, next[0..next_len], output.items[next_start..]);

        const empty_start = output.items.len;
        try builder.finishInto(&output);
        try std.testing.expectEqualSlices(u8, &.{0}, output.items[empty_start..]);
        try builder.add("discarded");
        builder.reset();
        const reset_start = output.items.len;
        try builder.finishInto(&output);
        try std.testing.expectEqualSlices(u8, &.{0}, output.items[reset_start..]);
    }
}

test "bloom builder keeps the committed partition byte format" {
    const allocator = std.testing.allocator;
    const long_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const cases = [_]struct {
        bits_per_key: u32,
        keys: []const []const u8,
        expected: []const u8,
    }{
        .{ .bits_per_key = 1, .keys = &.{""}, .expected = &.{0x02} },
        .{
            .bits_per_key = 10,
            .keys = &.{ "a", "repeat", "repeat" },
            .expected = &.{ 0x02, 0x50, 0xf1, 0xaf },
        },
        .{
            .bits_per_key = 64,
            .keys = &.{ "alpha", long_key },
            .expected = &.{ 0x3e, 0x80, 0x0f, 0xe0, 0x03, 0xf8, 0x00, 0x3c, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f, 0x00 },
        },
    };

    // Literals above were generated by the pre-optimization FilterBuilder;
    // they pin the on-disk format without sharing the current hash path.
    for (cases) |case| {
        var builder = try FilterBuilder.init(allocator, case.bits_per_key);
        defer builder.deinit();
        var output: std.ArrayListUnmanaged(u8) = .empty;
        defer output.deinit(allocator);
        for (case.keys) |key| try builder.add(key);
        try builder.finishInto(&output);
        try std.testing.expectEqualSlices(u8, case.expected, output.items);
    }
}

test "bloom builder reuses partition storage without allocating for each key" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var builder = try FilterBuilder.init(failing.allocator(), default_bits_per_key);
    defer builder.deinit();
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(failing.allocator());
    for (0..128) |_| try builder.add("warm");
    try output.ensureTotalCapacity(failing.allocator(), 160);
    try builder.finishInto(&output);
    output.clearRetainingCapacity();
    const before = failing.alloc_index;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    const long_key: [4096]u8 = @splat('k');
    for (0..128) |_| try builder.add(&long_key);
    try builder.finishInto(&output);
    try std.testing.expectEqual(before, failing.alloc_index);
    try std.testing.expectEqual(@as(usize, 160), output.items.len);
    try std.testing.expect((Filter{ .bits = output.items, .probe = builder.probe }).mayContain(&long_key));
}

fn buildPartitionsWithFailures(allocator: std.mem.Allocator) !void {
    var builder = try FilterBuilder.init(allocator, 10);
    defer builder.deinit();
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);
    var key: [8]u8 = undefined;
    for (0..80) |index| {
        std.mem.writeInt(u64, &key, index, .little);
        try builder.add(&key);
    }
    try builder.finishInto(&output);
    try builder.add("next partition");
    try builder.finishInto(&output);
}

test "bloom builder releases partial partitions on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildPartitionsWithFailures, .{});
}

test "bloom builder keeps accepted keys when partition emission fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var builder = try FilterBuilder.init(failing.allocator(), 10);
    defer builder.deinit();
    try builder.add("accepted");
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(failing.allocator());
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, builder.finishInto(&output));
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
    failing.fail_index = std.math.maxInt(usize);
    try builder.finishInto(&output);
    try std.testing.expect((Filter{ .bits = output.items, .probe = builder.probe }).mayContain("accepted"));
    const previous = output.items.len;
    try builder.finishInto(&output);
    try std.testing.expectEqualSlices(u8, &.{0}, output.items[previous..]);
}

test "bloom builder preserves historical filter bytes" {
    // Golden bytes generated from the old key-copying builder at 10 bits/key.
    // This test must not call addKey/addHash, so a hash change cannot move it.
    const keys = [_][]const u8{ "", "alpha", "beta", "this-is-a-much-longer-user-key" };
    const expected = [_]u8{ 48, 27, 119, 222, 227 };
    var builder = try FilterBuilder.init(std.testing.allocator, default_bits_per_key);
    defer builder.deinit();
    for (keys) |key| try builder.add(key);
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try builder.finishInto(&output);
    try std.testing.expectEqualSlices(u8, &expected, output.items);
}
