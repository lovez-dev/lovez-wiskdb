//! Manifest recovery: read CURRENT for the manifest name, fall back to
//! the largest MANIFEST-* when CURRENT is unusable, then replay framed
//! edits into a VersionSet. A frame-level failure is a torn tail and
//! stops the replay; a payload that checksums but breaks the prev-crc
//! chain or fails to decode is corruption and refuses to open.

const std = @import("std");
const mf = @import("format.zig");
const mw = @import("writer.zig");
const vs_mod = @import("version_set.zig");
const disk = @import("../io/io.zig");
const crc = @import("../util/crc.zig");

pub const VersionSet = vs_mod.VersionSet;

/// A directory opened with `iterate = true` is required: fallback scans
/// for MANIFEST-* entries.
pub fn recover(allocator: std.mem.Allocator, io: std.Io, dir: disk.Dir) !Recovery {
    var vs = VersionSet.init(allocator);
    errdefer vs.deinit();
    var tail: mw.Tail = .{};

    var cands: [2]?[]u8 = .{ null, null };
    defer for (cands) |c| if (c) |n| allocator.free(n);

    cands[0] = readCurrent(allocator, dir, io) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => null, // missing or malformed CURRENT: go find the largest
    };
    if (try largestManifestNumber(dir, io)) |num| {
        var buf: [64]u8 = undefined;
        const name = mw.fileName(num, &buf);
        if (cands[0] == null or !std.mem.eql(u8, cands[0].?, name)) {
            cands[1] = try allocator.dupe(u8, name);
        }
    }

    var last_err: error{ NotFound, ManifestCorrupted } = error.NotFound; // exactly what the loop below can store
    for (cands, 0..) |mc, i| {
        const cname = mc orelse continue;
        if (replayInto(allocator, io, dir, cname, &vs, &tail)) {
            const taken = cands[i];
            cands[i] = null;
            return .{
                .vs = vs,
                .manifest_name = taken.?,
                .used_fallback = i != 0,
                .tail = tail,
            };
        } else |e| switch (e) {
            error.NotFound, error.ManifestCorrupted => {
                vs.deinit(); // a failed candidate may have applied a prefix
                vs = VersionSet.init(allocator);
                tail = .{};
                last_err = if (e == error.NotFound) error.NotFound else error.ManifestCorrupted; // switch arms don't narrow e's type
            },
            else => return e, // version/comparator gates refuse the open
        }
    }
    return last_err;
}

pub const Recovery = struct {
    vs: VersionSet,
    manifest_name: []u8,
    used_fallback: bool,
    tail: mw.Tail,

    pub fn deinit(self: *Recovery, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_name);
        self.vs.deinit();
    }
};

pub fn readCurrent(allocator: std.mem.Allocator, dir: disk.Dir, io: std.Io) ![]u8 {
    const f = dir.openFile(io, mw.current_name, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return error.NotFound,
        else => return e,
    };
    defer f.close(io);
    const size = try f.length(io);
    if (size > 4096) return error.ManifestCorrupted;
    var buf: [4096]u8 = undefined;
    try disk.preadAll(f, io, buf[0..size], 0);
    const name = std.mem.trim(u8, buf[0..size], " \t\r\n");
    if (parseManifestName(name) == null) return error.ManifestCorrupted;
    return try allocator.dupe(u8, name);
}

fn parseManifestName(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, mw.file_prefix)) return null;
    const rest = name[mw.file_prefix.len..];
    if (rest.len == 0) return null;
    return std.fmt.parseInt(u64, rest, 10) catch null;
}

fn largestManifestNumber(dir: disk.Dir, io: std.Io) !?u64 {
    var it = dir.iterate();
    var best: ?u64 = null;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const num = parseManifestName(entry.name) orelse continue;
        if (best == null or num > best.?) best = num;
    }
    return best;
}

fn replayInto(allocator: std.mem.Allocator, io: std.Io, dir: disk.Dir, name: []const u8, vs: *VersionSet, tail_out: *mw.Tail) !void {
    const f = dir.openFile(io, name, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return error.NotFound,
        else => return e,
    };
    defer f.close(io);
    const size = try f.length(io);
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    try disk.preadAll(f, io, bytes, 0);

    var running: u32 = 0;
    var first = true;
    var pos: usize = 0;
    var committed_end: usize = 0;
    var acc: std.ArrayListUnmanaged(u8) = .empty;
    defer acc.deinit(allocator);

    while (pos < bytes.len) {
        const h = mf.decodeHeader(bytes[pos..]) catch break; // torn tail
        if (pos + mf.frame_header_len + h.payload_len > bytes.len) break; // torn tail
        pos += mf.frame_header_len;
        const chunk = bytes[pos .. pos + h.payload_len];
        pos += h.payload_len;
        if (crc.crc32(chunk) != h.payload_crc) break; // torn tail
        switch (h.frame_type) {
            .full => {
                try consume(allocator, vs, chunk, &running, &first);
                committed_end = pos;
            },
            .first => {
                acc.clearRetainingCapacity();
                try acc.appendSlice(allocator, chunk);
            },
            .middle => {
                if (acc.items.len == 0) break; // stray middle: treat as tail
                try acc.appendSlice(allocator, chunk);
            },
            .last => {
                if (acc.items.len == 0) break; // stray last: treat as tail
                try acc.appendSlice(allocator, chunk);
                try consume(allocator, vs, acc.items, &running, &first);
                acc.clearRetainingCapacity();
                committed_end = pos;
            },
        }
    }
    // An incomplete first snapshot is not an empty database.
    if (first) return error.ManifestCorrupted;
    tail_out.* = .{ .offset = committed_end, .prev_crc = running };
}

fn consume(allocator: std.mem.Allocator, vs: *VersionSet, payload: []const u8, running: *u32, first: *bool) !void {
    var ed = try mf.decode(allocator, payload); // checksum passed: a decode failure is real corruption
    defer ed.deinit(allocator);
    if (ed.prev_edit_crc != running.*) return error.ManifestCorrupted;
    if (first.*) {
        first.* = false;
        const fv = ed.format_version orelse return error.ManifestCorrupted;
        if (fv > mf.current_version) return error.UnsupportedFormatVersion;
    }
    if (ed.comparator) |c| {
        if (!std.mem.eql(u8, c, mf.comparator_name)) return error.InvalidOptions;
    }
    try vs.apply(&ed);
    running.* = crc.crc32(payload);
}

fn writeManifestWith(alloc: std.mem.Allocator, io: std.Io, dir: disk.Dir, number: u64, edits: []const mf.Edit) !void {
    var w = try mw.Writer.create(alloc, io, dir, number);
    defer w.close();
    for (edits) |e| try w.appendEdit(&e);
}

test "manifest recovery: CURRENT names the file and replay rebuilds state" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const add = mf.FileMeta{
        .level = 0,
        .file_id = 8,
        .file_size = 4096,
        .smallest = "aaa",
        .largest = "zzz",
        .min_seq = 1,
        .max_seq = 9,
        .vlog_ids = &.{ 1, 2 },
    };
    const e1 = mf.Edit{
        .log_number = 4,
        .next_file_number = 9,
        .last_sequence = 9,
        .format_version = mf.current_version,
        .adds = &.{add},
    };
    const e2 = mf.Edit{
        .deletes = &.{.{ .level = 0, .file_id = 8 }},
        .last_sequence = 20,
    };
    try writeManifestWith(alloc, io, tmp.dir, 7, &.{ e1, e2 });
    try mw.publishCurrent(io, tmp.dir, "MANIFEST-000007");

    var rec = try recover(alloc, io, tmp.dir);
    defer rec.deinit(alloc);
    try std.testing.expectEqualStrings("MANIFEST-000007", rec.manifest_name);
    try std.testing.expect(!rec.used_fallback);
    try std.testing.expectEqual(@as(u64, 4), rec.vs.log_number);
    try std.testing.expectEqual(@as(u64, 20), rec.vs.last_sequence);
    try std.testing.expectEqual(@as(usize, 0), rec.vs.fileCount(0)); // delete applied
}

test "manifest recovery: a torn trailing frame keeps the effective prefix" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const e1 = mf.Edit{ .last_sequence = 11, .format_version = mf.current_version };
    try writeManifestWith(alloc, io, tmp.dir, 3, &.{e1});
    try mw.publishCurrent(io, tmp.dir, "MANIFEST-000003");

    // crash tore the file mid-header after the valid edit
    const f = try tmp.dir.openFile(io, "MANIFEST-000003", .{ .mode = .read_write });
    const size = try f.length(io);
    var torn: [8]u8 = @splat(0xFF);
    try disk.pwriteAll(f, io, &torn, size);
    f.close(io);

    var rec = try recover(alloc, io, tmp.dir);
    defer rec.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 11), rec.vs.last_sequence);
    try std.testing.expect(!rec.used_fallback);
}

test "manifest recovery: malformed CURRENT falls back to the largest manifest" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const e1 = mf.Edit{ .last_sequence = 55, .format_version = mf.current_version };
    try writeManifestWith(alloc, io, tmp.dir, 1, &.{e1});
    const e2 = mf.Edit{ .last_sequence = 66, .format_version = mf.current_version };
    try writeManifestWith(alloc, io, tmp.dir, 2, &.{e2});

    const cf = try tmp.dir.createFile(io, mw.current_name, .{ .truncate = true });
    try disk.pwriteAll(cf, io, "BOGUS\n", 0);
    cf.close(io);

    var rec = try recover(alloc, io, tmp.dir);
    defer rec.deinit(alloc);
    try std.testing.expect(rec.used_fallback);
    try std.testing.expectEqualStrings("MANIFEST-000002", rec.manifest_name);
    try std.testing.expectEqual(@as(u64, 66), rec.vs.last_sequence);
}

test "manifest recovery: a valid frame with a broken prev-crc chain refuses to open" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const bad = mf.Edit{ .prev_edit_crc = 999, .last_sequence = 1, .format_version = mf.current_version };
    const payload = try mf.encode(alloc, &bad);
    defer alloc.free(payload);

    const f = try tmp.dir.createFile(io, "MANIFEST-000009", .{});
    var hdr: [mf.frame_header_len]u8 = undefined;
    mf.encodeHeader(&hdr, .full, @intCast(payload.len), crc.crc32(payload));
    try disk.pwriteAll(f, io, &hdr, 0);
    try disk.pwriteAll(f, io, payload, mf.frame_header_len);
    f.close(io);

    try std.testing.expectError(error.ManifestCorrupted, recover(alloc, io, tmp.dir));
}

test "manifest recovery: an empty first snapshot refuses to open" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var writer = try mw.Writer.create(alloc, io, tmp.dir, 1);
    writer.close();
    try mw.publishCurrent(io, tmp.dir, "MANIFEST-000001");
    try std.testing.expectError(error.ManifestCorrupted, recover(alloc, io, tmp.dir));
}

test "manifest recovery: incomplete fragmented edits are replaced at the committed boundary" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var writer = try mw.Writer.create(alloc, io, tmp.dir, 1);
    try writer.appendEdit(&.{ .format_version = mf.current_version, .last_sequence = 7 });
    const committed = mw.Tail{ .offset = writer.offset, .prev_crc = writer.prev_crc };
    writer.close();
    try mw.publishCurrent(io, tmp.dir, "MANIFEST-000001");

    const file = try tmp.dir.openFile(io, "MANIFEST-000001", .{ .mode = .read_write });
    var chunk: [2048]u8 = @splat(0x43);
    var header: [mf.frame_header_len]u8 = undefined;
    mf.encodeHeader(&header, .first, chunk.len, crc.crc32(&chunk));
    try disk.pwriteAll(file, io, &header, committed.offset);
    try disk.pwriteAll(file, io, &chunk, committed.offset + header.len);
    mf.encodeHeader(&header, .middle, chunk.len, crc.crc32(&chunk));
    try disk.pwriteAll(file, io, &header, committed.offset + header.len + chunk.len);
    try disk.pwriteAll(file, io, &chunk, committed.offset + 2 * header.len + chunk.len);
    file.close(io);

    {
        var recovered = try recover(alloc, io, tmp.dir);
        defer recovered.deinit(alloc);
        try std.testing.expectEqual(committed.offset, recovered.tail.offset);
        try std.testing.expectEqual(committed.prev_crc, recovered.tail.prev_crc);
        var append = try mw.Writer.openAppend(alloc, io, tmp.dir, recovered.manifest_name, recovered.tail);
        defer append.close();
        try append.appendEdit(&.{ .last_sequence = 8 });
        try std.testing.expectEqual(append.offset, try append.file.length(io));
    }
    var recovered = try recover(alloc, io, tmp.dir);
    defer recovered.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 8), recovered.vs.last_sequence);
}
