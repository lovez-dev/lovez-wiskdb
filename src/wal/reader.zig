//! WAL read path: frame validation, the tail-vs-mid scan, and batch
//! reassembly for recovery.

const std = @import("std");
const disk = @import("../io/io.zig");
const Io = std.Io;
const crc = @import("../util/crc.zig");
const coding = @import("../util/coding.zig");
const wf = @import("format.zig");
const magic = wf.magic;
const frame_header_len = wf.frame_header_len;
const decodeHeader = wf.decodeHeader;
const FrameType = wf.FrameType;
const wtr = @import("writer.zig");
const Wal = wtr.Wal;

pub const Frame = struct {
    frame_type: FrameType,
    /// Slice into the caller's scratch buffer; valid until the next readFrame.
    payload: []const u8,
    offset: u64,
    next: u64,
};

/// Validate one frame at `at`. Short reads return `UnexpectedEof`; insufficient
/// scratch returns `BatchTooLarge`. I/O errors propagate unchanged.
pub fn readFrame(
    file: disk.File,
    io: Io,
    at: u64,
    scratch: []u8,
) (error{ WalCorrupted, BatchTooLarge } || disk.ReadError)!Frame {
    var hdr: [frame_header_len]u8 = undefined;
    try disk.preadAll(file, io, &hdr, at);
    const h = try decodeHeader(&hdr);
    if (scratch.len < h.payload_len) return error.BatchTooLarge;
    try disk.preadAll(file, io, scratch[0..h.payload_len], at + frame_header_len);
    if (crc.crc32(scratch[0..h.payload_len]) != h.payload_crc) return error.WalCorrupted;
    return .{
        .frame_type = h.frame_type,
        .payload = scratch[0..h.payload_len],
        .offset = at,
        .next = at + frame_header_len + h.payload_len,
    };
}

/// A valid header after `from` distinguishes mid-file corruption from a torn
/// tail. Probe header CRCs without reading each candidate's payload.
pub fn hasValidFrameAfter(file: disk.File, io: Io, from: u64) (error{WalCorrupted} || disk.ReadError || disk.File.LengthError)!bool {
    const size = try file.length(io);
    var pos = from;
    var buf: [4096]u8 = undefined;
    while (pos < size) {
        const want: usize = @min(buf.len, size - pos);
        const n = try file.readPositionalAll(io, buf[0..want], pos);
        if (n == 0) return false;
        var scan: usize = 0;
        while (std.mem.indexOfPos(u8, buf[0..n], scan, magic)) |m| {
            var hdr: [frame_header_len]u8 = undefined;
            disk.preadAll(file, io, &hdr, pos + m) catch |e| switch (e) {
                error.UnexpectedEof => break, // pattern runs past EOF: not a frame
                else => return e,
            };
            _ = decodeHeader(&hdr) catch {
                scan = m + 1;
                continue;
            };
            return true;
        }
        if (n < want) return false; // short read: file ended
        // Keep the last 3 bytes — a magic can straddle the block boundary.
        pos += if (n > 3) n - 3 else n;
    }
    return false;
}

pub const Item = union(enum) { batch: []const u8, synced: u64 };

pub const ReplayError = error{ WalCorrupted, BatchTooLarge } || disk.ReadError || disk.File.LengthError;

/// Pull-style replay: complete WriteBatches in order plus SYNCED watermarks.
/// A structural break or a CRC failure stops the stream the same way — if a
/// valid frame follows, that is mid-file corruption (`WalCorrupted`, refuse to
/// start); otherwise it is a torn tail and `truncate_at` marks where recovery
/// cuts back, always a complete-batch boundary.
pub const Replay = struct {
    file: disk.File,
    /// Caller-owned reassembly buffer: one whole batch must fit in it.
    buf: []u8,
    pos: u64 = 0,
    synced_seq: u64 = 0,
    truncate_at: u64 = 0,
    have: usize = 0,
    pending: bool = false,
    batch_start: u64 = 0,

    pub fn init(file: disk.File, buf: []u8) Replay {
        return .{ .file = file, .buf = buf };
    }

    /// Next item, or null at a clean end (check `truncate_at` then).
    pub fn next(self: *Replay, io: Io) ReplayError!?Item {
        while (true) {
            // Payloads land right after the bytes already assembled, so a
            // full buffer turns into BatchTooLarge inside readFrame.
            const f = readFrame(self.file, io, self.pos, self.buf[self.have..]) catch |e| switch (e) {
                error.UnexpectedEof, error.WalCorrupted => return self.cleanEnd(io),
                else => return e,
            };
            switch (f.frame_type) {
                .synced => {
                    if (f.payload.len != 8) return error.WalCorrupted; // contract, not a limit
                    self.synced_seq = coding.getU64(f.payload[0..8]); // len==8 checked above
                    self.pos = f.next;
                    self.truncate_at = f.next;
                    return .{ .synced = self.synced_seq };
                },
                .full => {
                    if (self.pending) return self.cleanEnd(io);
                    self.pos = f.next;
                    self.truncate_at = f.next;
                    return .{ .batch = f.payload };
                },
                .first => {
                    if (self.pending) return self.cleanEnd(io);
                    self.batch_start = f.offset;
                    self.have = f.payload.len;
                    self.pending = true;
                    self.pos = f.next;
                },
                .middle, .last => {
                    if (!self.pending) return self.cleanEnd(io);
                    self.have += f.payload.len;
                    self.pos = f.next;
                    if (f.frame_type == .last) {
                        self.pending = false;
                        const batch = self.buf[0..self.have];
                        self.have = 0;
                        self.truncate_at = f.next;
                        return .{ .batch = batch };
                    }
                },
            }
        }
    }

    /// The stream ends here — or the file is really corrupt: a LATER frame
    /// that validates proves mid-file corruption; nothing after means a torn
    /// tail, and `truncate_at` already marks the complete-batch boundary.
    fn cleanEnd(self: *Replay, io: Io) ReplayError!?Item {
        // +1 skips this frame's own magic — its header may well validate.
        if (try hasValidFrameAfter(self.file, io, self.pos + 1)) return error.WalCorrupted;
        return null;
    }
};

fn expectBatch(expected: []const u8, item: Item) !void {
    switch (item) {
        .batch => |b| try std.testing.expectEqualStrings(expected, b),
        .synced => try std.testing.expect(false),
    }
}

fn expectSynced(expected: u64, item: Item) !void {
    switch (item) {
        .synced => |s| try std.testing.expectEqual(expected, s),
        .batch => try std.testing.expect(false),
    }
}

test "replay: full and split batches plus the synced watermark" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var wal = try Wal.create(tmp.dir, io, "w0");
    defer wal.close(io);

    try wal.append(io, .full, "B0");
    try wal.append(io, .first, "B1-a");
    try wal.append(io, .middle, "B1-b");
    try wal.append(io, .last, "B1-c");
    try wal.appendSynced(io, 7);
    try wal.append(io, .full, "B2");

    var rbuf: [128]u8 = undefined;
    var rp = Replay.init(wal.file, &rbuf);
    try expectBatch("B0", (try rp.next(io)).?);
    try expectBatch("B1-aB1-bB1-c", (try rp.next(io)).?);
    try expectSynced(7, (try rp.next(io)).?);
    try expectBatch("B2", (try rp.next(io)).?);
    try std.testing.expect((try rp.next(io)) == null);
    try std.testing.expectEqual(@as(u64, 7), rp.synced_seq);
    try std.testing.expectEqual(wal.end, rp.truncate_at); // clean end sits at EOF
}

test "a torn tail ends clean; a mid-file break refuses to start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Scenario 1: cut into the last batch's payload — clean end, cut back.
    var w0 = try Wal.create(tmp.dir, io, "w0");
    defer w0.close(io);
    try w0.append(io, .full, "A");
    const after_a = w0.end;
    try w0.append(io, .full, "BB");
    try w0.truncateTo(io, w0.end - 5);

    var rbuf: [64]u8 = undefined;
    var rp = Replay.init(w0.file, &rbuf);
    try expectBatch("A", (try rp.next(io)).?);
    try std.testing.expect((try rp.next(io)) == null);
    try std.testing.expectEqual(after_a, rp.truncate_at);

    // Scenario 2: corrupt A's payload while BB still validates after it.
    var w1 = try Wal.create(tmp.dir, io, "w1");
    defer w1.close(io);
    try w1.append(io, .full, "A");
    try w1.append(io, .full, "BB");
    try disk.pwriteAll(w1.file, io, &.{0xFF}, 15); // first payload byte
    var rp1 = Replay.init(w1.file, &rbuf);
    try std.testing.expectError(error.WalCorrupted, rp1.next(io));
}

test "structural break: corrupt only when a valid frame follows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // FIRST then FULL then FULL: the middle frame breaks the sequence and
    // the third proves it is mid-file — refuse to start.
    var w0 = try Wal.create(tmp.dir, io, "w0");
    defer w0.close(io);
    try w0.append(io, .first, "x");
    try w0.append(io, .full, "y");
    try w0.append(io, .full, "z");
    var rbuf: [64]u8 = undefined;
    var rp = Replay.init(w0.file, &rbuf);
    try std.testing.expectError(error.WalCorrupted, rp.next(io));

    // Same break with nothing after it is just a torn tail: truncate the
    // dangling FIRST away at the boundary before it.
    // Same break with nothing after it is just a torn tail: a complete batch
    // up front makes the cut point observable — the dangling FIRST (and the
    // FULL after it) all get truncated away.
    var w1 = try Wal.create(tmp.dir, io, "w1");
    defer w1.close(io);
    try w1.append(io, .full, "keep");
    const boundary = w1.end;
    try w1.append(io, .first, "dangle");
    try w1.append(io, .full, "y");
    var rp1 = Replay.init(w1.file, &rbuf);
    try expectBatch("keep", (try rp1.next(io)).?);
    try std.testing.expect((try rp1.next(io)) == null);
    try std.testing.expectEqual(boundary, rp1.truncate_at);
}

test "BatchTooLarge when a split batch outruns the reassembly buffer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var wal = try Wal.create(tmp.dir, io, "w0");
    defer wal.close(io);

    const a: [100]u8 = @splat('a');
    const b: [50]u8 = @splat('b');
    try wal.append(io, .first, &a);
    try wal.append(io, .last, &b);

    var rbuf: [100]u8 = undefined; // fits the FIRST, not FIRST+LAST
    var rp = Replay.init(wal.file, &rbuf);
    try std.testing.expectError(error.BatchTooLarge, rp.next(io));
}

test "crash points: every truncation replays a strict batch prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var wal = try Wal.create(tmp.dir, io, "w0");
    defer wal.close(io);

    try wal.append(io, .full, "B0");
    try wal.append(io, .first, "B1a");
    try wal.append(io, .middle, "B1b");
    try wal.append(io, .last, "B1c");
    try wal.appendSynced(io, 5);
    try wal.append(io, .full, "B2");
    try wal.append(io, .first, "B3a");
    try wal.append(io, .last, "B3b");
    const total = wal.end;

    const expected = [_][]const u8{ "B0", "B1aB1bB1c", "B2", "B3aB3b" };
    var rbuf: [64]u8 = undefined;

    // Descending cuts only ever remove bytes, so each pass replays a shorter
    // prefix of the real file — the exact set of crash points.
    var cut: u64 = total + 1;
    while (cut > 0) {
        cut -= 1;
        try wal.truncateTo(io, cut);
        var rp = Replay.init(wal.file, &rbuf);
        var got: usize = 0;
        while ((try rp.next(io))) |item| {
            switch (item) {
                .batch => |b| {
                    try std.testing.expect(got < expected.len);
                    try std.testing.expectEqualStrings(expected[got], b);
                    got += 1;
                },
                .synced => |s| try std.testing.expectEqual(@as(u64, 5), s),
            }
        }
        try std.testing.expect(rp.truncate_at <= cut);
        if (rp.synced_seq != 0) try std.testing.expect(got >= 2); // sits after B1
    }
}
