//! Arena-backed skip list: one arena allocation per node, laid out as
//! `[varint key_len][varint val_len][key][value][pad8][tower]`. Single writer,
//! lock-free readers: every byte of a node is written before the release-store
//! that publishes it, and neither node nor arena ever moves — a reader that
//! holds a ref always sees stable memory.

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const rand = @import("../util/rand.zig");
const varint = @import("../util/varint.zig");
const internal_key = @import("../util/internal_key.zig");

pub const max_height = 12;

/// Node handle: the allocation's address. Bytes are read through `parts()`.
pub const Node = opaque {};

// cmp: any comptime callable `(node_key, user, seq, kind) -> std.math.Order` —
// `anytype` because an `inline fn` has its own calling convention and cannot
// coerce into a plain `*const fn`.
pub fn SkipList(comptime cmp: anytype) type {
    return struct {
        const Self = @This();

        arena: *ArenaAllocator,
        head: *Node,
        /// Levels in use (>= 1). Writer stores; readers treat it as a start
        /// hint only — a stale value costs a level, never correctness.
        height: std.atomic.Value(u32) = .init(1),
        rng: rand.Rand,

        pub fn init(arena: *ArenaAllocator, seed: u64) !Self {
            const bytes = try arena.allocator().alignedAlloc(
                u8,
                .@"8",
                max_height * @sizeOf(?*Node),
            );
            @memset(bytes, 0); // every next slot starts as null
            return .{
                .arena = arena,
                .head = @ptrCast(bytes.ptr),
                .rng = rand.Rand.init(seed),
            };
        }

        /// p = 1/4 per level above 1: consume one trailing 2-bit group per step.
        /// (Plain `1 + ctz(x)` would make p = 1/2 and saturate the top level.)
        fn genHeight(self: *Self) u32 {
            var x = self.rng.next();
            var h: u32 = 1;
            while (h < max_height and (x & 0b11) == 0) : (x >>= 2) h += 1;
            return h;
        }

        const Parts = struct { key: []const u8, value: []const u8, tower: [*]?*Node };

        inline fn parts(n: *Node) Parts {
            const base: [*]align(1) u8 = @ptrCast(n);
            // Two varints, then key bytes, then value; tower starts 8-aligned
            // after that. The 5-byte windows are safe: a node's allocation is
            // always larger, and a valid varint terminates inside them.
            const key_len = varint.getU32(base[0..5]) catch unreachable;
            const val_off = key_len.len;
            const val_len = varint.getU32(base[val_off .. val_off + 5]) catch unreachable;
            const key_start = val_off + val_len.len;
            const value_start = key_start + key_len.value;
            const value_end = value_start + val_len.value;
            const tower_off = std.mem.alignForward(usize, value_end, @alignOf(?*Node));
            return .{
                .key = base[key_start..value_start],
                .value = base[value_start..value_end],
                .tower = @ptrCast(@alignCast(base + tower_off)),
            };
        }
        inline fn slot(self: *Self, n: *Node, level: usize) *?*Node {
            const tower: [*]?*Node = if (n == self.head)
                @ptrCast(@alignCast(n))
            else
                parts(n).tower;
            return &tower[level];
        }

        pub inline fn nodeKey(n: *Node) []const u8 {
            return parts(n).key;
        }

        pub inline fn nodeValue(n: *Node) []const u8 {
            return parts(n).value;
        }

        /// One arena allocation: content first, then an 8-aligned null tower.
        /// The two length prefixes are sized by throwing the varints at stack
        /// buffers, so the real writes below cannot run out of room.
        fn allocNode(
            self: *Self,
            user_key: []const u8,
            seq: u64,
            kind: internal_key.Kind,
            header: []const u8,
            payload: []const u8,
            h: usize,
        ) !*Node {
            var tk: [5]u8 = undefined;
            var tv: [5]u8 = undefined;
            const key_len = user_key.len + internal_key.suffix_len;
            const kn = varint.putU32(&tk, @intCast(key_len)) catch unreachable;
            const value_len = header.len + payload.len;
            const vn = varint.putU32(&tv, @intCast(value_len)) catch unreachable;
            const content = kn + vn + key_len + value_len;
            const tower_off = std.mem.alignForward(usize, content, @alignOf(?*Node));
            const total = tower_off + @as(usize, h) * @sizeOf(?*Node);
            const bytes = try self.arena.allocator().alignedAlloc(u8, .@"8", total);
            @memset(bytes[tower_off..], 0);
            var off: usize = 0;
            @memcpy(bytes[0..kn], tk[0..kn]);
            @memcpy(bytes[kn .. kn + vn], tv[0..vn]);
            off = kn + vn;
            // The internal key is built straight into the node — no temp buffer
            // (encoding one on the stack could cost 64 KiB per call).
            off += internal_key.encode(user_key, seq, kind, bytes[off..]) catch unreachable;
            @memcpy(bytes[off .. off + header.len], header);
            off += header.len;
            @memcpy(bytes[off .. off + payload.len], payload);
            return @ptrCast(bytes.ptr);
        }

        /// Top-down walk: `preds[i]` = last node with key < target at level i;
        /// returns the first node >= target (null = end). One pass serves both
        /// insert linking and seek.
        fn find(self: *Self, user_key: []const u8, seq: u64, kind: internal_key.Kind, preds: *[max_height]?*Node) ?*Node {
            var x: *Node = self.head;
            var tower: [*]?*Node = @ptrCast(@alignCast(self.head));
            var level: usize = self.height.load(.monotonic) - 1;
            while (true) {
                const nxt = @atomicLoad(?*Node, &tower[level], .acquire);
                if (nxt) |node| {
                    const decoded = parts(node);
                    if (cmp(decoded.key, user_key, seq, kind) == .lt) {
                        x = node;
                        // Node bytes never move; keep the decoded tower across
                        // horizontal steps and descents, but reload each link.
                        tower = decoded.tower;
                        continue;
                    }
                }
                preds[level] = x;
                if (level == 0) return nxt;
                level -= 1;
            }
        }

        /// Single writer: fill the whole node first, then publish level by
        /// level with release stores; raise `height` only after its new links
        /// exist (a reader starting high on stale state just finds an empty level).
        pub fn insert(self: *Self, user_key: []const u8, seq: u64, kind: internal_key.Kind, value: []const u8) !void {
            try self.insertParts(user_key, seq, kind, value, "");
        }

        /// Both slices are copied into the final node before publication;
        /// neither caller-owned slice must outlive this call.
        pub fn insertParts(self: *Self, user_key: []const u8, seq: u64, kind: internal_key.Kind, header: []const u8, payload: []const u8) !void {
            const h: usize = self.genHeight();
            var preds: [max_height]?*Node = undefined;
            _ = self.find(user_key, seq, kind, &preds); // duplicates are allowed (flush never re-inserts a key)
            const n = try self.allocNode(user_key, seq, kind, header, payload, h);
            const tower = parts(n).tower;
            const cur_h: usize = self.height.load(.monotonic);
            for (0..h) |i| {
                const p = if (i < cur_h) preds[i].? else self.head;
                // Own tower: plain writes — no reader can reach `n` yet.
                tower[i] = @atomicLoad(?*Node, self.slot(p, i), .monotonic);
            }
            for (0..h) |i| {
                const p = if (i < cur_h) preds[i].? else self.head;
                @atomicStore(?*Node, self.slot(p, i), n, .release);
            }
            if (h > cur_h) self.height.store(@intCast(h), .release);
        }

        pub const Iterator = struct {
            list: *Self,
            node: ?*Node = null,

            /// Readers hold a table ref; only one writer may insert. Reverse
            /// steps re-search acquire-loaded links rather than modifying nodes.
            /// Concurrent inserts can be observed; snapshot filtering is external.
            pub fn seekToFirst(self: *Iterator) void {
                self.node = @atomicLoad(?*Node, self.list.slot(self.list.head, 0), .acquire);
            }

            pub fn seekToLast(self: *Iterator) void {
                var node = self.list.head;
                var tower: [*]?*Node = @ptrCast(@alignCast(node));
                var level: usize = self.list.height.load(.monotonic) - 1;
                while (true) {
                    if (@atomicLoad(?*Node, &tower[level], .acquire)) |next_node| {
                        node = next_node;
                        tower = parts(node).tower;
                    } else {
                        if (level == 0) break;
                        level -= 1;
                    }
                }
                self.node = if (node == self.list.head) null else node;
            }

            /// Strict predecessor of an internal key; null before the first.
            pub fn seekBefore(self: *Iterator, user_key: []const u8, seq: u64, kind: internal_key.Kind) void {
                var preds: [max_height]?*Node = undefined;
                _ = self.list.find(user_key, seq, kind, &preds);
                self.node = if (preds[0] == self.list.head) null else preds[0];
            }

            pub fn prev(self: *Iterator) void {
                if (self.node) |node| {
                    const decoded = internal_key.decode(nodeKey(node)) catch unreachable;
                    self.seekBefore(decoded.user, decoded.seq, decoded.kind);
                }
            }

            pub fn seek(self: *Iterator, user_key: []const u8, seq: u64, kind: internal_key.Kind) void {
                var preds: [max_height]?*Node = undefined;
                self.node = self.list.find(user_key, seq, kind, &preds);
            }

            /// Caller contract: `valid()` must hold. Advances to null at the
            /// end and stays there (a next() on null is a no-op).
            pub fn next(self: *Iterator) void {
                if (self.node) |n| {
                    self.node = @atomicLoad(?*Node, self.list.slot(n, 0), .acquire);
                }
            }

            pub inline fn valid(self: *const Iterator) bool {
                return self.node != null;
            }

            pub inline fn key(self: *const Iterator) []const u8 {
                return nodeKey(self.node.?);
            }

            pub inline fn value(self: *const Iterator) []const u8 {
                return nodeValue(self.node.?);
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .list = self };
        }
    };
}

test "shuffled inserts walk back sorted; findGE covers every boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const SL = SkipList(internal_key.compareParts);
    var sl = try SL.init(&arena, 0xBEEF);
    var rnd = rand.Rand.init(7);

    var preds: [max_height]?*Node = undefined;
    try std.testing.expect(sl.find("a", 1, .put, &preds) == null); // empty table -> no first-≥

    const n = 32;
    var order: [n]u8 = undefined;
    for (&order, 0..) |*o, i| o.* = @intCast(i);
    var i: usize = n;
    while (i > 1) {
        i -= 1;
        const j: usize = @intCast(rnd.below(i + 1));
        const t = order[i];
        order[i] = order[j];
        order[j] = t;
    }

    for (order) |raw| {
        const idx: usize = raw;
        var ub: [8]u8 = undefined;
        const user = try std.fmt.bufPrint(&ub, "k{d:0>2}", .{idx});
        var vb: [8]u8 = undefined;
        const val = try std.fmt.bufPrint(&vb, "v{d}", .{idx});
        try sl.insert(user, idx + 1, .put, val);
    }

    var walked: usize = 0;
    var cur = @atomicLoad(?*Node, sl.slot(sl.head, 0), .monotonic);
    while (cur) |c| : (cur = @atomicLoad(?*Node, sl.slot(c, 0), .monotonic)) {
        const v = internal_key.decode(SL.nodeKey(c)) catch unreachable;
        var eb: [8]u8 = undefined;
        const want_user = try std.fmt.bufPrint(&eb, "k{d:0>2}", .{walked});
        try std.testing.expectEqualStrings(want_user, v.user);
        var ev: [8]u8 = undefined;
        const want_val = try std.fmt.bufPrint(&ev, "v{d}", .{walked});
        try std.testing.expectEqualStrings(want_val, SL.nodeValue(c));
        walked += 1;
    }
    try std.testing.expectEqual(@as(usize, n), walked);

    const g = sl.find("k10", 999, .put, &preds).?; // seq 999 brackets the stored seq 11
    try std.testing.expectEqualStrings("k10", (internal_key.decode(SL.nodeKey(g)) catch unreachable).user);
    const g0 = sl.find("a", 1, .put, &preds).?; // before everything
    try std.testing.expectEqualStrings("k00", (internal_key.decode(SL.nodeKey(g0)) catch unreachable).user);
    try std.testing.expect(sl.find("zz", 1, .put, &preds) == null);
}

test "heights follow p = 1/4 per level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const SL = SkipList(internal_key.compareParts);
    var sl = try SL.init(&arena, 42);
    var tall: usize = 0;
    for (0..10_000) |_| {
        if (sl.genHeight() >= 2) tall += 1;
    }
    // P(h >= 2) = 1/4; 10k draws sit far inside a +-11 sigma band of 2500.
    try std.testing.expect(tall > 2000 and tall < 3300);
}

test "skiplist: multilevel seeks preserve long-key gaps and mixed value lengths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const SL = SkipList(internal_key.compareParts);
    var sl = try SL.init(&arena, 99);
    var user: [119]u8 = @splat(0x80);
    const value: [300]u8 = @splat(0xAB);
    const sizes = [_]usize{ 0, 127, 128, 300 };
    for (0..256) |i| {
        const key_id = (i * 73) % 256;
        std.mem.writeInt(u16, user[user.len - 2 ..][0..2], @intCast(key_id * 2), .big);
        try sl.insert(&user, 7, .put, value[0..sizes[key_id % sizes.len]]);
    }
    try std.testing.expect(sl.height.load(.monotonic) > 2);
    var it = sl.iterator();
    for (0..513) |target| {
        std.mem.writeInt(u16, user[user.len - 2 ..][0..2], @intCast(target), .big);
        it.seek(&user, 7, .put);
        const expected = (target + 1) / 2;
        try std.testing.expectEqual(expected < 256, it.valid());
        if (it.valid()) {
            const found = try internal_key.decode(it.key());
            try std.testing.expectEqual(@as(u16, @intCast(expected * 2)), std.mem.readInt(u16, found.user[found.user.len - 2 ..][0..2], .big));
            try std.testing.expectEqualSlices(u8, value[0..sizes[expected % sizes.len]], it.value());
        }
        it.seekBefore(&user, 7, .put);
        try std.testing.expectEqual(target != 0, it.valid());
        if (it.valid()) {
            const found = try internal_key.decode(it.key());
            const previous: usize = if (target > 510) 510 else (target - 1) & ~@as(usize, 1);
            try std.testing.expectEqual(@as(u16, @intCast(previous)), std.mem.readInt(u16, found.user[found.user.len - 2 ..][0..2], .big));
        }
    }
    it.seekToLast();
    try std.testing.expectEqual(@as(u16, 510), std.mem.readInt(u16, it.key()[user.len - 2 ..][0..2], .big));
}

test "multi-byte lengths and empty values survive the layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const SL = SkipList(internal_key.compareParts);
    var sl = try SL.init(&arena, 99);

    var user: [119]u8 = @splat('u'); // user+9 = 128 -> key_len varint spans 2 bytes
    var value: [300]u8 = @splat(0xAB); // value_len varint also 2 bytes
    try sl.insert(&user, 7, .put, &value);

    try sl.insert("zz", 1, .delete, ""); // empty value -> zero-length varint

    var preds: [max_height]?*Node = undefined;
    const g = sl.find(&user, 7, .put, &preds).?;
    try std.testing.expectEqualSlices(u8, &value, SL.nodeValue(g));
    const g2 = sl.find("zz", 1, .delete, &preds).?;
    try std.testing.expectEqual(SL.nodeValue(g2).len, 0);
}

test "skiplist: split values preserve boundaries and own both input slices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const SL = SkipList(internal_key.compareParts);
    var sl = try SL.init(&arena, 31);
    const user: [1024]u8 = @splat('k');
    const sizes = [_]usize{ 0, 1, 127, 128, 300 };
    var source: [300]u8 = undefined;
    var seq: u64 = 0;
    for ([_]usize{ 0, 118, 119, 1024 }) |key_len| {
        for (sizes) |value_len| {
            for ([_]usize{ 0, value_len / 2, value_len }) |split| {
                for (source[0..value_len], 0..) |*byte, i| byte.* = @truncate(i);
                seq += 1;
                try sl.insertParts(user[0..key_len], seq, .put, source[0..split], source[split..value_len]);
                @memset(source[0..value_len], 0xff);
                var it = sl.iterator();
                it.seek(user[0..key_len], seq, .put);
                const key = try internal_key.decode(it.key());
                try std.testing.expectEqualSlices(u8, user[0..key_len], key.user);
                try std.testing.expectEqual(seq, key.seq);
                const stored = it.value();
                try std.testing.expectEqual(value_len, stored.len);
                for (stored, 0..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(i)), byte);
            }
        }
    }
}

test "iterator: ordered walk, mid seek, sticky end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const SL = SkipList(internal_key.compareParts);
    var sl = try SL.init(&arena, 5);

    var it = sl.iterator();
    it.seekToFirst();
    try std.testing.expect(!it.valid()); // empty table -> end

    // Insert keys backwards; order must come from the list, not the input.
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        var ub: [8]u8 = undefined;
        const user = try std.fmt.bufPrint(&ub, "k{d}", .{i});
        try sl.insert(user, 1, .put, "v");
    }

    it.seekToFirst();
    var seen: usize = 0;
    while (it.valid()) : (it.next()) {
        const d = internal_key.decode(it.key()) catch unreachable;
        var eb: [8]u8 = undefined;
        const want = try std.fmt.bufPrint(&eb, "k{d}", .{seen});
        try std.testing.expectEqualStrings(want, d.user);
        try std.testing.expectEqualStrings("v", it.value());
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), seen);

    it.seek("k3", 1, .put); // exact hit -> k3..k7 remain
    var remain: usize = 0;
    while (it.valid()) : (it.next()) remain += 1;
    try std.testing.expectEqual(@as(usize, 5), remain);

    it.seek("zz", 1, .put);
    try std.testing.expect(!it.valid());
    it.next(); // past-the-end state is stable
    try std.testing.expect(!it.valid());
}

test "skiplist reverse: empty, strict predecessor, versions and publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const SL = SkipList(internal_key.compareParts);
    var sl = try SL.init(&arena, 17);
    var it = sl.iterator();
    it.seekToLast();
    try std.testing.expect(!it.valid());
    it.prev();
    try sl.insert("b", 1, .put, "old");
    try sl.insert("d", 2, .put, "last");
    try sl.insert("b", 3, .delete, "");
    it.seekToLast();
    try std.testing.expectEqualStrings("last", it.value());
    it.prev();
    try std.testing.expectEqualStrings("old", it.value());
    it.prev();
    try std.testing.expectEqual(internal_key.Kind.delete, (try internal_key.decode(it.key())).kind);
    it.prev();
    try std.testing.expect(!it.valid());
    it.prev();
    for ([_][]const u8{ "a", "b", "c", "z" }, 0..) |user, i| {
        it.seekBefore(user, std.math.maxInt(u64), .put);
        try std.testing.expectEqual(i >= 2, it.valid());
        if (it.valid()) try std.testing.expect(std.mem.order(u8, (try internal_key.decode(it.key())).user, user) == .lt);
    }
    // A single writer publishes while the reader traverses existing nodes.
    const Writer = struct {
        fn run(list: *SL) void {
            for (0..500) |i| list.insert("c", i + 10, .put, "published") catch @panic("insert failed");
        }
    };
    const writer = try std.Thread.spawn(.{}, Writer.run, .{&sl});
    defer writer.join();
    for (0..20) |_| {
        it.seekToLast();
        var previous_seq: u64 = 0;
        while (it.valid()) : (it.prev()) {
            const decoded = try internal_key.decode(it.key());
            if (std.mem.eql(u8, decoded.user, "c")) {
                try std.testing.expect(decoded.seq > previous_seq);
                previous_seq = decoded.seq;
                try std.testing.expectEqualStrings("published", it.value());
            }
        }
    }
}
