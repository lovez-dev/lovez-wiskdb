//! Seeded xorshift64* for skip-list heights and reproducible tests.
//! Not suitable for cryptographic use.

const std = @import("std");

pub const Rand = struct {
    state: u64,

    /// xorshift has the all-zero fixed point; seed 0 swaps to a golden-ratio
    /// constant instead of stalling.
    const golden_ratio: u64 = 0x9E3779B97F4A7C15;

    pub fn init(seed: u64) Rand {
        return .{ .state = if (seed == 0) golden_ratio else seed };
    }

    pub fn next(self: *Rand) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545F4914F6CDD1D;
    }

    /// Uniform in [0, n), n > 0. Rejection sampling: values below
    /// (2^64 mod n) are dropped so the modulo cannot skew the distribution.
    pub fn below(self: *Rand, n: u64) u64 {
        std.debug.assert(n > 0);
        const threshold = (@as(u64, 0) -% n) % n;
        while (true) {
            const v = self.next();
            if (v >= threshold) return v % n;
        }
    }
};

test "identical seeds reproduce; a different seed diverges" {
    var a = Rand.init(42);
    var b = Rand.init(42);
    var c = Rand.init(43);
    for (0..8) |_| {
        const x = a.next();
        try std.testing.expectEqual(x, b.next());
        try std.testing.expect(x != c.next());
    }
}

test "seed 0 never stalls at the zero fixed point" {
    var r = Rand.init(0);
    const first = r.next();
    try std.testing.expect(first != 0);
    try std.testing.expect(first != r.next());
}

test "below stays in range, covers both sides, n=1 is always 0" {
    var r = Rand.init(0xC0FFEE);
    var seen0 = false;
    var seen1 = false;
    for (0..512) |_| {
        const wide = r.below(1000);
        try std.testing.expect(wide < 1000);
        const bit = r.below(2);
        try std.testing.expect(bit < 2);
        if (bit == 0) seen0 = true else seen1 = true;
    }
    try std.testing.expect(seen0 and seen1);
    try std.testing.expectEqual(@as(u64, 0), r.below(1));
}
