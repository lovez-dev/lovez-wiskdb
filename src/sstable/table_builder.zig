//! SSTable writer: size-targeted data blocks (entries never split) feed
//! per-block Bloom partitions and the Index; `finish` assembles Filter,
//! Props, MetaIndex, Index and Footer into one in-memory image. The builder
//! retains the complete table until deinit.

const std = @import("std");
const flate = std.compress.flate;
const sst = @import("format.zig");
const BlockBuilder = @import("block_builder.zig").BlockBuilder;
const bloom = @import("bloom.zig");
const internal_key = @import("../util/internal_key.zig");
const ivfmt = @import("../util/internal_value.zig");
const coding = @import("../util/coding.zig");
const varint = @import("../util/varint.zig");
const mf = @import("../manifest/format.zig");

pub const Compression = enum { none, deflate };

pub const Options = struct {
    block_size: u32 = sst.default_block_size,
    bits_per_key: u32 = bloom.default_bits_per_key,
    compression: Compression = .none,
};

pub const TableBuilder = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    out: std.ArrayListUnmanaged(u8) = .empty,
    data: BlockBuilder,
    index: BlockBuilder,
    filter: bloom.FilterBuilder,
    filter_bits: std.ArrayListUnmanaged(u8) = .empty,
    filter_lens: std.ArrayListUnmanaged(u32) = .empty,
    scratch: std.ArrayListUnmanaged(u8) = .empty, // deflate staging

    num_entries: u64 = 0,
    num_deletes: u64 = 0,
    min_seq: u64 = std.math.maxInt(u64),
    max_seq: u64 = 0,
    smallest_user: std.ArrayListUnmanaged(u8) = .empty,
    largest_user: std.ArrayListUnmanaged(u8) = .empty,
    raw_key_size: u64 = 0,
    raw_value_size: u64 = 0,
    /// Distinct VLog ids, sorted, capped at 64 — past the cap the encoder
    /// switches to range mode (GC then falls back to scanning, never to
    /// wrongly deleting).
    vlog_ids: std.ArrayListUnmanaged(u64) = .empty,
    vlog_overflow: bool = false,
    vlog_min: u64 = std.math.maxInt(u64),
    vlog_max: u64 = 0,
    packed_vlog_ids: sst.BlockHandle = .{ .offset = 0, .size = 0 },
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, opts: Options) error{ InvalidOptions, OutOfMemory }!TableBuilder {
        const filter = try bloom.FilterBuilder.init(allocator, opts.bits_per_key);
        var data = try BlockBuilder.init(allocator);
        errdefer data.deinit();
        const index = try BlockBuilder.init(allocator);
        return .{
            .allocator = allocator,
            .opts = opts,
            .data = data,
            .index = index,
            .filter = filter,
        };
    }

    pub fn add(self: *TableBuilder, ik: []const u8, iv: []const u8) error{OutOfMemory}!void {
        std.debug.assert(!self.finished);
        std.debug.assert(ik.len >= internal_key.suffix_len);
        const header = ivfmt.Header.decode(iv) catch unreachable;
        const view = internal_key.decode(ik) catch unreachable;

        self.num_entries += 1;
        self.raw_key_size += ik.len;
        self.raw_value_size += iv.len;
        if (view.seq < self.min_seq) self.min_seq = view.seq;
        if (view.seq > self.max_seq) self.max_seq = view.seq;
        if (header.isDeleted()) self.num_deletes += 1;

        if (self.num_entries == 1) {
            try self.smallest_user.appendSlice(self.allocator, view.user);
        } else if (std.mem.order(u8, view.user, self.smallest_user.items) == .lt) {
            self.smallest_user.clearRetainingCapacity();
            try self.smallest_user.appendSlice(self.allocator, view.user);
        }
        if (std.mem.order(u8, view.user, self.largest_user.items) == .gt) {
            self.largest_user.clearRetainingCapacity();
            try self.largest_user.appendSlice(self.allocator, view.user);
        }

        const vlog_id = header.file_id;
        if (vlog_id != 0) try self.trackVlogId(vlog_id);

        try self.filter.add(view.user);
        try self.data.add(ik, iv);
        if (self.data.estimatedSize() >= self.opts.block_size) try self.flushBlock();
    }

    fn flushBlock(self: *TableBuilder) error{OutOfMemory}!void {
        if (self.data.entry_count == 0) return;
        try self.data.finish();
        const bytes = self.data.data.items;

        const handle = try self.appendBlock(bytes);

        var hbuf: [20]u8 = undefined;
        const hn = sst.encodeHandle(handle, &hbuf) catch unreachable;
        try self.index.add(self.data.last_key.items, hbuf[0..hn]);

        const before = self.filter_bits.items.len;
        try self.filter.finishInto(&self.filter_bits);
        try self.filter_lens.append(self.allocator, @intCast(self.filter_bits.items.len - before));
        self.data.reset();
    }

    fn trackVlogId(self: *TableBuilder, id: u64) error{OutOfMemory}!void {
        if (id < self.vlog_min) self.vlog_min = id;
        if (id > self.vlog_max) self.vlog_max = id;
        if (self.vlog_overflow) return;
        var lo: usize = 0;
        var hi: usize = self.vlog_ids.items.len;
        while (lo < hi) { // first id >= target, keeps the list sorted
            const mid = (lo + hi) / 2;
            if (self.vlog_ids.items[mid] < id) lo = mid + 1 else hi = mid;
        }
        if (lo < self.vlog_ids.items.len and self.vlog_ids.items[lo] == id) return;
        if (self.vlog_ids.items.len >= 64) {
            self.vlog_overflow = true;
            return;
        }
        try self.vlog_ids.insert(self.allocator, lo, id);
    }

    /// Assemble the remaining blocks and footer; returns the image (valid
    /// until `deinit`). Compression is applied per block at this write
    /// point, never to already-assembled bytes. On failure, only `deinit`
    /// is allowed: partially serialized blocks cannot be retried.
    pub fn finish(self: *TableBuilder) error{OutOfMemory}![]const u8 {
        std.debug.assert(!self.finished);
        self.finished = true;
        try self.flushBlock();

        // Filter block: header (type/k/bpk/num + n+1 offsets) + partition bits
        const num: u32 = @intCast(self.filter_lens.items.len);
        var head: [bloom.header_base]u8 = undefined;
        head[0] = bloom.filter_type_bloom;
        head[1] = self.filter.probe;
        coding.putU32(head[2..6], self.filter.bits_per_key);
        coding.putU32(head[6..10], num);
        const filter_off = self.out.items.len; // block starts at the header
        try self.out.appendSlice(self.allocator, &head);
        var cum: u32 = @intCast(bloom.headerSize(num));
        var i: u32 = 0;
        while (i < num) : (i += 1) {
            var word: [4]u8 = undefined;
            coding.putU32(&word, cum);
            try self.out.appendSlice(self.allocator, &word);
            cum += self.filter_lens.items[i];
        }
        var tail: [4]u8 = undefined;
        coding.putU32(&tail, cum); // end of the last filter
        try self.out.appendSlice(self.allocator, &tail);
        try self.out.appendSlice(self.allocator, self.filter_bits.items);
        const bloom_handle: sst.BlockHandle = .{ .offset = filter_off, .size = self.out.items.len - filter_off };
        var ftrailer: [sst.trailer_len]u8 = undefined;
        sst.writeTrailer(&ftrailer, self.out.items[filter_off..], sst.block_type_none);
        try self.out.appendSlice(self.allocator, &ftrailer);

        const props_handle = try self.writeProps();

        var meta = try BlockBuilder.init(self.allocator);
        defer meta.deinit();
        var hbuf: [20]u8 = undefined;
        const hn = sst.encodeHandle(bloom_handle, &hbuf) catch unreachable;
        try meta.add(sst.metaindex_bloom_key, hbuf[0..hn]);
        const hn2 = sst.encodeHandle(props_handle, &hbuf) catch unreachable;
        try meta.add(sst.metaindex_props_key, hbuf[0..hn2]);
        try meta.finish();
        const meta_handle = try self.appendBlock(meta.data.items);

        try self.index.finish();
        const index_handle = try self.appendBlock(self.index.data.items);

        var foot: [sst.footer_len]u8 = undefined;
        sst.encodeFooter(&foot, .{ .index = index_handle, .metaindex = meta_handle });
        try self.out.appendSlice(self.allocator, &foot);
        return self.out.items;
    }

    /// Call after successful `finish`. The caller owns all returned slices
    /// with this builder's allocator; they remain valid after `deinit`.
    pub fn metadata(self: *const TableBuilder, level: u32, file_id: u64) error{OutOfMemory}!mf.FileMeta {
        std.debug.assert(self.finished);
        const smallest = try self.allocator.dupe(u8, self.smallest_user.items);
        errdefer self.allocator.free(smallest);
        const largest = try self.allocator.dupe(u8, self.largest_user.items);
        errdefer self.allocator.free(largest);
        const start: usize = @intCast(self.packed_vlog_ids.offset);
        const len: usize = @intCast(self.packed_vlog_ids.size);
        const vlog_ids = try self.allocator.dupe(u8, self.out.items[start..][0..len]);
        return .{
            .level = level,
            .file_id = file_id,
            .file_size = self.out.items.len,
            .smallest = smallest,
            .largest = largest,
            .min_seq = if (self.num_entries == 0) 0 else self.min_seq,
            .max_seq = self.max_seq,
            .vlog_ids = vlog_ids,
        };
    }

    /// Append one block plus its 5-byte trailer; `size` excludes the
    /// trailer (readers use `size + trailer_len`). Deflate runs first and
    /// is kept only when it shrinks the block; a stored compressed block
    /// is `u32 LE uncompressed_size ‖ deflate_stream` under type=1.
    fn appendBlock(self: *TableBuilder, block_bytes: []const u8) error{OutOfMemory}!sst.BlockHandle {
        const off = self.out.items.len;
        var block_type: u8 = sst.block_type_none;
        if (self.opts.compression == .deflate and try self.tryDeflate(block_bytes)) {
            try self.out.appendSlice(self.allocator, self.scratch.items);
            block_type = sst.block_type_deflate;
        } else {
            try self.out.appendSlice(self.allocator, block_bytes);
        }
        const size = self.out.items.len - off;
        var trailer: [sst.trailer_len]u8 = undefined;
        sst.writeTrailer(&trailer, self.out.items[off..], block_type);
        try self.out.appendSlice(self.allocator, &trailer);
        return .{ .offset = off, .size = size };
    }

    /// Compress into `scratch` as `u32 LE size ‖ stream`; false when the
    /// stored form would not be smaller than raw.
    fn tryDeflate(self: *TableBuilder, data: []const u8) error{OutOfMemory}!bool {
        self.scratch.clearRetainingCapacity();
        try self.scratch.appendNTimes(self.allocator, 0, 4 + data.len + data.len / 8 + 64);
        var w = std.Io.Writer.fixed(self.scratch.items[4..]);
        var window: [flate.max_window_len]u8 = undefined; // one block at a time
        var c = flate.Compress.init(&w, &window, .raw, .default) catch return false;
        c.writer.writeAll(data) catch {
            self.scratch.clearRetainingCapacity();
            return false; // in-memory writer fails only on capacity, which the headroom covers
        };
        c.finish() catch {
            self.scratch.clearRetainingCapacity();
            return false;
        };
        if (4 + w.end >= data.len) {
            self.scratch.clearRetainingCapacity();
            return false;
        }
        self.scratch.shrinkRetainingCapacity(4 + w.end);
        coding.putU32(self.scratch.items[0..4], @intCast(data.len));
        return true;
    }
    /// ASCII `key=value\n` lines. `vlog_ids=` is last and its binary
    /// payload runs to the end of the block: varints may contain 0x0A, so
    /// the payload must not be newline-framed (readers take "rest of
    /// block" after the key).
    fn writeProps(self: *TableBuilder) error{OutOfMemory}!sst.BlockHandle {
        const start = self.out.items.len;
        const min_seq = if (self.num_entries == 0) 0 else self.min_seq;
        try self.appendProp("num_entries", self.num_entries);
        try self.appendProp("num_deletes", self.num_deletes);
        try self.appendProp("min_seq", min_seq);
        try self.appendProp("max_seq", self.max_seq);
        try self.out.appendSlice(self.allocator, "smallest_user_key=");
        try self.appendHex(self.smallest_user.items);
        try self.out.append(self.allocator, '\n');
        try self.out.appendSlice(self.allocator, "largest_user_key=");
        try self.appendHex(self.largest_user.items);
        try self.out.append(self.allocator, '\n');
        try self.appendProp("raw_key_size", self.raw_key_size);
        try self.appendProp("raw_value_size", self.raw_value_size);

        try self.out.appendSlice(self.allocator, "vlog_ids=");
        const vlog_start = self.out.items.len;
        var scratch: [10]u8 = undefined;
        if (self.vlog_overflow) {
            try self.out.append(self.allocator, 0); // mode 0: range(min, max)
            const n1 = varint.putU64(&scratch, self.vlog_min) catch unreachable;
            try self.out.appendSlice(self.allocator, scratch[0..n1]);
            const n2 = varint.putU64(&scratch, self.vlog_max) catch unreachable;
            try self.out.appendSlice(self.allocator, scratch[0..n2]);
        } else {
            try self.out.append(self.allocator, 1); // mode 1: count + list
            const nc = varint.putU32(&scratch, @intCast(self.vlog_ids.items.len)) catch unreachable;
            try self.out.appendSlice(self.allocator, scratch[0..nc]);
            var prev: u64 = 0;
            for (self.vlog_ids.items, 0..) |id, idx| {
                const delta = if (idx == 0) id else id - prev;
                const n = varint.putU64(&scratch, delta) catch unreachable;
                try self.out.appendSlice(self.allocator, scratch[0..n]);
                prev = id;
            }
        }

        self.packed_vlog_ids = .{ .offset = vlog_start, .size = self.out.items.len - vlog_start };
        const size = self.out.items.len - start;
        var trailer: [sst.trailer_len]u8 = undefined;
        sst.writeTrailer(&trailer, self.out.items[start..], sst.block_type_none);
        try self.out.appendSlice(self.allocator, &trailer);
        return .{ .offset = start, .size = size };
    }

    fn appendProp(self: *TableBuilder, comptime name: []const u8, value: u64) error{OutOfMemory}!void {
        // A u64 needs at most 20 decimal digits, plus the name, = and newline.
        var buffer: [name.len + 22]u8 = undefined;
        const s = std.fmt.bufPrint(&buffer, name ++ "={d}\n", .{value}) catch unreachable;
        try self.out.appendSlice(self.allocator, s);
    }

    fn appendHex(self: *TableBuilder, bytes: []const u8) error{OutOfMemory}!void {
        var two: [2]u8 = undefined;
        for (bytes) |b| {
            const s = std.fmt.bufPrint(&two, "{x:0>2}", .{b}) catch unreachable; // exactly 2 chars
            try self.out.appendSlice(self.allocator, s);
        }
    }

    pub fn deinit(self: *TableBuilder) void {
        self.data.deinit();
        self.index.deinit();
        self.filter.deinit();
        self.out.deinit(self.allocator);
        self.filter_bits.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.filter_lens.deinit(self.allocator);
        self.smallest_user.deinit(self.allocator);
        self.largest_user.deinit(self.allocator);
        self.vlog_ids.deinit(self.allocator);
    }
};

test "table builder: numeric props preserve decimal bounds without temporary allocations" {
    const allocator = std.testing.allocator;
    var tb = try TableBuilder.init(allocator, .{});
    defer tb.deinit();
    try tb.out.ensureTotalCapacity(allocator, 512);
    var no_alloc = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    tb.allocator = no_alloc.allocator();
    defer tb.allocator = allocator;

    try tb.appendProp("num_entries", 0);
    try tb.appendProp("num_deletes", std.math.maxInt(u64));
    try tb.appendProp("min_seq", 0);
    try tb.appendProp("max_seq", std.math.maxInt(u64));
    try tb.appendProp("raw_key_size", std.math.maxInt(u64));
    try tb.appendProp("raw_value_size", 0);
    try std.testing.expectEqualStrings(
        "num_entries=0\nnum_deletes=18446744073709551615\n" ++
            "min_seq=0\nmax_seq=18446744073709551615\n" ++
            "raw_key_size=18446744073709551615\nraw_value_size=0\n",
        tb.out.items,
    );
}

test "table builder: multi-block image with valid footer and props" {
    const alloc = std.testing.allocator;
    var tb = try TableBuilder.init(alloc, .{ .block_size = 256 });
    defer tb.deinit();

    var kbuf: [32]u8 = undefined;
    var ikbuf: [48]u8 = undefined;
    const iv: [21]u8 = @splat(0); // all-inline, no deletes
    for (0..50) |i| {
        const user = try std.fmt.bufPrint(&kbuf, "key{d:0>4}", .{i});
        const ikl = try internal_key.encode(user, @as(u64, i) + 1, .put, &ikbuf);
        try tb.add(ikbuf[0..ikl], &iv);
    }
    const img = try tb.finish();
    try std.testing.expect(tb.data.entry_count == 0); // flushed at finish

    const foot = img[img.len - sst.footer_len ..];
    try std.testing.expectEqualStrings(sst.magic, foot[0..4]);
    try std.testing.expectEqual(sst.format_version, coding.getU16(foot[4..6]));
    const f = try sst.decodeFooter(foot, img.len);
    try std.testing.expect(f.index.offset < img.len - sst.footer_len);
    try std.testing.expect(f.index.size > 0);

    // several data blocks → several index entries → index block non-trivial
    try std.testing.expect(f.index.size > 32);

    try std.testing.expect(std.mem.indexOf(u8, img, "num_entries=50\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, img, "vlog_ids=\x01\x00") != null); // empty list mode
}

fn metadataWithFailures(allocator: std.mem.Allocator, builder: *const TableBuilder) !void {
    var borrowed = builder.*;
    borrowed.allocator = allocator;
    const meta = try borrowed.metadata(2, 17);
    defer meta.deinit(allocator);
    try std.testing.expectEqualStrings("first", meta.smallest);
    try std.testing.expectEqualStrings("last", meta.largest);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 9 }, meta.vlog_ids);
}

fn initWithFailures(allocator: std.mem.Allocator) !void {
    var tb = try TableBuilder.init(allocator, .{});
    defer tb.deinit();
}

test "table builder: init releases partial ownership and validates filter options" {
    const allocator = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(allocator, initWithFailures, .{});
    try std.testing.expectError(error.InvalidOptions, TableBuilder.init(allocator, .{ .bits_per_key = 0 }));
    try std.testing.expectError(error.InvalidOptions, TableBuilder.init(allocator, .{ .bits_per_key = 65 }));
}

test "table builder: metadata releases partial ownership on allocation failure" {
    const allocator = std.testing.allocator;
    var tb = try TableBuilder.init(allocator, .{});
    defer tb.deinit();
    var ikbuf: [32]u8 = undefined;
    var iv: [21]u8 = @splat(0);
    coding.putU64(iv[5..13], 9);
    for ([_][]const u8{ "first", "last" }) |user| {
        const n = try internal_key.encode(user, 7, .put, &ikbuf);
        try tb.add(ikbuf[0..n], &iv);
    }
    _ = try tb.finish();
    try std.testing.checkAllAllocationFailures(allocator, metadataWithFailures, .{&tb});
}

test "table builder: owned metadata preserves empty keys and late vlog range bounds" {
    const vids = @import("../util/vlog_ids.zig");
    const allocator = std.testing.allocator;
    for ([_]usize{ 0, 1, 64, 67 }) |count| {
        const meta = blk: {
            var tb = try TableBuilder.init(allocator, .{ .block_size = 128 });
            defer tb.deinit();
            var ikbuf: [32]u8 = undefined;
            var keybuf: [16]u8 = undefined;
            var iv: [21]u8 = @splat(0);
            for (0..count) |i| {
                const user = if (i == 0) "" else try std.fmt.bufPrint(&keybuf, "key{d:0>3}", .{i});
                const id: u64 = switch (i) {
                    65 => 1,
                    66 => 1000,
                    else => @intCast(100 + i),
                };
                coding.putU64(iv[5..13], id);
                const n = try internal_key.encode(user, @intCast(i + 1), .put, &ikbuf);
                try tb.add(ikbuf[0..n], &iv);
            }
            const img = try tb.finish();
            const result = try tb.metadata(3, 42);
            errdefer result.deinit(allocator);
            try std.testing.expectEqual(img.len, result.file_size);
            break :blk result;
        };
        defer meta.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 3), meta.level);
        try std.testing.expectEqual(@as(u64, 42), meta.file_id);
        try std.testing.expectEqualStrings("", meta.smallest);
        try std.testing.expectEqualStrings(if (count <= 1) "" else if (count == 64) "key063" else "key066", meta.largest);
        try std.testing.expectEqual(@as(u64, if (count == 0) 0 else 1), meta.min_seq);
        try std.testing.expectEqual(@as(u64, @intCast(count)), meta.max_seq);
        if (count <= 64) {
            const exact = (try vids.unpackExact(allocator, meta.vlog_ids)).?;
            defer allocator.free(exact);
            try std.testing.expectEqual(count, exact.len);
            for (exact, 0..) |id, i| try std.testing.expectEqual(@as(u64, @intCast(100 + i)), id);
        } else {
            try std.testing.expect((try vids.unpackExact(allocator, meta.vlog_ids)) == null);
            for ([_]u64{ 1, 100, 164, 1000 }) |id| {
                try std.testing.expectEqual(vids.Ref.referenced, vids.reference(meta.vlog_ids, id));
            }
            try std.testing.expectEqual(vids.Ref.absent, vids.reference(meta.vlog_ids, 0));
            try std.testing.expectEqual(vids.Ref.absent, vids.reference(meta.vlog_ids, 1001));
        }
    }
}
