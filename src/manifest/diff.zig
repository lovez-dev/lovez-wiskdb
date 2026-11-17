//! Delta edits between two in-memory versions. Outputs borrow FileMeta
//! payloads from `next`; callers encode before either version is released.
const std = @import("std");
const mf = @import("format.zig");
const VersionSet = @import("version_set.zig").VersionSet;

pub fn deltaEdit(allocator: std.mem.Allocator, old: *const VersionSet, next: *const VersionSet) !mf.Edit {
    var adds: std.ArrayListUnmanaged(mf.FileMeta) = .empty;
    errdefer adds.deinit(allocator);
    var deletes: std.ArrayListUnmanaged(mf.DeleteFile) = .empty;
    errdefer deletes.deinit(allocator);

    var nit = next.by_level.iterator();
    while (nit.next()) |entry| {
        for (entry.value_ptr.items) |file| {
            if (old.findFile(entry.key_ptr.*, file.file_id) == null) {
                try adds.append(allocator, file);
            }
        }
    }
    var oit = old.by_level.iterator();
    while (oit.next()) |entry| {
        for (entry.value_ptr.items) |file| {
            if (next.findFile(entry.key_ptr.*, file.file_id) == null) {
                try deletes.append(allocator, .{ .level = entry.key_ptr.*, .file_id = file.file_id });
            }
        }
    }

    const owned_adds = try adds.toOwnedSlice(allocator);
    errdefer allocator.free(owned_adds);
    const owned_deletes = try deletes.toOwnedSlice(allocator);
    return .{
        .log_number = next.log_number,
        .next_file_number = next.next_file_number,
        .last_sequence = next.last_sequence,
        .db_id = if (old.db_id == null) next.db_id else null,
        .format_version = if (old.format_version == null) next.format_version else null,
        .deletes = owned_deletes,
        .adds = owned_adds,
        .vlog_deletes = next.dead_vlogs.items,
    };
}

pub fn freeEdit(allocator: std.mem.Allocator, edit: *const mf.Edit) void {
    if (edit.adds.len != 0) allocator.free(edit.adds);
    if (edit.deletes.len != 0) allocator.free(edit.deletes);
}
