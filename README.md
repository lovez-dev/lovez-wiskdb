# wiskdb

An embedded key-value database with WiscKey value separation, an LSM tree, and WAL-backed recovery.

## Install

```sh
zig fetch --save "git+https://github.com/lovez-dev/wiskdb#main"
```

```zig
const dep = b.dependency("wiskdb", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("wiskdb", dep.module("wiskdb"));
```

## Use

```zig
const std = @import("std");
const wiskdb = @import("wiskdb");

pub fn main(init: std.process.Init) !void {
    var db = try wiskdb.Open(init.gpa, init.io, "data", .{
        .create_if_missing = true,
        .db = .{ .durability = .sync },
    });
    defer db.deinit();

    try db.put("key", "value");
    if (try db.get("key")) |value| {
        defer init.gpa.free(value);
        std.debug.print("{s}\n", .{value});
    }
    try db.delete("key");
    try db.close();
}
```

The database uses the caller-provided allocator and `std.Io` instance. Values returned by `get` are allocated and must be released by the caller. Close the database before its I/O context and allocator are released.

## Build

```sh
zig build test
zig build test --release=safe
zig build test-api
zig build test-api -Dtest-filter="contract:"
zig build fmt
zig build examples
zig build bench
zig build stress
```

Unit tests live beside implementation modules. Public API contracts and cross-subsystem tests live in `tests/`. The benchmark uses [`zlap`](https://github.com/lovez-dev/zlap).

## License

[MIT](LICENSE)
