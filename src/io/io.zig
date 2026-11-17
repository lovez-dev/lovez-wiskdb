//! Positional I/O helpers and persistence barriers. Callers control buffering,
//! rotation, sync scheduling and corruption handling.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

pub const File = Io.File;
pub const Dir = Io.Dir;

/// Short read: EOF before `buffer.len` was filled. Callers map it to their
/// domain error: truncated log tail, torn edit, short block, or dangling file.
pub const ReadError = error{UnexpectedEof} || Io.File.ReadPositionalError;

/// Read exactly `buffer.len` bytes at `offset`, or return UnexpectedEof.
pub fn preadAll(file: File, io: Io, buffer: []u8, offset: u64) ReadError!void {
    const n = try file.readPositionalAll(io, buffer, offset);
    if (n != buffer.len) return error.UnexpectedEof;
}

/// Write every byte at `offset` (std loops internally until done or errors).
pub fn pwriteAll(file: File, io: Io, bytes: []const u8, offset: u64) Io.File.WritePositionalError!void {
    if (comptime builtin.is_test) {
        if (TestWrite.target) |target| if (target != file.handle) return try file.writePositionalAll(io, bytes, offset);
        const call = TestWrite.calls;
        TestWrite.calls += 1;
        if (call == TestWrite.fail_at) return error.InputOutput;
    }
    try file.writePositionalAll(io, bytes, offset);
}

/// fsync this file's data+metadata (directory fsync is a separate concern).
pub fn fsync(file: File, io: Io) Io.File.SyncError!void {
    if (comptime builtin.is_test) {
        if (TestSync.target) |target| if (target == file.handle) {
            const call = TestSync.calls;
            TestSync.calls += 1;
            if (call == TestSync.fail_at) return error.InputOutput;
        };
    }
    try file.sync(io);
}

/// Windows directory handles cannot be flushed through the current std.Io
/// backend. Report that boundary; strict callers must reject compatibility mode.
pub const DirectorySync = enum { synced, unsupported };
pub const directory_sync_supported = switch (builtin.os.tag) {
    .linux, .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

/// Thread-local fault injection, compiled only into test binaries. A matching
/// barrier failure is independent of host capability so Windows can exercise
/// the post-rename uncertainty path without claiming a real directory flush.
pub const TestBarrier = if (builtin.is_test) struct {
    pub threadlocal var target: ?Dir.Handle = null;
    pub threadlocal var fail_at: usize = 0;
    pub threadlocal var calls: usize = 0;
} else struct {};
/// Test-only positional-write fault injection. A target limits failures to
/// one file so output SST and WAL writes cannot disturb manifest tests.
pub const TestWrite = if (builtin.is_test) struct {
    pub threadlocal var target: ?File.Handle = null;
    pub threadlocal var fail_at: usize = std.math.maxInt(usize);
    pub threadlocal var calls: usize = 0;
} else struct {};
pub const TestSync = if (builtin.is_test) struct {
    pub threadlocal var target: ?File.Handle = null;
    pub threadlocal var fail_at: usize = std.math.maxInt(usize);
    pub threadlocal var calls: usize = 0;
} else struct {};

pub const DirectorySyncError = File.OpenError || File.SyncError;

pub fn syncDirectory(dir: Dir, io: Io) DirectorySyncError!DirectorySync {
    if (comptime builtin.is_test) {
        if (TestBarrier.target) |target| if (target == dir.handle) {
            const call = TestBarrier.calls;
            TestBarrier.calls += 1;
            if (call == TestBarrier.fail_at) return error.InputOutput;
        };
    }
    if (comptime !directory_sync_supported) return .unsupported;
    // Dir handles may use O_PATH (or AT_FDCWD), neither can be fsynced.
    // Open a real read-only directory file through std.Io, leaving the
    // caller's handle and directory iterator position untouched.
    const file = try dir.openFile(io, ".", .{ .allow_directory = true, .path_only = false });
    defer file.close(io);
    try file.sync(io);
    return .synced;
}

/// Rename across two dirs; the standard way to switch a file atomically.
pub fn rename(from: Dir, from_path: []const u8, to: Dir, to_path: []const u8, io: Io) Io.Dir.RenameError!void {
    try from.rename(from_path, to, to_path, io);
}

pub fn unlink(dir: Dir, io: Io, path: []const u8) Io.Dir.DeleteFileError!void {
    try dir.deleteFile(io, path);
}

test "preadAll reads exactly; a short read surfaces UnexpectedEof" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "rw.bin", .{ .read = true });
    defer file.close(io);
    try pwriteAll(file, io, &.{ 1, 2, 3, 4 }, 0);

    var buf: [4]u8 = undefined;
    try preadAll(file, io, &buf, 0);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &buf);

    // Requesting 4 bytes from offset 2 hits EOF after 2 → short read.
    try std.testing.expectError(error.UnexpectedEof, preadAll(file, io, &buf, 2));
}

test "directory barrier: reports platform capability without consuming the directory handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try syncDirectory(tmp.dir, std.testing.io);
    try std.testing.expectEqual(if (directory_sync_supported) DirectorySync.synced else DirectorySync.unsupported, result);
    const file = try tmp.dir.createFile(std.testing.io, "still-open", .{});
    file.close(std.testing.io);
}

test "directory barrier: accepts path-only directory handles" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_only = try tmp.dir.openDir(io, ".", .{ .iterate = false });
    defer path_only.close(io);
    const result = try syncDirectory(path_only, io);
    try std.testing.expectEqual(if (directory_sync_supported) DirectorySync.synced else DirectorySync.unsupported, result);
    const file = try path_only.createFile(io, "still-usable", .{});
    file.close(io);
}

test "directory barrier: accepts the process cwd pseudo-handle" {
    const result = try syncDirectory(Dir.cwd(), std.testing.io);
    try std.testing.expectEqual(if (directory_sync_supported) DirectorySync.synced else DirectorySync.unsupported, result);
}
