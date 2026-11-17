const std = @import("std");
const w = @import("wiskdb");
const Worker = struct {
    db: *w.Db,
    id: u8,
    failure: ?anyerror = null,
    fn run(self: *Worker) void {
        self.exercise() catch |err| {
            self.failure = err;
        };
    }
    fn exercise(self: *Worker) !void {
        var value: [4096]u8 = undefined;
        for (0..2000) |i| {
            const key = [2]u8{ self.id, @intCast(i % 128) };
            @memset(&value, @intCast(i % 251));
            try self.db.put(&key, &value);
            const got = (try self.db.get(&key)) orelse return error.MissingKey;
            defer self.db.allocator.free(got);
            if (!std.mem.eql(u8, &value, got)) return error.WrongValue;
            if (i % 3 == 0) {
                try self.db.delete(&key);
                if (try self.db.get(&key)) |unexpected| {
                    self.db.allocator.free(unexpected);
                    return error.UnexpectedValue;
                }
            }
            if (i % 500 == 0) try self.db.collectGarbage();
        }
    }
};
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedPathAndRounds;
    const rounds = try std.fmt.parseInt(usize, args[2], 10);
    var operations: usize = 0;
    for (0..rounds) |round| {
        var db = try w.Open(init.gpa, init.io, args[1], .{ .create_if_missing = true, .db = .{
            .write_buffer_size = 65536,
            .max_immutable_count = 2,
            .l0_compaction_trigger = 2,
            .vlog_file_size = 1048576,
        } });
        {
            defer db.deinit();
            var workers: [4]Worker = undefined;
            var threads: [4]std.Thread = undefined;
            var started: usize = 0;
            {
                defer for (threads[0..started]) |thread| thread.join();
                for (&workers, 0..) |*worker, id| {
                    worker.* = .{ .db = &db, .id = @intCast(id) };
                    threads[id] = try std.Thread.spawn(.{}, Worker.run, .{worker});
                    started += 1;
                }
            }
            for (workers) |worker| if (worker.failure) |err| return err;
            try db.sync();
        }
        var reopened = try w.Open(init.gpa, init.io, args[1], .{});
        defer reopened.deinit();
        for (0..4) |id| for (0..128) |slot| {
            const key = [2]u8{ @intCast(id), @intCast(slot) };
            const last = slot + (1999 - slot) / 128 * 128;
            const got = try reopened.get(&key);
            defer if (got) |v| init.gpa.free(v);
            if (last % 3 == 0) {
                if (got != null) return error.RecoveryUnexpectedValue;
            } else {
                const value = got orelse return error.RecoveryMissingKey;
                if (value.len != 4096) return error.RecoveryWrongLength;
                for (value) |byte| if (byte != last % 251) return error.RecoveryWrongValue;
            }
        };
        operations += 8000;
        std.debug.print("PASS round={d} writes={d} workers=4 reopen_verified=true\n", .{ round + 1, operations });
    }
}
