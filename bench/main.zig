const std = @import("std");
const wiskdb = @import("wiskdb");
const zlap = @import("zlap");

const Phase = enum { seed, overwrite, read, verify, hot, missing, mem_read, mem_hot, mem_missing, gc, collections_seed, collections_read, collections_page };

const Context = struct {
    allocator: std.mem.Allocator,
    db: *wiskdb.Db,
    phase: Phase,
    count: usize,
    value_size: usize,
    value: []u8,
    expected_byte: u8,
    next: usize = 0,
};

var context: Context = undefined;

fn keyFor(index: usize) [8]u8 {
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, @intCast(index), .big);
    return key;
}

fn indexFor(operation: usize, count: usize) usize {
    var value: u64 = @as(u64, @intCast(operation)) +% 0x9e3779b97f4a7c15;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    return @intCast((value ^ (value >> 31)) % count);
}

fn workload(_: std.mem.Allocator, operations: usize) anyerror!void {
    const ctx = &context;
    if (ctx.phase == .collections_page) {
        var collections = wiskdb.Collections.init(ctx.db, "bench");
        const middle = ctx.count / 2;
        const member = keyFor(middle);
        for (0..operations) |_| {
            const rows = try collections.zsetQuery("rank", null, null, .{ .score = @intCast(middle), .member = &member }, false, 10);
            defer collections.freeZ(rows);
            if (rows.len != @min(10, ctx.count - middle - 1)) return error.WrongResultCount;
            for (rows, 0..) |row, rank| if (row.score != middle + rank + 1) return error.WrongRank;
        }
        return;
    }
    if (ctx.phase == .collections_seed or ctx.phase == .collections_read) {
        var collections = wiskdb.Collections.init(ctx.db, "bench");
        if (ctx.phase == .collections_seed) {
            for (0..operations) |i| {
                var key: [8]u8 = undefined;
                std.mem.writeInt(u64, &key, @intCast((ctx.next + i) % ctx.count), .big);
                try collections.hashSet("hash", &key, ctx.value);
                try collections.zsetAdd("rank", &key, @intCast((ctx.next + i) % ctx.count));
            }
        } else {
            for (0..operations) |i| {
                var key: [8]u8 = undefined;
                std.mem.writeInt(u64, &key, @intCast((ctx.next + i) % ctx.count), .big);
                const value = (try collections.hashGet("hash", &key)) orelse return error.MissingKey;
                defer ctx.allocator.free(value);
                const rows = try collections.zsetQuery("rank", null, null, null, true, 10);
                defer collections.freeZ(rows);
                if (rows.len != @min(ctx.count, 10)) return error.WrongResultCount;
                for (rows, 0..) |row, rank| {
                    const expected = ctx.count - 1 - rank;
                    if (row.score != expected or row.member.len != 8 or std.mem.readInt(u64, row.member[0..8], .big) != expected) return error.WrongRank;
                }
            }
        }
        ctx.next += operations;
        return;
    }
    switch (ctx.phase) {
        .seed, .overwrite => {
            for (0..operations) |_| {
                const index = ctx.next % ctx.count;
                const key = keyFor(index);
                try ctx.db.put(&key, ctx.value);
                ctx.next += 1;
            }
        },
        .gc => for (0..operations) |_| try ctx.db.collectGarbage(),
        else => {
            for (0..operations) |offset| {
                const operation = ctx.next + offset;
                const index = switch (ctx.phase) {
                    .read, .mem_read => indexFor(operation, ctx.count),
                    .hot, .mem_hot => operation % @min(ctx.count, 64),
                    .missing, .mem_missing => ctx.count + operation,
                    .verify => operation % ctx.count,
                    else => unreachable,
                };
                const key = keyFor(index);
                const maybe_value = try ctx.db.get(&key);
                if (ctx.phase == .missing or ctx.phase == .mem_missing) {
                    if (maybe_value) |value| {
                        ctx.allocator.free(value);
                        return error.UnexpectedHit;
                    }
                    continue;
                }
                const value = maybe_value orelse return error.MissingKey;
                defer ctx.allocator.free(value);
                if (value.len != ctx.value_size) return error.WrongValueSize;
                for (value) |byte| if (byte != ctx.expected_byte) return error.WrongValue;
            }
            ctx.next += operations;
        },
    }
}

fn parseInt(comptime T: type, args: []const []const u8, index: usize, default: T) !T {
    if (args.len <= index) return default;
    return try std.fmt.parseInt(T, args[index], 10);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 8) return error.ExpectedAtMostSevenArguments;
    const expected_byte: u8 = if (args.len > 6 and std.mem.eql(u8, args[6], "b")) 'b' else if (args.len <= 6 or std.mem.eql(u8, args[6], "a")) 'a' else return error.ExpectedValueMustBeAOrB;

    const path = if (args.len > 1) args[1] else "out/bench-db";
    const phase = if (args.len > 2) std.meta.stringToEnum(Phase, args[2]) orelse return error.UnknownPhase else .seed;
    const count = try parseInt(usize, args, 3, 100_000);
    const value_size = try parseInt(usize, args, 4, 128);
    const durability = if (args.len > 5) std.meta.stringToEnum(wiskdb.Durability, args[5]) orelse return error.UnknownDurability else .interval;
    const block_cache_size = try parseInt(usize, args, 7, 8 * 1024 * 1024);
    if (count == 0 or value_size == 0 or value_size > 16 * 1024 * 1024) return error.InvalidOptions;

    const io = init.io;
    const is_mem = phase == .mem_read or phase == .mem_hot or phase == .mem_missing;
    // Match MemTable accounting with inline values and leave one byte of
    // headroom so preparation never rotates the measured current table.
    const mem_entry_size = try std.math.add(u64, value_size, 8 + 9 + 21 + 64);
    const mem_buffer_size = if (is_mem) try std.math.add(u64, try std.math.mul(u64, count, mem_entry_size), 1) else 256 * 1024;
    const is_seed = phase == .seed or phase == .collections_seed;
    var db = try wiskdb.Open(init.gpa, io, path, .{
        .create_if_missing = is_seed or is_mem,
        .db = .{
            .durability = durability,
            .write_buffer_size = mem_buffer_size,
            .value_threshold = if (is_mem) value_size + 1 else 512,
            .max_sst_file_size = 1024 * 1024,
            .vlog_file_size = 1024 * 1024,
            .l0_compaction_trigger = 2,
            .automatic_gc = false,
            .block_cache_size = block_cache_size,
        },
    });
    defer db.deinit();

    const value = try init.gpa.alloc(u8, value_size);
    defer init.gpa.free(value);
    @memset(value, if (is_mem) expected_byte else if (phase == .overwrite) 'b' else 'a');
    context = .{
        .allocator = init.gpa,
        .db = &db,
        .phase = phase,
        .count = count,
        .value_size = value_size,
        .value = value,
        .expected_byte = expected_byte,
    };

    if (is_mem) {
        // Use a fresh path for these phases. Only reads enter the timing loop;
        // preparation stays in the current MemTable without an explicit flush.
        context.phase = .seed;
        try workload(init.gpa, count);
    } else if (phase == .seed or phase == .overwrite or phase == .collections_seed) {
        try workload(init.gpa, count);
        try db.flush();
    }
    context.phase = phase;
    context.next = 0;

    const batch_size: usize = if (phase == .seed or phase == .overwrite) 1000 else 100;
    const memory_before = db.stat();
    const result = try zlap.runConfigured(io, .{
        .allocator = init.gpa,
        .batch_size = batch_size,
        .sample_count = 20,
        .rounds = 3,
        .batch_repeats = 1,
        .min_sample_ns = 1_000_000,
    }, workload);
    result.print(@tagName(phase));
    const memory_after = db.stat();
    std.debug.print("  internal allocation requests during measurement: {d}; retained bytes: {d}\n", .{
        memory_after.allocation_count - memory_before.allocation_count,
        memory_after.allocated_bytes,
    });

    if (phase == .seed or phase == .overwrite or phase == .collections_seed or phase == .gc) try db.flush();
    try db.close();
}
