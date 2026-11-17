//! Append-only WAL file: frame append, fsync, and rollback-to-offset.

const std = @import("std");
const disk = @import("../io/io.zig");
const Io = std.Io;
const crc = @import("../util/crc.zig");
const coding = @import("../util/coding.zig");
const wf = @import("format.zig");
const FrameType = wf.FrameType;
const frame_header_len = wf.frame_header_len;
const max_payload_len = wf.max_payload_len;
const encodeHeader = wf.encodeHeader;

/// One WAL file. After an append error, callers must stop writing or truncate
/// to a known batch boundary before appending again.
pub const Wal = struct {
    file: disk.File,
    end: u64,
    directory_dirty: bool,

    /// Fresh file for a new generation; `exclusive` refuses to clobber an
    /// existing one (generation numbers must make that impossible anyway).
    pub fn create(dir: disk.Dir, io: Io, name: []const u8) disk.File.OpenError!Wal {
        const file = try dir.createFile(io, name, .{ .read = true, .exclusive = true });
        return .{ .file = file, .end = 0, .directory_dirty = true };
    }

    /// Recovery validates frame checksums and discards incomplete batch tails.
    pub fn append(self: *Wal, io: Io, frame_type: FrameType, payload: []const u8) Io.File.WritePositionalError!void {
        std.debug.assert(payload.len > 0 and payload.len <= max_payload_len);
        var hdr: [frame_header_len]u8 = undefined;
        encodeHeader(&hdr, frame_type, @intCast(payload.len), crc.crc32(payload));
        // Small frames trade a bounded copy for one fewer file call.
        // Keep large payloads streaming so stack usage stays bounded.
        var record: [4096]u8 = undefined;
        if (payload.len <= record.len - frame_header_len) {
            @memcpy(record[0..frame_header_len], &hdr);
            @memcpy(record[frame_header_len..][0..payload.len], payload);
            try disk.pwriteAll(self.file, io, record[0 .. frame_header_len + payload.len], self.end);
        } else {
            try disk.pwriteAll(self.file, io, &hdr, self.end);
            try disk.pwriteAll(self.file, io, payload, self.end + frame_header_len);
        }
        self.end += frame_header_len + payload.len;
    }

    pub fn appendSynced(self: *Wal, io: Io, synced_seq: u64) Io.File.WritePositionalError!void {
        var buf: [8]u8 = undefined;
        coding.putU64(&buf, synced_seq);
        try self.append(io, .synced, &buf);
    }

    pub fn sync(self: *Wal, io: Io) Io.File.SyncError!void {
        try disk.fsync(self.file, io);
    }

    pub fn syncDirectoryIfDirty(self: *Wal, dir: disk.Dir, io: Io) disk.DirectorySyncError!void {
        if (!self.directory_dirty) return;
        _ = try disk.syncDirectory(dir, io);
        self.directory_dirty = false;
    }

    /// Rollback point for a failed append; runs under `write_mutex`, so no
    /// other batch can slip in between the failure and the truncation.
    pub fn truncateTo(self: *Wal, io: Io, new_end: u64) Io.File.SetLengthError!void {
        try self.file.setLength(io, new_end);
        self.end = new_end;
    }

    pub fn close(self: *Wal, io: Io) void {
        self.file.close(io);
    }
};

test "writer: WAL directory sync is one-shot until a new file is created" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wal = try Wal.create(tmp.dir, io, "000001.wal");
    defer wal.close(io);
    disk.TestBarrier.target = tmp.dir.handle;
    disk.TestBarrier.calls = 0;
    disk.TestBarrier.fail_at = std.math.maxInt(usize);
    defer disk.TestBarrier.target = null;
    try wal.syncDirectoryIfDirty(tmp.dir, io);
    try std.testing.expectEqual(@as(usize, 1), disk.TestBarrier.calls);
    try wal.syncDirectoryIfDirty(tmp.dir, io);
    try std.testing.expectEqual(@as(usize, 1), disk.TestBarrier.calls);
}
