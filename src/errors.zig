//! Single flat error set: every public API returns a subset of `Error`.
//! Std I/O errors are folded in; internal helpers may narrow further.

const std = @import("std");
const Io = std.Io;

/// Every std I/O error the io layer is allowed to return, folded in one set.
pub const IoErrors = Io.File.OpenError ||
    Io.File.ReadPositionalError ||
    Io.File.WritePositionalError ||
    Io.File.SyncError ||
    Io.Dir.RenameError ||
    Io.Dir.DeleteFileError ||
    Io.Dir.CreateFileAtomicError;

pub const Error = error{
    // Open
    DbLocked,
    RecoveryFlushFailed,
    UnsupportedDirectorySync,
    PublicationUncertain,
    InvalidOptions,
    UnsupportedFormatVersion,
    ManifestCorrupted,
    DbIdMismatch,
    // Read
    NotFound,
    BlockCorrupted,
    SSTableCorrupted,
    SSTableTooSmall,
    VLogCorrupted,
    FileClosing,
    DbClosed,
    // Write
    KeyTooLarge,
    ValueTooLarge,
    BatchTooLarge,
    WalCorrupted,
    WriteStalled,
    WriteFailed,
    // Handles
    SnapshotBudgetExceeded,
    LeakedHandles,
    // Verification
    VerifyInProgress,
} || IoErrors;

test "flat set contains every contract error" {
    // Typed array literal: a missing name is a compile error on this line,
    // and the values are consumed (error values may not be discarded).
    const all: []const Error = &.{
        error.DbLocked,          error.InvalidOptions,   error.UnsupportedFormatVersion,
        error.ManifestCorrupted, error.DbIdMismatch,     error.NotFound,
        error.BlockCorrupted,    error.SSTableCorrupted, error.SSTableTooSmall,
        error.VLogCorrupted,     error.FileClosing,      error.DbClosed,
        error.KeyTooLarge,       error.ValueTooLarge,    error.BatchTooLarge,
        error.WalCorrupted,      error.WriteStalled,     error.SnapshotBudgetExceeded,
        error.LeakedHandles,     error.VerifyInProgress,
    };
    try std.testing.expect(all.len == 20);
}
