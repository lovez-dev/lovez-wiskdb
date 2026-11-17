//! Manifest writer: creates a MANIFEST file, appends each VersionEdit as
//! WKMF frames (splitting above the frame cap), syncs after every edit,
//! and publishes the CURRENT pointer through std's atomic file swap.

const std = @import("std");
const mf = @import("format.zig");
const disk = @import("../io/io.zig");
const crc = @import("../util/crc.zig");

pub const current_name = "CURRENT";
pub const file_prefix = "MANIFEST-";

/// Byte offset and CRC chain state at the last complete manifest edit.
pub const Tail = struct {
    offset: u64 = 0,
    prev_crc: u32 = 0,
};

pub fn fileName(number: u64, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, file_prefix ++ "{d:0>6}", .{number}) catch unreachable;
}

pub const Writer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: disk.File,
    offset: u64 = 0,
    /// crc32 of the last appended payload; the next edit carries it as
    /// prev_edit_crc. The first edit in a fresh file chains from 0.
    prev_crc: u32 = 0,
    edits: u64 = 0,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, dir: disk.Dir, number: u64) !Writer {
        var buf: [64]u8 = undefined;
        const file = try dir.createFile(io, fileName(number, &buf), .{
            .read = true,
            .truncate = true,
            .exclusive = true,
        });
        return .{ .allocator = allocator, .io = io, .file = file };
    }

    /// Open the CURRENT manifest for incremental edits. A torn tail was
    /// ignored by recovery, so appending at the last complete frame keeps
    /// the CRC chain valid and leaves stale bytes unreachable.
    pub fn openAppend(allocator: std.mem.Allocator, io: std.Io, dir: disk.Dir, name: []const u8, tail: Tail) !Writer {
        const file = try dir.openFile(io, name, .{ .mode = .write_only });
        errdefer file.close(io);
        // Recovery may have ignored a torn or stale tail. Drop it before
        // appending so a later replay cannot observe a mixed frame chain.
        try file.setLength(io, tail.offset);
        return .{ .allocator = allocator, .io = io, .file = file, .offset = tail.offset, .prev_crc = tail.prev_crc };
    }

    pub fn appendEdit(self: *Writer, edit: *const mf.Edit) !void {
        var e = edit.*;
        e.prev_edit_crc = self.prev_crc;
        const payload = try mf.encode(self.allocator, &e);
        defer self.allocator.free(payload);
        try self.writeFrames(payload);
        try disk.fsync(self.file, self.io);
        self.prev_crc = crc.crc32(payload);
        self.edits += 1;
    }

    fn writeFrames(self: *Writer, payload: []const u8) !void {
        const cap: usize = mf.max_payload_len;
        if (payload.len <= cap) return self.writeFrame(.full, payload);
        var start: usize = 0;
        while (true) {
            const end = @min(start + cap, payload.len);
            const t: mf.FrameType = if (start == 0)
                .first
            else if (end == payload.len)
                .last
            else
                .middle;
            try self.writeFrame(t, payload[start..end]);
            if (end == payload.len) break;
            start = end;
        }
    }

    fn writeFrame(self: *Writer, frame_type: mf.FrameType, chunk: []const u8) !void {
        var hdr: [mf.frame_header_len]u8 = undefined;
        mf.encodeHeader(&hdr, frame_type, @intCast(chunk.len), crc.crc32(chunk));
        try disk.pwriteAll(self.file, self.io, &hdr, self.offset);
        try disk.pwriteAll(self.file, self.io, chunk, self.offset + mf.frame_header_len);
        self.offset += mf.frame_header_len + chunk.len;
    }

    pub fn close(self: *Writer) void {
        self.file.close(self.io);
    }
};

/// Publish `manifest_name` as the CURRENT pointer: temp file, content
/// sync, atomic rename over the old CURRENT. Always deinit the handle.
pub fn publishCurrent(io: std.Io, dir: disk.Dir, manifest_name: []const u8) !void {
    return publishCurrentWithBarrier(io, dir, manifest_name, SystemBarrier{});
}

const SystemBarrier = struct {
    fn sync(_: SystemBarrier, io: std.Io, dir: disk.Dir) !void {
        _ = try disk.syncDirectory(dir, io);
    }
};

/// The first barrier persists the already-synced manifest's name. The second
/// persists CURRENT's rename. A failure after rename has an uncertain outcome:
/// callers must retain both old inputs and new outputs and stop writing.
fn publishCurrentWithBarrier(io: std.Io, dir: disk.Dir, manifest_name: []const u8, barrier: anytype) !void {
    try barrier.sync(io, dir);
    var af = try dir.createFileAtomic(io, current_name, .{ .replace = true });
    defer af.deinit(io);
    var buf: [96]u8 = undefined;
    const content = std.fmt.bufPrint(&buf, "{s}\n", .{manifest_name}) catch unreachable;
    try disk.pwriteAll(af.file, io, content, 0);
    try disk.fsync(af.file, io);
    try af.replace(io);
    barrier.sync(io, dir) catch return error.PublicationUncertain;
}

fn slurp(alloc: std.mem.Allocator, dir: disk.Dir, io: std.Io, name: []const u8) ![]u8 {
    const f = try dir.openFile(io, name, .{ .mode = .read_only });
    defer f.close(io);
    const size = try f.length(io);
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    try disk.preadAll(f, io, buf, 0);
    return buf;
}

test "manifest writer: framed edits chain prev_crc across appends" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var w = try Writer.create(alloc, io, tmp.dir, 1);
    var e1 = mf.Edit{ .log_number = 4, .format_version = mf.current_version };
    try w.appendEdit(&e1);
    var e2 = mf.Edit{ .last_sequence = 1234 };
    try w.appendEdit(&e2);
    var e3 = mf.Edit{ .vlog_deletes = &.{9} };
    try w.appendEdit(&e3);
    const n_edits = w.edits;
    w.close();

    var namebuf: [64]u8 = undefined;
    const name = fileName(1, &namebuf);
    const bytes = try slurp(alloc, tmp.dir, io, name);
    defer alloc.free(bytes);

    // walk frames, reassemble payloads, verify the chain
    var payloads: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (payloads.items) |p| alloc.free(p);
        payloads.deinit(alloc);
    }
    var acc: std.ArrayListUnmanaged(u8) = .empty;
    defer acc.deinit(alloc);
    var pos: usize = 0;
    while (pos < bytes.len) {
        const h = try mf.decodeHeader(bytes[pos..]);
        pos += mf.frame_header_len;
        const chunk = bytes[pos .. pos + h.payload_len];
        pos += h.payload_len;
        if (crc.crc32(chunk) != h.payload_crc) return error.ManifestCorrupted;
        switch (h.frame_type) {
            .full => try payloads.append(alloc, try alloc.dupe(u8, chunk)),
            .first => {
                acc.clearRetainingCapacity();
                try acc.appendSlice(alloc, chunk);
            },
            .middle, .last => try acc.appendSlice(alloc, chunk),
        }
        if (h.frame_type == .last) try payloads.append(alloc, try acc.toOwnedSlice(alloc));
    }
    try std.testing.expectEqual(@as(u64, 3), n_edits);
    try std.testing.expectEqual(@as(usize, 3), payloads.items.len);

    var prev: u32 = 0;
    for (payloads.items, 0..) |p, i| {
        var ed = try mf.decode(alloc, p);
        defer ed.deinit(alloc);
        try std.testing.expectEqual(prev, ed.prev_edit_crc);
        prev = crc.crc32(p);
        switch (i) {
            0 => try std.testing.expectEqual(@as(u64, 4), ed.log_number.?),
            1 => try std.testing.expectEqual(@as(u64, 1234), ed.last_sequence.?),
            2 => try std.testing.expectEqual(@as(usize, 1), ed.vlog_deletes.len),
            else => unreachable,
        }
    }
}

test "manifest writer: an oversized edit splits into FIRST..LAST frames" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dels = try alloc.alloc(mf.DeleteFile, 3000);
    defer alloc.free(dels);
    for (dels, 0..) |*d, i| d.* = .{ .level = 0, .file_id = @intCast(i) };
    const big = mf.Edit{ .deletes = dels };

    var w = try Writer.create(alloc, io, tmp.dir, 2);
    try w.appendEdit(&big);
    const n = w.edits;
    w.close();
    try std.testing.expectEqual(@as(u64, 1), n);

    var namebuf: [64]u8 = undefined;
    const bytes = try slurp(alloc, tmp.dir, io, fileName(2, &namebuf));
    defer alloc.free(bytes);

    var types: std.ArrayListUnmanaged(mf.FrameType) = .empty;
    defer types.deinit(alloc);
    var acc: std.ArrayListUnmanaged(u8) = .empty;
    defer acc.deinit(alloc);
    var pos: usize = 0;
    while (pos < bytes.len) {
        const h = try mf.decodeHeader(bytes[pos..]);
        pos += mf.frame_header_len;
        try acc.appendSlice(alloc, bytes[pos .. pos + h.payload_len]);
        pos += h.payload_len;
        try types.append(alloc, h.frame_type);
    }
    try std.testing.expect(types.items.len >= 2); // 3000 deletes exceed one frame
    try std.testing.expectEqual(mf.FrameType.first, types.items[0]);
    try std.testing.expectEqual(mf.FrameType.last, types.items[types.items.len - 1]);
    for (types.items[1 .. types.items.len - 1]) |t| {
        try std.testing.expectEqual(mf.FrameType.middle, t);
    }

    var ed = try mf.decode(alloc, acc.items);
    defer ed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3000), ed.deletes.len);
    try std.testing.expectEqual(@as(u64, 2999), ed.deletes[2999].file_id);
}

test "manifest writer: publishCurrent swaps CURRENT atomically twice" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var namebuf: [64]u8 = undefined;
    const name1 = fileName(1, &namebuf);
    try publishCurrent(io, tmp.dir, name1);

    var namebuf2: [64]u8 = undefined;
    const name2 = fileName(2, &namebuf2);
    try publishCurrent(io, tmp.dir, name2); // replace path over an existing CURRENT

    const raw = try slurp(alloc, tmp.dir, io, current_name);
    defer alloc.free(raw);
    var expect_buf: [96]u8 = undefined;
    const expect_line = try std.fmt.bufPrint(&expect_buf, "{s}\n", .{name2});
    try std.testing.expectEqualSlices(u8, expect_line, raw);
}

test "CURRENT: barriers before and after rename distinguish unchanged from uncertain publication" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    for ([_]usize{ 0, 1 }) |failure| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try publishCurrent(io, tmp.dir, "MANIFEST-000001");
        disk.TestBarrier.target = tmp.dir.handle;
        disk.TestBarrier.calls = 0;
        disk.TestBarrier.fail_at = failure;
        {
            defer disk.TestBarrier.target = null;
            try std.testing.expectError(if (failure == 0) error.InputOutput else error.PublicationUncertain, publishCurrent(io, tmp.dir, "MANIFEST-000002"));
        }
        const bytes = try slurp(alloc, tmp.dir, io, "CURRENT");
        defer alloc.free(bytes);
        try std.testing.expectEqualStrings(if (failure == 0) "MANIFEST-000001\n" else "MANIFEST-000002\n", bytes);
    }
}
