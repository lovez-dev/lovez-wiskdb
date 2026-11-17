//! Open validates the footer, index and whole filter block, then caches the
//! filter header and checksums of its partitions.
//! Point lookups binary-search a decoded index, probe the data-block cache, and consult
//! a Bloom partition only on cache misses before fetching the data block.

const std = @import("std");
const disk = @import("../io/io.zig");
const Io = std.Io;
const sst = @import("format.zig");
const bloom = @import("bloom.zig");
const bi = @import("block_reader.zig");
const coding = @import("../util/coding.zig");
const crcmod = @import("../util/crc.zig");
const internal_key = @import("../util/internal_key.zig");
const flate = std.compress.flate;
const refcount = @import("../util/refcount.zig");
const block_cache = @import("../cache/block_cache.zig");
const tmod = @import("table_builder.zig");
const TableBuilder = tmod.TableBuilder;
const TbOptions = tmod.Options;

const FilterLoad = struct { bytes: []u8, header: bloom.FilterHeader, offset: u64 };
const PointIndexEntry = struct { key: []const u8, handle: sst.BlockHandle };

const BlockBytes = struct {
    /// Uncompressed block data without the trailer — what BlockReader.init takes.
    data: []u8,
    /// The allocation backing `data`; free this, not `data` (they differ for type=1).
    alloc: []u8,
};

pub const TableReader = struct {
    allocator: std.mem.Allocator,
    io: Io,
    file: disk.File,
    file_size: u64,
    /// Successful-read byte counter; tests assert a negative Bloom lookup
    /// touches only its own filter partition.
    bytes_read: std.atomic.Value(u64) = .init(0),
    bloom_negative: std.atomic.Value(u64) = .init(0),
    bloom_partition_reads: std.atomic.Value(u64) = .init(0),
    bloom_partition_bytes: std.atomic.Value(u64) = .init(0),
    data_block_reads: std.atomic.Value(u64) = .init(0),
    data_cache_hits: std.atomic.Value(u64) = .init(0),
    block_cache: ?*block_cache.BlockCache = null,
    block_file_id: u64 = 0,
    /// Shared decoded index. Keys are owned by point_index_keys; the
    /// compressed index is released after decoding. Storage is
    /// sizeof(PointIndexEntry) plus the full separator key per data block.
    point_index: []PointIndexEntry = &.{},
    point_index_keys: []u8 = &.{},
    filter_present: bool = false,
    filter_bytes: []u8 = &.{}, // header + offsets + trusted per-partition CRCs
    filter_offset: u64 = 0, // file offset of the filter block (extent preads)
    filter_header: bloom.FilterHeader = .{
        .probe = 0,
        .bits_per_key = 0,
        .num_filters = 0,
        .offsets = &.{},
        .data = &.{},
    },

    pub fn open(allocator: std.mem.Allocator, io: Io, dir: disk.Dir, name: []const u8) !TableReader {
        const file = try dir.openFile(io, name, .{ .mode = .read_only });
        const file_size = file.length(io) catch |e| {
            file.close(io);
            return e;
        };
        if (file_size < sst.footer_len) {
            file.close(io);
            return error.SSTableTooSmall;
        }
        // one cleanup owner per resource: build never closes `file`
        return build(allocator, io, file, file_size) catch |e| {
            file.close(io);
            return e;
        };
    }

    /// Cached block allocations can outlive this reader. allocator must stay
    /// valid until cache releases them and support concurrent cache frees.
    pub fn openWithCache(allocator: std.mem.Allocator, io: Io, dir: disk.Dir, name: []const u8, cache: *block_cache.BlockCache, file_id: u64) !TableReader {
        var result = try open(allocator, io, dir, name);
        result.block_cache = cache;
        result.block_file_id = file_id;
        return result;
    }

    /// Fallible assembly; every partial has an errdefer, and the infallible
    /// struct literal is the last statement, so success never runs a cleanup
    /// arm alongside the returned reader.
    fn build(allocator: std.mem.Allocator, io: Io, file: disk.File, file_size: u64) !TableReader {
        var count: u64 = 0;
        var fraw: [sst.footer_len]u8 = undefined;
        try disk.preadAll(file, io, &fraw, file_size - sst.footer_len);
        count += sst.footer_len;
        const footer = try sst.decodeFooter(&fraw, file_size);

        const rb = try readBlockBytes(allocator, file, io, &count, footer.index);
        defer allocator.free(rb.alloc);
        const index_block = try bi.BlockReader.init(rb.data);

        var iter = bi.BlockIter.init(allocator);
        defer iter.deinit();
        iter.resetTo(index_block);
        var idx_count: usize = 0;
        var key_bytes: usize = 0;
        if (try iter.first()) {
            while (true) {
                idx_count += 1;
                key_bytes = try std.math.add(usize, key_bytes, iter.key.len);
                if (!(try iter.advance())) break;
            }
        }
        const point_index = try allocator.alloc(PointIndexEntry, idx_count);
        errdefer allocator.free(point_index);
        const point_index_keys = try allocator.alloc(u8, key_bytes);
        errdefer allocator.free(point_index_keys);
        var point_i: usize = 0;
        var key_pos: usize = 0;
        iter.resetTo(index_block);
        if (try iter.first()) {
            while (true) {
                const key = point_index_keys[key_pos .. key_pos + iter.key.len];
                @memcpy(key, iter.key);
                point_index[point_i] = .{ .key = key, .handle = try sst.decodeHandle(iter.value) };
                point_i += 1;
                key_pos += iter.key.len;
                if (!(try iter.advance())) break;
            }
        }

        const mrb = try readBlockBytes(allocator, file, io, &count, footer.metaindex);
        defer allocator.free(mrb.alloc);
        const meta_block = try bi.BlockReader.init(mrb.data);
        var meta_iter = bi.BlockIter.init(allocator);
        defer meta_iter.deinit();
        meta_iter.resetTo(meta_block);
        var bloom_handle: ?sst.BlockHandle = null;
        if (try meta_iter.first()) {
            while (true) {
                if (std.mem.eql(u8, meta_iter.key, sst.metaindex_bloom_key)) {
                    bloom_handle = try sst.decodeHandle(meta_iter.value);
                    break;
                }
                if (!(try meta_iter.advance())) break;
            }
        }

        var fh: ?FilterLoad = null;
        errdefer if (fh) |f| allocator.free(f.bytes);
        if (bloom_handle) |h| {
            fh = try loadFilterHeader(allocator, io, file, h, &count);
            if (fh) |f| {
                if (f.header.num_filters != idx_count) return error.SSTableCorrupted; // partitions pair with data blocks
            }
        }
        // missing bloom key → fail open: every lookup reads its block

        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .file_size = file_size,
            .bytes_read = .init(count),
            .point_index = point_index,
            .point_index_keys = point_index_keys,
            .filter_present = fh != null,
            .filter_offset = if (fh) |f| f.offset else 0,
            .filter_bytes = if (fh) |f| f.bytes else &.{},
            .filter_header = if (fh) |f| f.header else .{
                .probe = 0,
                .bits_per_key = 0,
                .num_filters = 0,
                .offsets = &.{},
                .data = &.{},
            },
        };
    }

    /// Verify the existing whole-block CRC before trusting any negative Bloom
    /// result. Retain only the header and partition CRCs so later lookups can
    /// validate one extent without reading the whole filter again. This also
    /// protects existing SSTs without changing the on-disk format.
    fn loadFilterHeader(allocator: std.mem.Allocator, io: Io, file: disk.File, handle: sst.BlockHandle, count: *u64) error{ SSTableCorrupted, OutOfMemory }!?FilterLoad {
        const block = readBlockBytes(allocator, file, io, count, handle) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SSTableCorrupted,
        };
        defer allocator.free(block.alloc);
        if (block.data.len < bloom.header_base) return error.SSTableCorrupted;
        if (block.data[0] != bloom.filter_type_bloom) return null;
        const header = try bloom.decodeFilterBlock(block.data);
        const num = header.num_filters;
        const need = bloom.headerSize(num);
        const buf = try allocator.alloc(u8, need + @as(usize, num) * 4);
        errdefer allocator.free(buf);
        @memcpy(buf[0..need], block.data[0..need]);
        for (0..num) |i| {
            coding.putU32(buf[need + i * 4 ..][0..4], crcmod.crc32(header.filterBits(i)));
        }
        return .{ .bytes = buf, .header = try bloom.decodeFilterHeader(buf[0..need], handle.size), .offset = handle.offset };
    }

    /// Read one block (data + trailer); returns the full allocation — use
    /// `buf[0..handle.size]`, free the whole.
    fn readBlockBytes(
        allocator: std.mem.Allocator,
        file: disk.File,
        io: Io,
        count: *u64,
        handle: sst.BlockHandle,
    ) !BlockBytes {
        const buf = try allocator.alloc(u8, handle.size + sst.trailer_len);
        errdefer allocator.free(buf);
        disk.preadAll(file, io, buf, handle.offset) catch |e| switch (e) {
            error.UnexpectedEof => return error.BlockCorrupted,
            else => return e,
        };
        count.* += buf.len;
        const t = try sst.verifyTrailer(buf); // data ‖ trailer
        if (t == sst.block_type_none) return .{ .data = buf[0..handle.size], .alloc = buf };
        if (t != sst.block_type_deflate) return error.BlockCorrupted;
        // type=1: `u32 LE uncompressed_size ‖ deflate_stream`
        const stored = buf[0..handle.size];
        if (stored.len < 4) return error.BlockCorrupted;
        const unc_len: u32 = coding.getU32(stored[0..4]);
        if (unc_len > 16 << 20) return error.BlockCorrupted; // a corrupt prefix must not drive a giant alloc
        const unc = try allocator.alloc(u8, unc_len);
        errdefer allocator.free(unc);
        var r = std.Io.Reader.fixed(stored[4..]);
        var window: [flate.max_window_len]u8 = undefined; // std's direct-mode readVec rebase panics on an empty buffer
        var d = flate.Decompress.init(&r, .raw, &window);
        d.reader.readSliceAll(unc) catch return error.BlockCorrupted;
        if (r.seek != stored.len - 4) return error.BlockCorrupted; // trailing garbage
        allocator.free(buf);
        return .{ .data = unc, .alloc = unc };
    }

    /// Exact InternalKey point lookup: Index seek (entry ordinal → Bloom
    /// partition), Bloom short-circuit, then the data block. Returns the
    /// first entry ≥ `target` with the same user key — the engine builds
    /// `target` with the snapshot suffix, so visibility filtering *is* this
    /// seek. Caller owns the returned slice. Each extent is checked against
    /// the checksum captured from the verified filter block at open.
    pub fn get(self: *TableReader, target: []const u8) !?[]const u8 {
        const Copy = struct {
            fn value(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
                return allocator.dupe(u8, bytes);
            }
        };
        return self.getWith([]const u8, target, self.allocator, Copy.value);
    }

    /// First separator >= target; len marks a target beyond the table.
    inline fn findBlock(self: *const TableReader, target: []const u8) usize {
        var lo: usize = 0;
        var hi = self.point_index.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (internal_key.compare(self.point_index[mid].key, target) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Consume a borrowed InternalValue while its block remains pinned.
    /// The callback must not retain slices into bytes after it returns.
    /// Returned owned resources belong to the caller; errors release all pins.
    pub fn getWith(self: *TableReader, comptime Result: type, target: []const u8, context: anytype, comptime consume: anytype) !?Result {
        std.debug.assert(target.len >= internal_key.suffix_len);
        const user = target[0 .. target.len - internal_key.suffix_len];

        var count: u64 = 0;
        defer _ = self.bytes_read.fetchAdd(count, .monotonic);
        const block_i = self.findBlock(target);
        if (block_i == self.point_index.len) return null;
        const handle = self.point_index[block_i].handle;

        // A cached immutable data block can answer the lookup directly.
        // Bloom is useful only when it may avoid fetching that block.
        var cached: ?block_cache.Handle = null;
        var rb: ?BlockBytes = null;
        defer {
            if (cached) |*h| h.release();
            if (rb) |block| self.allocator.free(block.alloc);
        }
        if (self.block_cache) |cache| {
            cached = cache.acquire(.{ .file_id = self.block_file_id, .offset = handle.offset });
            if (cached != null) _ = self.data_cache_hits.fetchAdd(1, .monotonic);
        }

        if (cached == null and self.filter_present) {
            const num = self.filter_header.num_filters;
            if (block_i >= num) return error.SSTableCorrupted;
            const a = bloom.offsetAt(self.filter_header.offsets, block_i);
            const b = bloom.offsetAt(self.filter_header.offsets, block_i + 1);
            if (b > a) {
                const extent = try self.allocator.alloc(u8, b - a);
                defer self.allocator.free(extent);
                const extent_ok = read: {
                    disk.preadAll(self.file, self.io, extent, self.filter_offset + a) catch break :read false;
                    break :read true;
                };
                if (extent_ok) {
                    count += b - a;
                    _ = self.bloom_partition_reads.fetchAdd(1, .monotonic);
                    _ = self.bloom_partition_bytes.fetchAdd(b - a, .monotonic);
                    const checksum_at = bloom.headerSize(num) + block_i * 4;
                    if (crcmod.crc32(extent) != coding.getU32(self.filter_bytes[checksum_at..][0..4])) return error.SSTableCorrupted;
                    const f = bloom.Filter{ .bits = extent, .probe = self.filter_header.probe };
                    if (!f.mayContain(user)) {
                        _ = self.bloom_negative.fetchAdd(1, .monotonic);
                        return null; // negative: no block read
                    }
                }
                // short/failed extent fails open — fall through to the block
            }
            // empty partition fails open too
        }

        const block_bytes: []const u8 = if (cached) |h| h.bytes() else if (self.block_cache) |cache| blk: {
            rb = try readBlockBytes(self.allocator, self.file, self.io, &count, handle);
            _ = self.data_block_reads.fetchAdd(1, .monotonic);
            if (!cache.canStore(.{ .file_id = self.block_file_id, .offset = handle.offset }, rb.?.alloc.len)) {
                // A block larger than one shard would evict its hot entries
                // without fitting itself. Keep it only for this request.
                break :blk rb.?.data;
            }
            const owned = rb.?;
            rb = null; // insertOwned consumes the allocation even on error.
            cached = try cache.insertOwned(.{ .file_id = self.block_file_id, .offset = handle.offset }, .{
                .data = owned.data,
                .allocation = owned.alloc,
                .allocator = self.allocator,
            });
            break :blk cached.?.bytes();
        } else blk: {
            rb = try readBlockBytes(self.allocator, self.file, self.io, &count, handle);
            _ = self.data_block_reads.fetchAdd(1, .monotonic);
            break :blk rb.?.data;
        };
        const blk = try bi.BlockReader.init(block_bytes);
        var it = bi.BlockIter.init(self.allocator);
        defer it.deinit();
        it.resetTo(blk);
        try it.seek(target);
        if (it.key.len == 0 or internal_key.compare(it.key, target) == .lt) return null;
        if (!std.mem.eql(u8, it.key[0 .. it.key.len - internal_key.suffix_len], user)) return null;
        return try consume(context, it.value);
    }

    /// Bidirectional whole-table walk: one decompressed data block in
    /// memory at a time, so merge memory stays at block scale however
    /// large the table is. Keeps its own index cursor; reads contribute to
    /// the shared TableReader byte counter. key/value stay valid only until
    /// repositioning or deinit, and the table must outlive the iterator.
    pub const TableIter = struct {
        table: *TableReader,
        index_pos: usize = 0,
        block: BlockBytes = .{ .data = &.{}, .alloc = &.{} },
        cached: ?block_cache.Handle = null,
        use_cache: bool = false,
        iter: bi.BlockIter,
        done: bool = true,
        index_valid: bool = false,

        pub fn init(t: *TableReader) TableIter {
            return .{ .table = t, .iter = bi.BlockIter.init(t.allocator) };
        }

        /// Limited user scans reuse point-read blocks. Bulk maintenance keeps
        /// init's uncached policy so sequential reads do not displace hot data.
        pub fn initCached(t: *TableReader) TableIter {
            var result = init(t);
            result.use_cache = true;
            return result;
        }

        pub fn deinit(self: *TableIter) void {
            self.freeBlock();
            self.iter.deinit();
        }

        pub fn seekToFirst(self: *TableIter) !void {
            self.index_pos = 0;
            self.index_valid = self.table.point_index.len != 0;
            self.done = false;
            try self.loadBlock(false);
        }

        pub fn seekToLast(self: *TableIter) !void {
            self.index_valid = self.table.point_index.len != 0;
            self.index_pos = if (self.index_valid) self.table.point_index.len - 1 else 0;
            self.done = false;
            try self.loadBlock(true);
        }

        /// First internal key >= target; an exhausted seek is invalid.
        /// target must stay valid throughout this call and must not reference
        /// this iterator's current key/value, which loadBlock may release.
        pub fn seek(self: *TableIter, target: []const u8) !void {
            self.index_pos = self.table.findBlock(target);
            self.index_valid = self.index_pos < self.table.point_index.len;
            self.done = false;
            try self.loadBlock(false);
            if (self.done) return;
            try self.iter.seek(target);
            if (internal_key.compare(self.iter.key, target) == .lt) try self.next();
        }

        /// Last internal key < target, including when target is beyond the table.
        pub fn seekBefore(self: *TableIter, target: []const u8) !void {
            try self.seek(target);
            if (self.done) return self.seekToLast();
            try self.prev();
        }

        pub fn prev(self: *TableIter) !void {
            if (self.done) return;
            if (try self.iter.prev()) return;
            self.moveIndex(true);
            try self.loadBlock(true);
        }

        pub fn next(self: *TableIter) !void {
            if (self.done) return;
            if (try self.iter.advance()) return;
            self.moveIndex(false);
            try self.loadBlock(false);
        }

        pub fn valid(self: *const TableIter) bool {
            return !self.done;
        }

        pub fn key(self: *const TableIter) []const u8 {
            return self.iter.key;
        }

        pub fn value(self: *const TableIter) []const u8 {
            return self.iter.value;
        }

        fn moveIndex(self: *TableIter, reverse: bool) void {
            if (reverse) {
                if (self.index_pos == 0) {
                    self.index_valid = false;
                } else self.index_pos -= 1;
            } else {
                self.index_pos += 1;
                self.index_valid = self.index_pos < self.table.point_index.len;
            }
        }

        fn freeBlock(self: *TableIter) void {
            if (self.cached) |*cached| cached.release();
            self.cached = null;
            if (self.block.alloc.len != 0) self.table.allocator.free(self.block.alloc);
            self.block = .{ .data = &.{}, .alloc = &.{} };
        }

        fn loadBlock(self: *TableIter, reverse: bool) !void {
            errdefer {
                self.done = true;
                self.iter.key = &.{};
                self.iter.value = &.{};
                self.iter.current = null;
                self.iter.at_end = true;
                self.freeBlock();
            }
            while (self.index_valid) {
                const handle = self.table.point_index[self.index_pos].handle;
                self.freeBlock();
                var bytes_read: u64 = 0;
                defer {
                    _ = self.table.bytes_read.fetchAdd(bytes_read, .monotonic);
                }
                const cache = if (self.use_cache) self.table.block_cache else null;
                const cache_key = block_cache.Key{ .file_id = self.table.block_file_id, .offset = handle.offset };
                if (cache) |c| self.cached = c.acquire(cache_key);
                if (self.cached != null) {
                    _ = self.table.data_cache_hits.fetchAdd(1, .monotonic);
                } else {
                    self.block = try readBlockBytes(self.table.allocator, self.table.file, self.table.io, &bytes_read, handle);
                    _ = self.table.data_block_reads.fetchAdd(1, .monotonic);
                    if (cache) |c| {
                        if (c.canStore(cache_key, self.block.alloc.len)) {
                            const owned = self.block;
                            self.block = .{ .data = &.{}, .alloc = &.{} };
                            self.cached = try c.insertOwned(cache_key, .{
                                .data = owned.data,
                                .allocation = owned.alloc,
                                .allocator = self.table.allocator,
                            });
                        }
                    }
                }
                // Either the cache handle or self.block retains these bytes
                // until freeBlock; current key/value slices depend on them.
                const bytes = if (self.cached) |cached| cached.bytes() else self.block.data;
                const blk = try bi.BlockReader.init(bytes);
                self.iter.resetTo(blk);
                if (if (reverse) try self.iter.last() else try self.iter.first()) return;
                self.moveIndex(reverse); // empty data block: roll on
            }
            self.done = true;
        }
    };

    pub fn deinit(self: *TableReader) void {
        if (self.point_index.len != 0) self.allocator.free(self.point_index);
        if (self.point_index_keys.len != 0) self.allocator.free(self.point_index_keys);
        if (self.filter_bytes.len != 0) self.allocator.free(self.filter_bytes);
        self.file.close(self.io);
    }
};

/// The last reference closes the table and releases its buffers.
pub const RcTable = refcount.RefCounted(TableReader, destroy);

fn destroy(t: *TableReader) void {
    const alloc = t.allocator;
    const holder: *RcTable = @fieldParentPtr("data", t);
    t.deinit();
    alloc.destroy(holder);
}

/// `n`-key fixture image (256 B blocks force several data blocks);
/// caller frees — the builder owns its own buffer.
fn buildFixtureImage(alloc: std.mem.Allocator, n: usize, opts: TbOptions) ![]u8 {
    var tb = try TableBuilder.init(alloc, opts);
    defer tb.deinit();
    var kbuf: [32]u8 = undefined;
    var ikbuf: [48]u8 = undefined;
    const iv: [21]u8 = @splat(0);
    for (0..n) |i| {
        const user = try std.fmt.bufPrint(&kbuf, "key{d:0>4}", .{i});
        const ikl = try internal_key.encode(user, @as(u64, i) + 1, .put, &ikbuf);
        try tb.add(ikbuf[0..ikl], &iv);
    }
    const img = try tb.finish();
    return try alloc.dupe(u8, img);
}

fn writeTestTable(alloc: std.mem.Allocator, io: std.Io, dir: disk.Dir, name: []const u8, n: usize) !void {
    const img = try buildFixtureImage(alloc, n, .{ .block_size = 256 });
    defer alloc.free(img);
    var f = try dir.createFile(io, name, .{ .truncate = true });
    defer f.close(io);
    try disk.pwriteAll(f, io, img, 0);
}

/// Inflate a type=1 stored block (`u32 LE size ‖ stream`); test-side
/// mirror of the reader path.
fn inflateBlock(alloc: std.mem.Allocator, stored: []const u8) ![]u8 {
    if (stored.len < 4) return error.BlockCorrupted;
    const unc_len: u32 = coding.getU32(stored[0..4]);
    const unc = try alloc.alloc(u8, unc_len);
    errdefer alloc.free(unc);
    var r = std.Io.Reader.fixed(stored[4..]);
    var window: [flate.max_window_len]u8 = undefined;
    var d = flate.Decompress.init(&r, .raw, &window);
    d.reader.readSliceAll(unc) catch return error.BlockCorrupted;
    if (r.seek != stored.len - 4) return error.BlockCorrupted;
    return unc;
}

fn walkCachedTable(allocator: std.mem.Allocator, dir: disk.Dir, check_invalidation: bool) !void {
    const io = std.testing.io;
    var cache = block_cache.BlockCache.init(allocator, io, 1024 * 1024);
    defer cache.deinit();
    var table = try TableReader.openWithCache(std.testing.allocator, io, dir, "cache-iter.sst", &cache, 71);
    defer table.deinit();
    {
        var it = TableReader.TableIter.initCached(&table);
        defer it.deinit();
        try it.seekToFirst();
        var count: usize = 0;
        while (it.valid()) : (try it.next()) count += 1;
        try std.testing.expectEqual(@as(usize, 150), count);
        const read = table.data_block_reads.load(.monotonic);
        try std.testing.expect(read > 1);
        try it.seekToLast();
        count = 0;
        while (it.valid()) : (try it.prev()) count += 1;
        try std.testing.expectEqual(@as(usize, 150), count);
        try std.testing.expectEqual(read, table.data_block_reads.load(.monotonic));
        try std.testing.expect(cache.stats().hits >= read);
        // The current block stays pinned across invalidation. Deinitializing
        // the iterator must release it, allowing final invalidation below.
        if (check_invalidation) {
            try it.seekToFirst();
            cache.invalidateFile(71);
            try std.testing.expect(cache.stats().bytes > 0);
            try std.testing.expect(it.valid());
            try std.testing.expect(it.key().len > internal_key.suffix_len);
        }
    }
    if (!check_invalidation) return;
    cache.invalidateFile(71);
    try std.testing.expectEqual(@as(usize, 0), cache.stats().bytes);
    const before = table.data_block_reads.load(.monotonic);
    var bulk = TableReader.TableIter.init(&table);
    defer bulk.deinit();
    try bulk.seekToFirst();
    try std.testing.expectEqual(before + 1, table.data_block_reads.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), cache.stats().bytes);
}

test "table reader: cached iterators reuse blocks and release pins across failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestTable(std.testing.allocator, std.testing.io, tmp.dir, "cache-iter.sst", 150);
    try walkCachedTable(std.testing.allocator, tmp.dir, true);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, walkCachedTable, .{ tmp.dir, false });
}

fn openIndexWithFailures(allocator: std.mem.Allocator, dir: disk.Dir) !void {
    var table = try TableReader.open(allocator, std.testing.io, dir, "index.sst");
    defer table.deinit();
    try std.testing.expect(table.point_index.len > 16);
}

test "table reader: decoded index frees every failed open allocation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestTable(std.testing.allocator, std.testing.io, tmp.dir, "index.sst", 150);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, openIndexWithFailures, .{tmp.dir});
}

test "table reader: decoded index preserves long-key snapshot boundaries across blocks" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var builder = try TableBuilder.init(alloc, .{ .block_size = 256 });
    defer builder.deinit();
    const user: [300]u8 = @splat('k');
    var key: [user.len + internal_key.suffix_len]u8 = undefined;
    var iv: [22]u8 = @splat(0);
    iv[0] = 0b010;
    coding.putU32(iv[1..5], 1);
    for (0..40) |i| {
        const seq = 40 - i;
        _ = try internal_key.encode(&user, seq, .put, &key);
        iv[21] = @intCast(seq);
        try builder.add(&key, &iv);
    }
    const image = try builder.finish();
    const file = try tmp.dir.createFile(io, "versions.sst", .{});
    defer file.close(io);
    try disk.pwriteAll(file, io, image, 0);
    var table = try TableReader.open(alloc, io, tmp.dir, "versions.sst");
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 40), table.point_index.len);
    for (0..42) |seq| {
        _ = try internal_key.encode(&user, seq, .put, &key);
        const got = try table.get(&key);
        defer if (got) |bytes| alloc.free(bytes);
        if (seq == 0) {
            try std.testing.expect(got == null);
        } else {
            try std.testing.expectEqual(@as(u8, @intCast(@min(seq, 40))), got.?[21]);
        }
    }
    // One version per block exercises decoded-index seeks across equal user
    // keys; direction changes must preserve the internal sequence ordering.
    var versions = TableReader.TableIter.init(&table);
    defer versions.deinit();
    for (1..40) |seq| {
        _ = try internal_key.encode(&user, seq, .put, &key);
        try versions.seek(&key);
        try std.testing.expect(versions.valid());
        try std.testing.expectEqual(@as(u64, seq), (try internal_key.decode(versions.key())).seq);
        try versions.prev();
        try std.testing.expectEqual(@as(u64, seq + 1), (try internal_key.decode(versions.key())).seq);
        try versions.next();
        try std.testing.expectEqual(@as(u64, seq), (try internal_key.decode(versions.key())).seq);
        try versions.seekBefore(&key);
        try std.testing.expectEqual(@as(u64, seq + 1), (try internal_key.decode(versions.key())).seq);
    }
    // Queries outside either user-key boundary must not select a false hit.
    for ([_]u8{ 'j', 'l' }) |byte| {
        const missing: [300]u8 = @splat(byte);
        _ = try internal_key.encode(&missing, 41, .put, &key);
        try std.testing.expect((try table.get(&key)) == null);
    }
    try writeTestTable(alloc, io, tmp.dir, "empty-index.sst", 0);
    var empty = try TableReader.open(alloc, io, tmp.dir, "empty-index.sst");
    defer empty.deinit();
    try std.testing.expect((try empty.get(&key)) == null);
}

test "table reader: TableIter reverse crosses blocks and seeks boundaries" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestTable(alloc, io, tmp.dir, "reverse.sst", 150);
    var tr = try TableReader.open(alloc, io, tmp.dir, "reverse.sst");
    defer tr.deinit();
    try std.testing.expect(tr.point_index.len > 16);
    var it = TableReader.TableIter.init(&tr);
    defer it.deinit();
    try it.seekToLast();
    var i: usize = 150;
    while (it.valid()) {
        i -= 1;
        var user_buf: [32]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "key{d:0>4}", .{i});
        try std.testing.expectEqualStrings(user, (try internal_key.decode(it.key())).user);
        try it.prev();
    }
    try std.testing.expectEqual(@as(usize, 0), i);
    try it.prev();
    var key: [48]u8 = undefined;
    for ([_][]const u8{ "a", "key0000", "key0016", "key0149", "z" }) |user| {
        const n = try internal_key.encode(user, std.math.maxInt(u64), .put, &key);
        try it.seekBefore(key[0..n]);
        if (std.mem.eql(u8, user, "a") or std.mem.eql(u8, user, "key0000")) {
            try std.testing.expect(!it.valid());
        } else {
            try std.testing.expect(it.valid());
            try std.testing.expect(std.mem.order(u8, (try internal_key.decode(it.key())).user, user) == .lt);
            try it.next();
            if (!std.mem.eql(u8, user, "z")) try std.testing.expectEqualStrings(user, (try internal_key.decode(it.key())).user);
        }
    }
    try writeTestTable(alloc, io, tmp.dir, "empty.sst", 0);
    var empty = try TableReader.open(alloc, io, tmp.dir, "empty.sst");
    defer empty.deinit();
    var empty_it = TableReader.TableIter.init(&empty);
    defer empty_it.deinit();
    try empty_it.seekToLast();
    try std.testing.expect(!empty_it.valid());
}

test "table reader: TableIter walks every entry in order" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestTable(alloc, io, tmp.dir, "walk.sst", 50);

    var tr = try TableReader.open(alloc, io, tmp.dir, "walk.sst");
    defer tr.deinit();
    try std.testing.expect(tr.point_index.len >= 2); // several blocks → the roll path runs

    var it = TableReader.TableIter.init(&tr);
    defer it.deinit();
    try it.seekToFirst();
    var i: usize = 0;
    var kbuf: [32]u8 = undefined;
    var ikbuf: [48]u8 = undefined;
    while (it.valid()) : (i += 1) {
        const user = try std.fmt.bufPrint(&kbuf, "key{d:0>4}", .{i});
        const ikl = try internal_key.encode(user, @as(u64, i) + 1, .put, &ikbuf);
        try std.testing.expectEqualSlices(u8, ikbuf[0..ikl], it.key());
        try std.testing.expectEqual(@as(usize, 21), it.value().len);
        try it.next();
    }
    try std.testing.expectEqual(@as(usize, 50), i);
    try it.seekToFirst(); // reusable after hitting the end
    try std.testing.expect(it.valid());
}

test "table reader: write/read symmetry, hits and misses" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestTable(alloc, io, tmp.dir, "sym.sst", 50);

    var tr = try TableReader.open(alloc, io, tmp.dir, "sym.sst");
    defer tr.deinit();
    try std.testing.expect(tr.point_index.len >= 2); // 256 B blocks split 50 entries
    try std.testing.expect(tr.filter_present);

    var kbuf: [32]u8 = undefined;
    var ikbuf: [48]u8 = undefined;
    for (0..50) |i| {
        const user = try std.fmt.bufPrint(&kbuf, "key{d:0>4}", .{i});
        const ikl = try internal_key.encode(user, @as(u64, i) + 1, .put, &ikbuf);
        const got = try tr.get(ikbuf[0..ikl]);
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(usize, 21), got.?.len);
        alloc.free(got.?); // get hands the caller a fresh slice
    }
    const miss = try internal_key.encode("no-such-key", 1, .put, &ikbuf);
    try std.testing.expect((try tr.get(ikbuf[0..miss])) == null);
}

test "table reader: concurrent lookups share only immutable state" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestTable(alloc, io, tmp.dir, "parallel.sst", 50);
    var tr = try TableReader.open(alloc, io, tmp.dir, "parallel.sst");
    defer tr.deinit();
    const Lookup = struct {
        fn run(t: *TableReader, start: usize) void {
            for (0..100) |j| {
                const i = (start + j) % 50;
                var key: [32]u8 = undefined;
                var target: [48]u8 = undefined;
                const user = std.fmt.bufPrint(&key, "key{d:0>4}", .{i}) catch unreachable;
                const n = internal_key.encode(user, i + 1, .put, &target) catch unreachable;
                const got = (t.get(target[0..n]) catch @panic("lookup failed")) orelse @panic("missing key");
                defer t.allocator.free(got);
                std.testing.expectEqual(@as(usize, 21), got.len) catch @panic("invalid value");
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Lookup.run, .{ &tr, 0 });
    defer thread.join();
    Lookup.run(&tr, 25);
}

test "table reader: a negative lookup reads only its filter partition" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestTable(alloc, io, tmp.dir, "neg.sst", 500);

    var tr = try TableReader.open(alloc, io, tmp.dir, "neg.sst");
    defer tr.deinit();
    try std.testing.expect(tr.filter_present);

    const before = tr.bytes_read.load(.monotonic);
    var ikbuf: [48]u8 = undefined;
    const miss = try internal_key.encode("definitely-absent", 1, .put, &ikbuf);
    try std.testing.expect((try tr.get(ikbuf[0..miss])) == null);
    const delta = tr.bytes_read.load(.monotonic) - before;
    try std.testing.expect(delta > 0); // the partition really was read
    // one partition ≈ 7 keys × 10 bpk / 8 ≈ 9 B; a data block (≥256 B) or
    // the whole filter block would blow far past this ceiling
    try std.testing.expect(delta <= 64);
}

test "table reader: Bloom bit corruption cannot hide an intact data block" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestTable(alloc, io, tmp.dir, "bitflip.sst", 3);
    var reader = try TableReader.open(alloc, io, tmp.dir, "bitflip.sst");
    defer reader.deinit();
    const a = bloom.offsetAt(reader.filter_header.offsets, 0);
    const b = bloom.offsetAt(reader.filter_header.offsets, 1);
    const bit = bloom.bitIndex(bloom.hashUserKey("key0001"), 0, (b - a) * 8);
    const file = try tmp.dir.openFile(io, "bitflip.sst", .{ .mode = .read_write });
    defer file.close(io);
    const offset = reader.filter_offset + a + bit / 8;
    var byte: [1]u8 = undefined;
    try disk.preadAll(file, io, &byte, offset);
    byte[0] ^= @as(u8, 1) << @intCast(bit & 7);
    try disk.pwriteAll(file, io, &byte, offset);

    var target: [48]u8 = undefined;
    const len = try internal_key.encode("key0001", 2, .put, &target);
    // Damage after open is detected by the retained partition checksum.
    try std.testing.expectError(error.SSTableCorrupted, reader.get(target[0..len]));
    // Damage before open is detected by the existing on-disk block checksum.
    try std.testing.expectError(error.SSTableCorrupted, TableReader.open(alloc, io, tmp.dir, "bitflip.sst"));
    var iter = TableReader.TableIter.init(&reader);
    defer iter.deinit();
    try iter.seek(target[0..len]);
    try std.testing.expect(iter.valid());
    try std.testing.expectEqualSlices(u8, target[0..len], iter.key());
    try std.testing.expectEqual(@as(usize, 21), iter.value().len);
}

test "table reader: cached blocks skip Bloom I/O and still verify exact keys and snapshots" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestTable(alloc, io, tmp.dir, "cached.sst", 3);
    var cache = block_cache.BlockCache.init(alloc, io, 64 * 1024);
    defer cache.deinit();
    var tr = try TableReader.openWithCache(alloc, io, tmp.dir, "cached.sst", &cache, 7);
    defer tr.deinit();
    try std.testing.expectEqual(@as(usize, 1), tr.point_index.len);
    var target: [48]u8 = undefined;
    const len = try internal_key.encode("key0001", 2, .put, &target);
    const first = (try tr.get(target[0..len])).?;
    alloc.free(first);
    const bytes_before = tr.bytes_read.load(.monotonic);
    try std.testing.expectEqual(@as(u64, 1), tr.bloom_partition_reads.load(.monotonic));
    const second = (try tr.get(target[0..len])).?;
    alloc.free(second);
    const missing_len = try internal_key.encode("key0001!", 100, .put, &target);
    try std.testing.expect((try tr.get(target[0..missing_len])) == null);
    const old_len = try internal_key.encode("key0001", 1, .put, &target);
    try std.testing.expect((try tr.get(target[0..old_len])) == null);
    try std.testing.expectEqual(bytes_before, tr.bytes_read.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), tr.bloom_partition_reads.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 3), tr.data_cache_hits.load(.monotonic));
    // A failed Bloom partition read must still fall through to the data block.
    cache.invalidateFile(7);
    tr.filter_offset = tr.file_size + 1024;
    const valid_len = try internal_key.encode("key0001", 2, .put, &target);
    const fallback = (try tr.get(target[0..valid_len])).?;
    defer alloc.free(fallback);
    try std.testing.expectEqual(@as(usize, 21), fallback.len);
    try std.testing.expectEqual(@as(u64, 2), tr.data_block_reads.load(.monotonic));
}

test "table reader: oversized blocks bypass point and iterator caches without evicting hot blocks" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestTable(alloc, io, tmp.dir, "hot.sst", 1);
    var builder = try TableBuilder.init(alloc, .{ .block_size = 16 * 1024 });
    defer builder.deinit();
    const large_user: [2048]u8 = @splat('l');
    var large_key: [2048 + internal_key.suffix_len]u8 = undefined;
    const large_key_len = try internal_key.encode(&large_user, 1, .put, &large_key);
    const iv: [21]u8 = @splat(0);
    try builder.add(large_key[0..large_key_len], &iv);
    const image = try builder.finish();
    {
        const large_file = try tmp.dir.createFile(io, "large.sst", .{});
        defer large_file.close(io);
        try disk.pwriteAll(large_file, io, image, 0);
    }

    var cache = block_cache.BlockCache.init(alloc, io, 1024);
    defer cache.deinit();
    var hot = try TableReader.openWithCache(alloc, io, tmp.dir, "hot.sst", &cache, 101);
    defer hot.deinit();
    var large = try TableReader.openWithCache(alloc, io, tmp.dir, "large.sst", &cache, 102);
    defer large.deinit();

    var hot_key: [48]u8 = undefined;
    const hot_key_len = try internal_key.encode("key0000", 1, .put, &hot_key);
    const hot_value = try hot.get(hot_key[0..hot_key_len]);
    try std.testing.expect(hot_value != null);
    alloc.free(hot_value.?);
    try std.testing.expect(cache.stats().bytes > 0);
    const hot_bytes = cache.stats().bytes;
    const large_value = try large.get(&large_key);
    try std.testing.expect(large_value != null);
    alloc.free(large_value.?);
    try std.testing.expectEqual(hot_bytes, cache.stats().bytes);
    {
        var it = TableReader.TableIter.initCached(&large);
        defer it.deinit();
        try it.seekToFirst();
        try std.testing.expect(it.valid());
        try std.testing.expectEqualSlices(u8, &large_key, it.key());
        try std.testing.expectEqual(hot_bytes, cache.stats().bytes);
        try it.seekToLast();
        try std.testing.expect(it.valid());
        try std.testing.expectEqualSlices(u8, &large_key, it.key());
        try std.testing.expectEqual(hot_bytes, cache.stats().bytes);
    }
    const hits = cache.stats().hits;
    const hot_again = try hot.get(hot_key[0..hot_key_len]);
    try std.testing.expect(hot_again != null);
    alloc.free(hot_again.?);
    try std.testing.expect(cache.stats().hits > hits);

    // Admission uses each shard's allocation budget, not total capacity.
    for ([_]usize{ 0, 4096 }) |budget| {
        var small_cache = block_cache.BlockCache.initSharded(alloc, io, budget, 4);
        defer small_cache.deinit();
        large.block_cache = &small_cache;
        defer large.block_cache = &cache;
        const value = try large.get(&large_key);
        try std.testing.expect(value != null);
        alloc.free(value.?);
        var it = TableReader.TableIter.initCached(&large);
        defer it.deinit();
        try it.seekToFirst();
        try std.testing.expect(it.valid());
        try std.testing.expectEqualSlices(u8, &large_key, it.key());
        try std.testing.expectEqual(@as(usize, 0), small_cache.stats().bytes);
    }
}

test "table reader: failed block transitions invalidate iterator slices and release storage" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestTable(alloc, io, tmp.dir, "failed-transition.sst", 50);
    var table = try TableReader.open(alloc, io, tmp.dir, "failed-transition.sst");
    defer table.deinit();
    var it = TableReader.TableIter.init(&table);
    defer it.deinit();
    try it.seekToFirst();
    try std.testing.expect(it.valid());
    try std.testing.expect(table.point_index.len > 1);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    table.allocator = failing.allocator();
    defer table.allocator = alloc;
    while (it.valid()) {
        it.next() catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(!it.valid());
            try std.testing.expectEqual(@as(usize, 0), it.key().len);
            try std.testing.expectEqual(@as(usize, 0), it.value().len);
            try std.testing.expectEqual(@as(usize, 0), it.block.alloc.len);
            try std.testing.expect(it.cached == null);
            return;
        };
    }
    return error.TestExpectedAllocationFailure;
}

test "table reader: borrowed value callback pins blocks and releases them on errors" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestTable(alloc, io, tmp.dir, "borrow.sst", 3);
    const Consume = struct {
        cache: ?*block_cache.BlockCache,
        fail: bool,
        fn value(ctx: @This(), bytes: []const u8) !usize {
            if (ctx.cache) |cache| {
                cache.invalidateFile(7);
                try std.testing.expect(cache.stats().bytes > 0);
            }
            try std.testing.expectEqual(@as(usize, 21), bytes.len);
            for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
            if (ctx.fail) return error.CallbackFailed;
            return bytes.len;
        }
    };
    for ([_]bool{ false, true }) |use_cache| {
        var cache = block_cache.BlockCache.init(alloc, io, 64 * 1024);
        defer cache.deinit();
        var tr = try TableReader.open(alloc, io, tmp.dir, "borrow.sst");
        defer tr.deinit();
        if (use_cache) {
            tr.block_cache = &cache;
            tr.block_file_id = 7;
        }
        var target: [48]u8 = undefined;
        const len = try internal_key.encode("key0001", 2, .put, &target);
        const ctx = Consume{ .cache = if (use_cache) &cache else null, .fail = false };
        try std.testing.expectEqual(@as(usize, 21), (try tr.getWith(usize, target[0..len], ctx, Consume.value)).?);
        const failing = Consume{ .cache = ctx.cache, .fail = true };
        try std.testing.expectError(error.CallbackFailed, tr.getWith(usize, target[0..len], failing, Consume.value));
        if (use_cache) {
            // A warm short-key lookup with a scalar consumer needs no
            // temporary allocations from the reader, including key rebuilds.
            var no_alloc = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
            tr.allocator = no_alloc.allocator();
            defer tr.allocator = alloc;
            const scalar = Consume{ .cache = null, .fail = false };
            try std.testing.expectEqual(@as(usize, 21), (try tr.getWith(usize, target[0..len], scalar, Consume.value)).?);
        }
        cache.invalidateFile(7);
        try std.testing.expectEqual(@as(usize, 0), cache.stats().bytes);
        const missing_len = try internal_key.encode("key0001!", 100, .put, &target);
        try std.testing.expect((try tr.getWith(usize, target[0..missing_len], failing, Consume.value)) == null);
    }
}

test "table reader: cache misses still use Bloom to avoid data block reads" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestTable(alloc, io, tmp.dir, "negative-cache.sst", 500);
    var cache = block_cache.BlockCache.init(alloc, io, 64 * 1024);
    defer cache.deinit();
    var tr = try TableReader.openWithCache(alloc, io, tmp.dir, "negative-cache.sst", &cache, 9);
    defer tr.deinit();
    var target: [48]u8 = undefined;
    const len = try internal_key.encode("definitely-absent", 1, .put, &target);
    for (0..2) |_| try std.testing.expect((try tr.get(target[0..len])) == null);
    try std.testing.expectEqual(@as(u64, 2), tr.bloom_partition_reads.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), tr.bloom_negative.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), tr.data_block_reads.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), cache.stats().misses);
    try std.testing.expectEqual(@as(usize, 0), cache.stats().bytes);
}

test "table reader: filter partitions must pair with Index entries" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const img = try buildFixtureImage(alloc, 50, .{ .block_size = 256 });
    defer alloc.free(img);

    // tamper: one fewer partition — offsets still form a valid prefix
    const f = try sst.decodeFooter(img[img.len - sst.footer_len ..], img.len);
    const mblk = try bi.BlockReader.init(img[f.metaindex.offset .. f.metaindex.offset + f.metaindex.size]);
    var mit = bi.BlockIter.init(alloc);
    defer mit.deinit();
    mit.resetTo(mblk);
    var h: sst.BlockHandle = undefined;
    var found = false;
    if (try mit.first()) while (true) {
        if (std.mem.eql(u8, mit.key, sst.metaindex_bloom_key)) {
            h = try sst.decodeHandle(mit.value);
            found = true;
            break;
        }
        if (!(try mit.advance())) break;
    };
    try std.testing.expect(found);
    const mut: []u8 = @constCast(img);
    var word: [4]u8 = undefined;
    @memcpy(&word, mut[h.offset + 6 ..][0..4]); // num_filters, LE
    coding.putU32(&word, coding.getU32(&word) - 1);
    @memcpy(mut[h.offset + 6 ..][0..4], &word);

    var wf = try tmp.dir.createFile(io, "num.sst", .{ .truncate = true });
    defer wf.close(io);
    try disk.pwriteAll(wf, io, img, 0);
    try std.testing.expectError(error.SSTableCorrupted, TableReader.open(alloc, io, tmp.dir, "num.sst"));
}

test "table reader: a missing filter fails open and lookups still work" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const img = try buildFixtureImage(alloc, 50, .{ .block_size = 256 });
    defer alloc.free(img);
    const mut: []u8 = @constCast(img);
    const f = try sst.decodeFooter(img[img.len - sst.footer_len ..], img.len);
    const key_off = std.mem.indexOf(u8, img, sst.metaindex_bloom_key).?;
    mut[key_off] ^= 0xFF; // the MetaIndex no longer advertises a filter
    // the flip broke the block CRC — re-stamp it so the reader sees a
    // valid block that simply carries a different key
    var crc = std.hash.Crc32.init();
    crc.update(mut[f.metaindex.offset .. f.metaindex.offset + f.metaindex.size]);
    crc.update(&.{mut[f.metaindex.offset + f.metaindex.size]}); // type byte
    std.mem.writeInt(u32, mut[f.metaindex.offset + f.metaindex.size + 1 ..][0..4], crc.final(), .little);

    var wf = try tmp.dir.createFile(io, "nofilter.sst", .{ .truncate = true });
    defer wf.close(io);
    try disk.pwriteAll(wf, io, img, 0);

    var tr = try TableReader.open(alloc, io, tmp.dir, "nofilter.sst");
    defer tr.deinit();
    try std.testing.expect(!tr.filter_present); // fail open, not corrupt

    var ikbuf: [48]u8 = undefined;
    const ikl = try internal_key.encode("key0007", 8, .put, &ikbuf);
    const got = try tr.get(ikbuf[0..ikl]);
    try std.testing.expect(got != null); // straight to the data block
    alloc.free(got.?);
}

test "table reader: deflate blocks round-trip through the read path" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const img = try buildFixtureImage(alloc, 50, .{ .block_size = 256, .compression = .deflate });
    defer alloc.free(img);
    var wf = try tmp.dir.createFile(io, "deflate.sst", .{ .truncate = true });
    defer wf.close(io);
    try disk.pwriteAll(wf, io, img, 0);

    // data block 0 = shared keys + zero values — it must have chosen the
    // compressed form (type byte sits between data and CRC)
    const f = try sst.decodeFooter(img[img.len - sst.footer_len ..], img.len);
    var idx_unc: ?[]u8 = null;
    defer if (idx_unc) |b| alloc.free(b);
    const idx_data = if (img[f.index.offset + f.index.size] == sst.block_type_deflate) blk: {
        const unc = try inflateBlock(alloc, img[f.index.offset .. f.index.offset + f.index.size]);
        idx_unc = unc;
        break :blk unc;
    } else img[f.index.offset .. f.index.offset + f.index.size];
    const idx = try bi.BlockReader.init(idx_data);
    var it = bi.BlockIter.init(alloc);
    defer it.deinit();
    it.resetTo(idx);
    try std.testing.expect(try it.first());
    const h0 = try sst.decodeHandle(it.value);
    try std.testing.expectEqual(sst.block_type_deflate, img[h0.offset + h0.size]);

    var tr = try TableReader.open(alloc, io, tmp.dir, "deflate.sst");
    defer tr.deinit();
    try std.testing.expect(tr.point_index.len >= 2);
    try std.testing.expect(tr.filter_present); // filters stay raw by design

    var kbuf: [32]u8 = undefined;
    var ikbuf: [48]u8 = undefined;
    for (0..50) |i| {
        const user = try std.fmt.bufPrint(&kbuf, "key{d:0>4}", .{i});
        const ikl = try internal_key.encode(user, @as(u64, i) + 1, .put, &ikbuf);
        const got = try tr.get(ikbuf[0..ikl]);
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(usize, 21), got.?.len);
        alloc.free(got.?);
    }
    const miss = try internal_key.encode("no-such-key", 1, .put, &ikbuf);
    try std.testing.expect((try tr.get(ikbuf[0..miss])) == null);
    var table_it = TableReader.TableIter.init(&tr);
    defer table_it.deinit();
    try table_it.seekToLast();
    var remaining: usize = 50;
    while (table_it.valid()) : (try table_it.prev()) {
        remaining -= 1;
        try std.testing.expectEqual(@as(u64, remaining + 1), (try internal_key.decode(table_it.key())).seq);
    }
    try std.testing.expectEqual(@as(usize, 0), remaining);
}

fn transferBlocksWithCacheFailures(cache_allocator: std.mem.Allocator, dir: disk.Dir, use_iterator: bool) !void {
    const CountingAllocator = @import("../util/counting_allocator.zig").CountingAllocator;
    var owner = CountingAllocator{ .parent = std.testing.allocator };
    defer std.testing.expectEqual(@as(usize, 0), owner.stats().allocated_bytes) catch @panic("transferred block leaked");
    var cache = block_cache.BlockCache.init(cache_allocator, std.testing.io, 1024 * 1024);
    defer cache.deinit();
    {
        var table = try TableReader.openWithCache(owner.allocator(), std.testing.io, dir, "transfer.sst", &cache, 83);
        defer table.deinit();
        if (use_iterator) {
            var it = TableReader.TableIter.initCached(&table);
            defer it.deinit();
            try it.seekToFirst();
            var count: usize = 0;
            while (it.valid()) : (try it.next()) {
                try std.testing.expectEqual(@as(u64, count + 1), (try internal_key.decode(it.key())).seq);
                try std.testing.expectEqual(@as(usize, 21), it.value().len);
                count += 1;
            }
            try std.testing.expectEqual(@as(usize, 50), count);
            const reads = table.data_block_reads.load(.monotonic);
            try it.seekToLast();
            while (it.valid()) : (try it.prev()) {
                try std.testing.expect(count > 0);
                try std.testing.expectEqual(@as(u64, count), (try internal_key.decode(it.key())).seq);
                count -= 1;
            }
            try std.testing.expectEqual(@as(usize, 0), count);
            try std.testing.expectEqual(reads, table.data_block_reads.load(.monotonic));
        } else {
            var user_buffer: [32]u8 = undefined;
            var key_buffer: [48]u8 = undefined;
            for (0..2) |_| {
                const reads = table.data_block_reads.load(.monotonic);
                for (0..50) |i| {
                    const user = try std.fmt.bufPrint(&user_buffer, "key{d:0>4}", .{i});
                    const len = try internal_key.encode(user, i + 1, .put, &key_buffer);
                    const value = (try table.get(key_buffer[0..len])).?;
                    defer owner.allocator().free(value);
                    try std.testing.expectEqual(@as(usize, 21), value.len);
                    for (value) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
                }
                if (reads != 0) try std.testing.expectEqual(reads, table.data_block_reads.load(.monotonic));
            }
        }
    }
    // Transferred blocks survive reader teardown, but retain their original
    // allocator until cache teardown releases the complete backing allocation.
    try std.testing.expect(cache.stats().bytes > 0);
    try std.testing.expectEqual(cache.stats().bytes, owner.stats().allocated_bytes);
}

test "table reader: transferred raw and deflate blocks release their owner through cache failures" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    for ([_]tmod.Compression{ .none, .deflate }) |compression| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const image = try buildFixtureImage(alloc, 50, .{ .block_size = 256, .compression = compression });
        defer alloc.free(image);
        const file = try tmp.dir.createFile(io, "transfer.sst", .{ .truncate = true });
        defer file.close(io);
        try disk.pwriteAll(file, io, image, 0);
        for ([_]bool{ false, true }) |use_iterator| {
            try std.testing.checkAllAllocationFailures(alloc, transferBlocksWithCacheFailures, .{ tmp.dir, use_iterator });
        }
    }
}
