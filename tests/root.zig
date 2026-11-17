//! Public API contracts and cross-subsystem integration tests.
//! Import the exported module in each suite, as a downstream consumer does.

test {
    _ = @import("contract/lifecycle.zig");
    _ = @import("contract/batch.zig");
    _ = @import("contract/scan.zig");
    _ = @import("contract/collections.zig");
    _ = @import("integration/maintenance.zig");
}
