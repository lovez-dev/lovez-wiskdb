//! Public database and collection APIs. Keep a database at a stable address
//! during use and finish concurrent calls before closing it. Free get results
//! with the opening allocator; use the matching helpers for scan results.

pub const db = @import("db.zig");
pub const Db = db.Db;
pub const Options = db.Options;
pub const OpenOptions = db.OpenOptions;
/// Path-based open; directory creation is opt-in and the returned Db owns its handle.
pub const Open = db.Db.openPath;
pub const Op = db.Op;
pub const Durability = db.Durability;
pub const ReadStats = db.Db.ReadStats;
pub const ScanOptions = db.Db.ScanOptions;
pub const syncDirectory = @import("io/io.zig").syncDirectory;
pub const DirectorySync = @import("io/io.zig").DirectorySync;
pub const directory_sync_supported = @import("io/io.zig").directory_sync_supported;
pub const errors = @import("errors.zig");
pub const Collections = @import("collections.zig").Collections;

// Internal test discovery.
test {
    _ = @import("scan_view.zig");
    _ = @import("collections_scan.zig");
    _ = @import("collections_key.zig");
    _ = @import("collections_zset.zig");
    _ = @import("collections.zig");
    _ = @import("memory_test.zig");
    _ = @import("errors.zig");
    _ = @import("io/io.zig");
    _ = @import("util/coding.zig");
    _ = @import("util/crc.zig");
    _ = @import("util/varint.zig");
    _ = @import("util/refcount.zig");
    _ = @import("util/rand.zig");
    _ = @import("util/lock_profile.zig");
    _ = @import("util/counting_allocator.zig");
    _ = @import("util/internal_key.zig");
    _ = @import("util/internal_value.zig");
    _ = @import("memtable/skiplist.zig");
    _ = @import("memtable/memtable.zig");
    _ = @import("wal/format.zig");
    _ = @import("wal/writer.zig");
    _ = @import("wal/reader.zig");
    _ = @import("sstable/format.zig");
    _ = @import("sstable/block_builder.zig");
    _ = @import("sstable/block_reader.zig");
    _ = @import("sstable/bloom.zig");
    _ = @import("sstable/table_builder.zig");
    _ = @import("sstable/table_reader.zig");
    _ = @import("manifest/format.zig");
    _ = @import("manifest/version_set.zig");
    _ = @import("manifest/commit.zig");
    _ = @import("manifest/version_set_test.zig");
    _ = @import("manifest/writer.zig");
    _ = @import("manifest/reader.zig");
    _ = @import("vlog/format.zig");
    _ = @import("vlog/writer.zig");
    _ = @import("vlog/reader.zig");
    _ = @import("vlog/manager.zig");
    _ = @import("vlog/gc.zig");
    _ = @import("recovery.zig");
    _ = @import("replay.zig");
    _ = @import("compaction/level.zig");
    _ = @import("compaction/merge.zig");
    _ = @import("bg/worker.zig");
    _ = @import("util/vlog_ids.zig");
    _ = @import("memtable/memtable_list.zig");
    _ = @import("cache/table_cache.zig");
    _ = @import("cache/block_cache.zig");
    _ = @import("db.zig");
    _ = @import("file_ids.zig");
    _ = @import("read.zig");
    _ = @import("write.zig");
    _ = @import("runtime_test.zig");
}
