//! Compaction triggers, input selection and size limits over a VersionSet.
//! This module performs no I/O; callers build and commit the selected merge.

const std = @import("std");
const mf = @import("../manifest/format.zig");
const VersionSet = @import("../manifest/reader.zig").VersionSet;

pub const Params = struct {
    max_levels: u32 = 7,
    level_multiplier: u64 = 10,
    l0_compaction_trigger: u32 = 4,
    write_buffer_size: u64 = 64 * 1024 * 1024,
    max_compaction_bytes: u64 = 2 * 1024 * 1024 * 1024,
    max_compaction_input_files: u32 = 64,
    max_sst_file_size: u64 = 64 * 1024 * 1024,

    /// L1 capacity is `write_buffer_size * level_multiplier`; each deeper
    /// level multiplies capacity by `level_multiplier` again.
    pub fn levelCapacity(p: Params, level: u32) u64 {
        std.debug.assert(level >= 1);
        var cap = p.write_buffer_size * p.level_multiplier;
        var i: u32 = 1;
        while (i < level) : (i += 1) cap *= p.level_multiplier;
        return cap;
    }
};

/// Borrowed pointers into the VersionSet's own lists — valid until the
/// next mutation of the VersionSet.
pub const Plan = struct {
    level: u32, // source level
    output_level: u32, // always level + 1
    inputs: std.ArrayListUnmanaged(*const mf.FileMeta) = .empty, // source level
    overlaps: std.ArrayListUnmanaged(*const mf.FileMeta) = .empty, // output level

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
        self.overlaps.deinit(allocator);
    }
};

pub fn rangesOverlap(a_small: []const u8, a_large: []const u8, b_small: []const u8, b_large: []const u8) bool {
    return std.mem.order(u8, a_small, b_large) != .gt and std.mem.order(u8, b_small, a_large) != .gt;
}

/// Promotion can reuse immutable bytes only when the destination needs no
/// merge and every source already fits the target's size and range invariants.
pub fn canMove(plan: *const Plan, p: Params) bool {
    if (plan.inputs.items.len == 0 or plan.overlaps.items.len != 0 or
        plan.output_level >= p.max_levels or plan.level >= plan.output_level or
        plan.output_level - plan.level != 1) return false;
    for (plan.inputs.items, 0..) |file, i| {
        if (file.level != plan.level or file.file_size > p.max_sst_file_size) return false;
        for (plan.inputs.items[0..i]) |previous| {
            if (rangesOverlap(previous.smallest, previous.largest, file.smallest, file.largest)) return false;
        }
    }
    return true;
}

/// The trigger and the input-set picker of the compaction rules: L0
/// scores by file count against the trigger, L1+ by bytes against
/// capacity; the highest score at or above 1 wins, ties go to the
/// shallower level. The picked set is one source file plus every
/// output-level file its key range touches (mandatory, never truncated),
/// grown with further source files in pick order while the running total
/// stays inside `max_compaction_bytes` and the soft file cap.
pub fn pick(allocator: std.mem.Allocator, vs: *const VersionSet, p: Params) error{OutOfMemory}!?Plan {
    var best_score: f64 = 0;
    var best_level: ?u32 = null;

    {
        const count = vs.fileCount(0);
        const score = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(p.l0_compaction_trigger));
        if (score >= 1) {
            best_score = score;
            best_level = 0;
        }
    }
    var lvl: u32 = 1;
    while (lvl + 1 < p.max_levels) : (lvl += 1) {
        var bytes: u64 = 0;
        if (vs.by_level.get(lvl)) |list| {
            for (list.items) |f| bytes += f.file_size;
        }
        const score = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(p.levelCapacity(lvl)));
        if (score >= 1 and score > best_score) {
            best_score = score;
            best_level = lvl;
        }
    }
    const level = best_level orelse return null;

    var plan = Plan{ .level = level, .output_level = level + 1 };
    errdefer plan.deinit(allocator);

    // Source pick: L0 takes the oldest file (smallest id, flush order);
    // deeper levels take the leftmost key range, sweeping each level
    // left to right so no file can starve.
    const source_list = vs.by_level.get(level).?;
    var first: ?*const mf.FileMeta = null;
    {
        var min_id: u64 = std.math.maxInt(u64);
        for (source_list.items) |*f| {
            if (level == 0) {
                if (f.file_id < min_id) {
                    min_id = f.file_id;
                    first = f;
                }
            } else if (first == null or std.mem.order(u8, f.smallest, first.?.smallest) == .lt) {
                first = f;
            }
        }
    }
    const first_file = first.?; // a score at or above 1 guarantees a non-empty level
    try plan.inputs.append(allocator, first_file);

    // Growth order for extras: id order at L0, key order deeper.
    var order: std.ArrayListUnmanaged(*const mf.FileMeta) = .empty;
    defer order.deinit(allocator);
    for (source_list.items) |*f| {
        if (f.file_id != first_file.file_id) try order.append(allocator, f);
    }
    std.sort.heap(*const mf.FileMeta, order.items, {}, struct {
        fn lt(_: void, a: *const mf.FileMeta, b: *const mf.FileMeta) bool {
            if (a.file_id == b.file_id) return false;
            return a.file_id < b.file_id;
        }
    }.lt);
    if (level != 0) {
        std.sort.heap(*const mf.FileMeta, order.items, {}, struct {
            fn lt(_: void, a: *const mf.FileMeta, b: *const mf.FileMeta) bool {
                return std.mem.order(u8, a.smallest, b.smallest) == .lt;
            }
        }.lt);
    }

    var running: u64 = first_file.file_size;
    try collectOverlaps(allocator, vs, plan.output_level, first_file, &plan, &running);

    for (order.items) |cand| {
        if (plan.inputs.items.len >= p.max_compaction_input_files) break;
        var cost: u64 = cand.file_size;
        var extra: std.ArrayListUnmanaged(*const mf.FileMeta) = .empty;
        defer extra.deinit(allocator);
        // Output SSTs may span gaps between selected source files. Include
        // every destination file inside that combined range, exactly once.
        var range = cand.*;
        for (plan.inputs.items) |file| {
            if (std.mem.order(u8, file.smallest, range.smallest) == .lt) range.smallest = file.smallest;
            if (std.mem.order(u8, file.largest, range.largest) == .gt) range.largest = file.largest;
        }
        for (plan.overlaps.items) |file| {
            if (std.mem.order(u8, file.smallest, range.smallest) == .lt) range.smallest = file.smallest;
            if (std.mem.order(u8, file.largest, range.largest) == .gt) range.largest = file.largest;
        }
        try collectOverlapsInto(allocator, vs, plan.output_level, &range, &extra);
        for (extra.items) |f| if (!already(plan.overlaps, f.file_id)) {
            cost += f.file_size;
        };
        if (running + cost > p.max_compaction_bytes) break;
        try plan.inputs.append(allocator, cand);
        for (extra.items) |f| if (!already(plan.overlaps, f.file_id)) {
            try plan.overlaps.append(allocator, f);
        };
        running += cost;
    }
    return plan;
}

fn already(list: std.ArrayListUnmanaged(*const mf.FileMeta), id: u64) bool {
    for (list.items) |f| {
        if (f.file_id == id) return true;
    }
    return false;
}

fn collectOverlapsInto(
    allocator: std.mem.Allocator,
    vs: *const VersionSet,
    output_level: u32,
    src: *const mf.FileMeta,
    out: *std.ArrayListUnmanaged(*const mf.FileMeta),
) error{OutOfMemory}!void {
    if (vs.by_level.get(output_level)) |list| {
        for (list.items) |*f| {
            if (rangesOverlap(src.smallest, src.largest, f.smallest, f.largest) and !already(out.*, f.file_id)) {
                try out.append(allocator, f);
            }
        }
    }
}

fn collectOverlaps(
    allocator: std.mem.Allocator,
    vs: *const VersionSet,
    output_level: u32,
    src: *const mf.FileMeta,
    plan: *Plan,
    running: *u64,
) error{OutOfMemory}!void {
    var extra: std.ArrayListUnmanaged(*const mf.FileMeta) = .empty;
    defer extra.deinit(allocator);
    try collectOverlapsInto(allocator, vs, output_level, src, &extra);
    for (extra.items) |f| {
        try plan.overlaps.append(allocator, f);
        running.* += f.file_size;
    }
}

/// Tombstone fate at the destination level: the bottom level swallows
/// tombstones outright; anywhere else one survives only while a file
/// below could still hold the value it buries.
pub fn dropTombstone(p: Params, output_level: u32, below_overlaps: bool) bool {
    if (output_level == p.max_levels - 1) return true;
    return !below_overlaps;
}

/// Does any level deeper than `output_level` hold a file touching the
/// user-key range? The compaction's own output level cannot answer this:
/// its overlapping files are inputs being replaced right now.
pub fn rangeOverlapBelow(vs: *const VersionSet, p: Params, output_level: u32, smallest: []const u8, largest: []const u8) bool {
    var lvl = output_level + 1;
    while (lvl < p.max_levels) : (lvl += 1) {
        if (vs.by_level.get(lvl)) |list| {
            for (list.items) |f| {
                if (rangesOverlap(smallest, largest, f.smallest, f.largest)) return true;
            }
        }
    }
    return false;
}

fn addFile(vs: *VersionSet, level: u32, id: u64, size: u64, smallest: []const u8, largest: []const u8) !void {
    const f = mf.FileMeta{
        .level = level,
        .file_id = id,
        .file_size = size,
        .smallest = smallest,
        .largest = largest,
        .min_seq = 1,
        .max_seq = 1,
        .vlog_ids = "",
    };
    const adds = [_]mf.FileMeta{f};
    var e = mf.Edit{ .adds = &adds };
    try vs.apply(&e); // clones what it stores; the literal edit owns nothing
}

test "level capacity: L1 is one decade above a memtable, then multiplies" {
    const p = Params{ .write_buffer_size = 64 * 1024 * 1024, .level_multiplier = 10 };
    try std.testing.expectEqual(@as(u64, 640 * 1024 * 1024), p.levelCapacity(1));
    try std.testing.expectEqual(@as(u64, 6400 * 1024 * 1024), p.levelCapacity(2));
}

test "move: disjoint source ranges retain size and destination invariants" {
    const allocator = std.testing.allocator;
    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    const p = Params{ .l0_compaction_trigger = 2, .max_sst_file_size = 100 };
    try addFile(&vs, 0, 1, 100, "a", "b");
    try addFile(&vs, 0, 2, 100, "c", "d");
    var plan = (try pick(allocator, &vs, p)).?;
    defer plan.deinit(allocator);
    try std.testing.expect(canMove(&plan, p));
    try std.testing.expect(!canMove(&plan, .{ .max_sst_file_size = 99 }));
    try plan.overlaps.append(allocator, plan.inputs.items[0]);
    try std.testing.expect(!canMove(&plan, p));
}

test "move: touching user keys and overlapping source ranges require a merge" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "b", "a" }) |second_smallest| {
        var vs = VersionSet.init(allocator);
        defer vs.deinit();
        const p = Params{ .l0_compaction_trigger = 2 };
        try addFile(&vs, 0, 1, 100, "a", "b");
        try addFile(&vs, 0, 2, 100, second_smallest, "d");
        var plan = (try pick(allocator, &vs, p)).?;
        defer plan.deinit(allocator);
        try std.testing.expect(!canMove(&plan, p));
    }
    var empty: Plan = .{ .level = 0, .output_level = 1 };
    try std.testing.expect(!canMove(&empty, .{}));
}

test "pick: L0 scores by count, below the trigger picks nothing" {
    const allocator = std.testing.allocator;
    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    const p = Params{};

    try addFile(&vs, 0, 1, 100, "a", "b");
    try addFile(&vs, 0, 2, 100, "c", "d");
    try addFile(&vs, 0, 3, 100, "e", "f");
    try std.testing.expect((try pick(allocator, &vs, p)) == null);

    try addFile(&vs, 0, 4, 100, "g", "h");
    var plan = (try pick(allocator, &vs, p)).?;
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), plan.level);
    try std.testing.expectEqual(@as(usize, 4), plan.inputs.items.len); // oldest first, all folded in
    try std.testing.expectEqual(@as(u64, 1), plan.inputs.items[0].file_id);
    try std.testing.expectEqual(@as(usize, 0), plan.overlaps.items.len); // no L1 files
}

test "pick: deeper levels score by bytes against capacity" {
    const allocator = std.testing.allocator;
    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    const p = Params{ .write_buffer_size = 100, .level_multiplier = 10 };

    try addFile(&vs, 1, 1, 1_000, "a", "m"); // capacity(1) = 1000 → score 1
    var plan = (try pick(allocator, &vs, p)).?;
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), plan.level);
    try std.testing.expectEqual(@as(u32, 2), plan.output_level);

    var vs2 = VersionSet.init(allocator);
    defer vs2.deinit();
    try addFile(&vs2, 1, 1, 999, "a", "m");
    try std.testing.expect((try pick(allocator, &vs2, p)) == null);
}

test "pick: the mandatory minimal set survives any byte budget" {
    const allocator = std.testing.allocator;
    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    const p = Params{ .max_compaction_bytes = 10, .l0_compaction_trigger = 1 }; // smaller than one file

    try addFile(&vs, 0, 1, 100, "a", "z");
    try addFile(&vs, 1, 2, 100, "a", "f");
    try addFile(&vs, 1, 3, 100, "g", "z");

    var plan = (try pick(allocator, &vs, p)).?;
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), plan.inputs.items.len);
    try std.testing.expectEqual(@as(usize, 2), plan.overlaps.items.len); // every toucher, never truncated
}

test "pick: growth stops at the byte budget and at the soft file cap" {
    const allocator = std.testing.allocator;
    {
        var vs = VersionSet.init(allocator);
        defer vs.deinit();
        const p = Params{ .max_compaction_bytes = 250, .l0_compaction_trigger = 1 };
        try addFile(&vs, 0, 1, 100, "a", "b");
        try addFile(&vs, 0, 2, 100, "c", "d");
        try addFile(&vs, 0, 3, 100, "e", "f");
        var plan = (try pick(allocator, &vs, p)).?;
        defer plan.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), plan.inputs.items.len); // third would exceed 250
    }
    {
        var vs = VersionSet.init(allocator);
        defer vs.deinit();
        const p = Params{ .max_compaction_input_files = 2, .l0_compaction_trigger = 1 };
        try addFile(&vs, 0, 1, 10, "a", "b");
        try addFile(&vs, 0, 2, 10, "c", "d");
        try addFile(&vs, 0, 3, 10, "e", "f");
        var plan = (try pick(allocator, &vs, p)).?;
        defer plan.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), plan.inputs.items.len); // soft cap on growth
    }
}

test "pick: deeper levels sweep leftmost first" {
    const allocator = std.testing.allocator;
    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    const p = Params{ .write_buffer_size = 100, .level_multiplier = 10 };

    try addFile(&vs, 1, 7, 600, "m", "t");
    try addFile(&vs, 1, 8, 600, "a", "l");
    var plan = (try pick(allocator, &vs, p)).?;
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 8), plan.inputs.items[0].file_id); // "a" < "m"
}

test "tombstones: bottom swallows, otherwise only without a file below" {
    const p = Params{ .max_levels = 7 };
    try std.testing.expect(dropTombstone(p, 6, false)); // bottom ignores overlap
    try std.testing.expect(dropTombstone(p, 3, false));
    try std.testing.expect(!dropTombstone(p, 3, true));

    const allocator = std.testing.allocator;
    var vs = VersionSet.init(allocator);
    defer vs.deinit();
    try addFile(&vs, 4, 1, 10, "k", "n");
    try std.testing.expect(rangeOverlapBelow(&vs, p, 3, "m", "m")); // level 4 touches "m"
    try std.testing.expect(!rangeOverlapBelow(&vs, p, 3, "z", "z"));
    try std.testing.expect(!rangeOverlapBelow(&vs, p, 4, "m", "m")); // nothing below level 4
}

test "rangesOverlap: touching endpoints count as overlap" {
    try std.testing.expect(rangesOverlap("a", "c", "c", "e"));
    try std.testing.expect(!rangesOverlap("a", "b", "c", "e"));
    try std.testing.expect(rangesOverlap("a", "z", "c", "e")); // containment
}

test "pick: destination overlaps are unique and cover gaps between source ranges" {
    const alloc = std.testing.allocator;
    var vs = VersionSet.init(alloc);
    defer vs.deinit();
    try addFile(&vs, 0, 1, 10, "a", "b");
    try addFile(&vs, 0, 2, 10, "y", "z");
    try addFile(&vs, 1, 3, 10, "a", "d");
    try addFile(&vs, 1, 4, 10, "m", "p");
    try addFile(&vs, 1, 5, 10, "x", "z");
    var plan = (try pick(alloc, &vs, .{ .l0_compaction_trigger = 2 })).?;
    defer plan.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), plan.overlaps.items.len);
    for (plan.overlaps.items, 0..) |file, i| for (plan.overlaps.items[i + 1 ..]) |other| {
        try std.testing.expect(file.file_id != other.file_id);
    };
}
