//! CRC-32/ISO-HDLC with reflected polynomial 0xEDB88320.
//! Persisted checksums use IEEE CRC, not the CRC32C polynomial of x86 CRC32.

const std = @import("std");

pub const Crc32 = struct {
    state: u32 = 0xffffffff,
    pub fn init() Crc32 {
        return .{};
    }
    pub fn update(self: *Crc32, bytes: []const u8) void {
        self.state = updateState(self.state, bytes);
    }
    pub fn final(self: Crc32) u32 {
        return ~self.state;
    }
    pub fn hash(bytes: []const u8) u32 {
        return crc32(bytes);
    }
};

const tables = blk: {
    @setEvalBranchQuota(80000);
    var t: [32][256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| c = (c >> 1) ^ (if (c & 1 != 0) @as(u32, 0xedb88320) else 0);
        t[0][i] = c;
    }
    for (0..256) |i| {
        var c = t[0][i];
        for (1..32) |j| {
            c = (c >> 8) ^ t[0][c & 255];
            t[j][i] = c;
        }
    }
    break :blk t;
};

pub fn crc32(bytes: []const u8) u32 {
    // Tiny headers do not amortize the extra table lookups.
    if (bytes.len < 16) return std.hash.Crc32.hash(bytes);
    return ~updateState(0xffffffff, bytes);
}

/// Combine finalized IEEE CRCs for adjacent byte strings without rereading
/// either input. `len_b` is the length, in bytes, of the second string.
pub fn combine(crc_a: u32, crc_b: u32, len_b: u64) u32 {
    var len = len_b;
    var combined = crc_a;
    var power: usize = 0;
    while (len != 0) : (power += 1) {
        if (len & 1 != 0) combined = matrixTimes(&zero_byte_powers[power], combined);
        len >>= 1;
    }
    return if (len_b == 0) crc_a else combined ^ crc_b;
}

// Entry i advances a CRC by 2^i zero bytes. Precompute the operators so
// combining a value's existing CRC never builds matrices on the write path.
const zero_byte_powers = blk: {
    @setEvalBranchQuota(1000000);
    var one_bit: [32]u32 = undefined;
    one_bit[0] = 0xedb88320;
    var row: u32 = 1;
    for (1..32) |i| {
        one_bit[i] = row;
        row <<= 1;
    }
    var two_bits: [32]u32 = undefined;
    var four_bits: [32]u32 = undefined;
    square(&two_bits, &one_bit);
    square(&four_bits, &two_bits);
    var powers: [64][32]u32 = undefined;
    square(&powers[0], &four_bits);
    for (1..64) |i| square(&powers[i], &powers[i - 1]);
    break :blk powers;
};

fn matrixTimes(matrix: *const [32]u32, vector: u32) u32 {
    var value = vector;
    var i: usize = 0;
    var result: u32 = 0;
    while (value != 0) : (i += 1) {
        if (value & 1 != 0) result ^= matrix[i];
        value >>= 1;
    }
    return result;
}

fn square(square_out: *[32]u32, matrix: *const [32]u32) void {
    for (0..32) |i| square_out[i] = matrixTimes(matrix, matrix[i]);
}

inline fn slice16(c: u32, bytes: *const [16]u8) u32 {
    const x0 = c ^ std.mem.readInt(u32, bytes[0..4], .little);
    const x1 = std.mem.readInt(u32, bytes[4..8], .little);
    const x2 = std.mem.readInt(u32, bytes[8..12], .little);
    const x3 = std.mem.readInt(u32, bytes[12..16], .little);
    return tables[15][x0 & 255] ^ tables[14][(x0 >> 8) & 255] ^ tables[13][(x0 >> 16) & 255] ^ tables[12][x0 >> 24] ^
        tables[11][x1 & 255] ^ tables[10][(x1 >> 8) & 255] ^ tables[9][(x1 >> 16) & 255] ^ tables[8][x1 >> 24] ^
        tables[7][x2 & 255] ^ tables[6][(x2 >> 8) & 255] ^ tables[5][(x2 >> 16) & 255] ^ tables[4][x2 >> 24] ^
        tables[3][x3 & 255] ^ tables[2][(x3 >> 8) & 255] ^ tables[1][(x3 >> 16) & 255] ^ tables[0][x3 >> 24];
}

fn updateState(state: u32, bytes: []const u8) u32 {
    var c = state;
    var i: usize = 0;
    // Small inputs retain the eight-slice path: touching all 32 tables is
    // useful only when a payload amortizes the larger lookup working set.
    if (bytes.len >= 8192) {
        while (bytes.len - i >= 32) : (i += 32) {
            const x0 = c ^ std.mem.readInt(u32, bytes[i + 0 ..][0..4], .little);
            const x1 = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
            const x2 = std.mem.readInt(u32, bytes[i + 8 ..][0..4], .little);
            const x3 = std.mem.readInt(u32, bytes[i + 12 ..][0..4], .little);
            const x4 = std.mem.readInt(u32, bytes[i + 16 ..][0..4], .little);
            const x5 = std.mem.readInt(u32, bytes[i + 20 ..][0..4], .little);
            const x6 = std.mem.readInt(u32, bytes[i + 24 ..][0..4], .little);
            const x7 = std.mem.readInt(u32, bytes[i + 28 ..][0..4], .little);
            c = tables[31][x0 & 255] ^ tables[30][(x0 >> 8) & 255] ^ tables[29][(x0 >> 16) & 255] ^ tables[28][x0 >> 24] ^
                tables[27][x1 & 255] ^ tables[26][(x1 >> 8) & 255] ^ tables[25][(x1 >> 16) & 255] ^ tables[24][x1 >> 24] ^
                tables[23][x2 & 255] ^ tables[22][(x2 >> 8) & 255] ^ tables[21][(x2 >> 16) & 255] ^ tables[20][x2 >> 24] ^
                tables[19][x3 & 255] ^ tables[18][(x3 >> 8) & 255] ^ tables[17][(x3 >> 16) & 255] ^ tables[16][x3 >> 24] ^
                tables[15][x4 & 255] ^ tables[14][(x4 >> 8) & 255] ^ tables[13][(x4 >> 16) & 255] ^ tables[12][x4 >> 24] ^
                tables[11][x5 & 255] ^ tables[10][(x5 >> 8) & 255] ^ tables[9][(x5 >> 16) & 255] ^ tables[8][x5 >> 24] ^
                tables[7][x6 & 255] ^ tables[6][(x6 >> 8) & 255] ^ tables[5][(x6 >> 16) & 255] ^ tables[4][x6 >> 24] ^
                tables[3][x7 & 255] ^ tables[2][(x7 >> 8) & 255] ^ tables[1][(x7 >> 16) & 255] ^ tables[0][x7 >> 24];
        }
        while (bytes.len - i >= 16) : (i += 16) {
            c = slice16(c, bytes[i..][0..16]);
        }
    }
    while (bytes.len - i >= 8) : (i += 8) {
        const low = c ^ std.mem.readInt(u32, bytes[i..][0..4], .little);
        const high = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        c = tables[7][low & 255] ^ tables[6][(low >> 8) & 255] ^ tables[5][(low >> 16) & 255] ^ tables[4][low >> 24] ^
            tables[3][high & 255] ^ tables[2][(high >> 8) & 255] ^ tables[1][(high >> 16) & 255] ^ tables[0][high >> 24];
    }
    while (bytes.len - i >= 4) : (i += 4) {
        c ^= std.mem.readInt(u32, bytes[i..][0..4], .little);
        c = tables[3][c & 255] ^ tables[2][(c >> 8) & 255] ^ tables[1][(c >> 16) & 255] ^ tables[0][c >> 24];
    }
    for (bytes[i..]) |b| c = (c >> 8) ^ tables[0][(c ^ b) & 255];
    return c;
}

test "CRC large-payload threshold preserves streaming and unaligned inputs" {
    var bytes: [8193 + 32]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i *% 47 +% (i >> 3));
    for (0..32) |offset| for ([_]usize{ 8191, 8192, 8193 }) |len| {
        const input = bytes[offset..][0..len];
        const expected = std.hash.Crc32.hash(input);
        try std.testing.expectEqual(expected, crc32(input));
        var stream: Crc32 = .init();
        stream.update(input[0 .. len - 1]);
        stream.update(input[len - 1 ..]);
        try std.testing.expectEqual(expected, stream.final());
    };
}

test "CRC combine matches concatenated input across lengths and splits" {
    var bytes: [8193]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i *% 73 +% (i >> 4));
    for (0..bytes.len + 1) |split| {
        const left = crc32(bytes[0..split]);
        const right = crc32(bytes[split..]);
        try std.testing.expectEqual(crc32(&bytes), combine(left, right, bytes.len - split));
    }
    try std.testing.expectEqual(crc32("prefix"), combine(crc32("prefix"), crc32(""), 0));
}

test "CRC combine handles lengths beyond 32 bits algebraically" {
    // Polynomial multiplication is independent of the matrix implementation.
    const Reference = struct {
        fn multiply(a: u32, b: u32) u32 {
            const factor = a;
            var value = b;
            var result: u32 = 0;
            var mask: u32 = 0x80000000;
            while (mask != 0) : (mask >>= 1) {
                if (factor & mask != 0) result ^= value;
                value = (value >> 1) ^ (if (value & 1 != 0) @as(u32, 0xedb88320) else 0);
            }
            return result;
        }
        fn shift(value: u32, bytes: u64) u32 {
            var len = bytes;
            var power: u32 = 0x00800000; // x^8 in reflected representation
            var factor: u32 = 0x80000000; // multiplicative identity
            while (len != 0) : (len >>= 1) {
                if (len & 1 != 0) factor = multiply(factor, power);
                power = multiply(power, power);
            }
            return multiply(factor, value);
        }
    };
    const left = crc32("left");
    const right = crc32("right");
    for ([_]u64{ 1, 5, 8192, 0xffffffff, 0x100000000, 1 << 40, (1 << 63) + 7, std.math.maxInt(u64) }) |len| {
        try std.testing.expectEqual(Reference.shift(left, len) ^ right, combine(left, right, len));
    }
    try std.testing.expectEqual(right, combine(0, right, 5));
    try std.testing.expectEqual(@as(u32, 0), combine(0, 0, 0));
}

test "CRC random payloads and streaming cuts preserve IEEE results" {
    var bytes: [131103]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xe5eb3dc2);
    const random = prng.random();
    random.bytes(&bytes);
    for (0..256) |_| {
        const offset = random.uintLessThan(usize, 32);
        const len = random.uintLessThan(usize, bytes.len - offset + 1);
        const input = bytes[offset..][0..len];
        const expected = std.hash.Crc32.hash(input);
        try std.testing.expectEqual(expected, crc32(input));
        const cut = random.uintLessThan(usize, len + 1);
        var stream: Crc32 = .init();
        stream.update(input[0..cut]);
        stream.update(input[cut..]);
        try std.testing.expectEqual(expected, stream.final());
        try std.testing.expectEqual(expected, combine(crc32(input[0..cut]), crc32(input[cut..]), len - cut));
    }
}

test "sliced CRC matches standard CRC for unaligned inputs and tails" {
    var bytes: [4100]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i *% 37);
    for (0..4) |offset| for (0..4097) |len| {
        const input = bytes[offset..][0..len];
        try std.testing.expectEqual(std.hash.Crc32.hash(input), crc32(input));
    };
}

test "streaming sliced CRC matches standard across chunk boundaries" {
    var bytes: [1031]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i *% 73);
    for (0..bytes.len + 1) |split| {
        var s: Crc32 = .init();
        s.update(bytes[0..split]);
        s.update("");
        s.update(bytes[split..]);
        try std.testing.expectEqual(std.hash.Crc32.hash(&bytes), s.final());
    }
}

test "canonical check vectors" {
    try std.testing.expectEqual(@as(u32, 0x00000000), crc32(""));
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
    try std.testing.expectEqual(
        @as(u32, 0x414FA339),
        crc32("The quick brown fox jumps over the lazy dog"),
    );
}

test "streaming update equals one-shot hash" {
    var s: Crc32 = .init();
    s.update("1234");
    s.update("56789");
    try std.testing.expectEqual(crc32("123456789"), s.final());
}
