//! Converts ranges of Unicode scalar values to equivalent ranges of UTF-8 bytes.
//!
//! See https://github.com/rust-lang/regex/blob/master/regex-syntax/src/utf8.rs.

const surrogate: ScalarRange = .{ .from = 0xd800, .to = 0xdfff };
const scalar_max = 0x10ffff;

/// A UTF-8 byte-range sequence for one contiguous set of encoded scalar values.
///
/// Each element is the inclusive byte range accepted at that byte position.
/// For example, Cyrillic U+0400..U+04FF becomes:
///
/// ```
/// [D0-D3] [80-BF]
/// ```
///
/// A sequence always contains 1..4 byte positions.
pub const Sequence = union(enum) {
    one: [1]ByteRange,
    two: [2]ByteRange,
    three: [3]ByteRange,
    four: [4]ByteRange,

    const Self = @This();

    pub fn init(ranges: []const ByteRange) Self {
        assert(ranges.len >= 1 and ranges.len <= 4);
        return switch (ranges.len) {
            1 => .{ .one = .{ranges[0]} },
            2 => .{ .two = .{ ranges[0], ranges[1] } },
            3 => .{ .three = .{ ranges[0], ranges[1], ranges[2] } },
            4 => .{ .four = .{ ranges[0], ranges[1], ranges[2], ranges[3] } },
            else => unreachable,
        };
    }

    /// Returns the exact UTF-8 byte sequence for one valid Unicode scalar value.
    ///
    /// `cp` must be valid for `std.unicode.utf8Encode`.
    pub fn fromCodePoint(cp: u21) Self {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        var ranges: [4]ByteRange = undefined;
        for (buf[0..len], ranges[0..len]) |byte, *range| {
            range.* = .init(byte, byte);
        }
        return .init(ranges[0..len]);
    }

    /// Builds a sequence from already encoded lower and upper UTF-8 bounds:
    /// both bounds must have the same byte length, and each byte in `from`
    /// must be less than or equal to the corresponding byte in `to`.
    pub fn fromEncodedRange(from: []const u8, to: []const u8) Self {
        assert(from.len == to.len);
        assert(from.len >= 1 and from.len <= 4);

        var ranges: [4]ByteRange = undefined;
        for (from, to, 0..) |lo, hi, i| {
            assert(lo <= hi);
            ranges[i] = .init(lo, hi);
        }
        return .init(ranges[0..from.len]);
    }

    pub fn slice(self: *const Self) []const ByteRange {
        return switch (self.*) {
            inline else => |*ranges| ranges[0..],
        };
    }
};

/// Iterator that decomposes one scalar range into UTF-8 byte range sequences.
///
/// The input range may include surrogate code points; they are skipped. Each
/// yielded sequence has byte ranges that can be lowered directly into a chain
/// of byte-range NFA states.
///
/// The iterator uses a fixed stack and performs no allocation.
pub const Sequences = struct {
    /// One scalar range decomposes into at most 21 valid UTF-8 terminal ranges:
    /// 1 one-byte, 3 two-byte, 5 lower three-byte, 5 upper three-byte, and 7
    /// four-byte ranges. Surrogate splitting can add one pending range; 24
    /// leaves room to spare.
    stack: [24]ScalarRange,
    len: usize,

    const Self = @This();

    pub fn init(range: ScalarRange) Self {
        assert(range.inBounds());

        var seqs: Self = .{ .stack = undefined, .len = 0 };
        seqs.push(range);
        return seqs;
    }

    pub fn reset(self: *Self, range: ScalarRange) void {
        assert(range.inBounds());

        self.len = 0;
        self.push(range);
    }

    /// Returns the next UTF-8 byte-range sequence, or null when exhausted.
    ///
    /// The splitting logic ensures a yielded scalar subrange has one UTF-8
    /// length and can be represented by independent byte ranges at each
    /// position.
    pub fn next(self: *Self) ?Sequence {
        var r = self.pop() orelse return null;
        while (true) {
            assert(r.isValid());
            if (splitSurrogates(r)) |split| {
                if (split.right) |right| self.push(.init(right.from, right.to));
                r = split.left orelse self.pop() orelse return null;
                continue;
            }

            for (1..4) |i| {
                const max = maxScalarValue(i);
                if (r.from <= max and max < r.to) {
                    self.push(.init(max + 1, r.to));
                    r.to = max;
                    continue;
                }
            }

            if (r.asAscii()) |br| return .init(&.{br});

            for (1..4) |i| {
                const m = mask(i);
                if ((r.from & ~m) != (r.to & ~m)) {
                    if ((r.from & m) != 0) {
                        self.push(.init((r.from | m) + 1, r.to));
                        r.to = r.from | m;
                        continue;
                    }
                    if ((r.to & m) != m) {
                        self.push(.init(r.to & ~m, r.to));
                        r.to = (r.to & ~m) - 1;
                        continue;
                    }
                }
            }

            var from: [4]u8 = undefined;
            var to: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(r.from, &from) catch unreachable;
            const to_len = std.unicode.utf8Encode(r.to, &to) catch unreachable;
            assert(len == to_len);
            return .fromEncodedRange(from[0..len], to[0..len]);
        }
    }

    fn push(self: *Self, range: ScalarRange) void {
        assert(self.len < self.stack.len);
        self.stack[self.len] = range;
        self.len += 1;
    }

    fn pop(self: *Self) ?ScalarRange {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.stack[self.len];
    }
};

/// Returns a mask for the low `6 * i` payload bits of a UTF-8 scalar value.
///
/// UTF-8 continuation bytes carry 6 payload bits, so this is used to split
/// ranges on boundaries where lower continuation-byte payloads differ.
fn mask(i: usize) u21 {
    assert(i < 4);
    const shift: u5 = @intCast(6 * i);
    return (@as(u21, 1) << shift) - 1;
}

/// Splits `range` around the surrogate interval, excluding surrogate values.
///
/// Returns null when `range` does not intersect surrogates. Otherwise, `left`
/// and `right` are the valid scalar subranges before and after the surrogate
/// interval; either side may be null when `range` starts or ends inside the
/// surrogate interval.
fn splitSurrogates(range: ScalarRange) ?struct { left: ?ScalarRange, right: ?ScalarRange } {
    if (range.from > surrogate.to or range.to < surrogate.from) return null;
    return .{
        .left = if (range.from < surrogate.from) .init(range.from, surrogate.from - 1) else null,
        .right = if (range.to > surrogate.to) .init(surrogate.to + 1, range.to) else null,
    };
}

fn maxScalarValue(byte_count: usize) u21 {
    return switch (byte_count) {
        1 => 0x007f,
        2 => 0x07ff,
        3 => 0xffff,
        4 => scalar_max,
        else => unreachable,
    };
}

fn expectSequences(from: u21, to: u21, expected: []const Sequence) !void {
    var seqs = Sequences.init(.init(from, to));
    var index: usize = 0;
    while (seqs.next()) |actual| {
        if (index >= expected.len) return error.TestUnexpectedResult;
        try testing.expectEqual(expected[index].slice().len, actual.slice().len);
        try testing.expectEqualSlices(ByteRange, expected[index].slice(), actual.slice());
        index += 1;
    }
    try testing.expectEqual(expected.len, index);
}

test "cyrillic range" {
    try expectSequences(0x0400, 0x04FF, &.{
        .init(&.{
            .{ .from = 0xD0, .to = 0xD3 },
            .{ .from = 0x80, .to = 0xBF },
        }),
    });
    try expectSequences(0x0400, 0x052F, &.{
        .init(&.{
            .{ .from = 0xD0, .to = 0xD3 },
            .{ .from = 0x80, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xD4, .to = 0xD4 },
            .{ .from = 0x80, .to = 0xAF },
        }),
    });
}

test "bmp exclude surrogates" {
    try expectSequences(0x0000, 0xFFFF, &.{
        .init(&.{.{ .from = 0x00, .to = 0x7F }}),
        .init(&.{
            .{ .from = 0xC2, .to = 0xDF },
            .{ .from = 0x80, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xE0, .to = 0xE0 },
            .{ .from = 0xA0, .to = 0xBF },
            .{ .from = 0x80, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xE1, .to = 0xEC },
            .{ .from = 0x80, .to = 0xBF },
            .{ .from = 0x80, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xED, .to = 0xED },
            .{ .from = 0x80, .to = 0x9F },
            .{ .from = 0x80, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xEE, .to = 0xEF },
            .{ .from = 0x80, .to = 0xBF },
            .{ .from = 0x80, .to = 0xBF },
        }),
    });
}

test "all unicode scalars" {
    try expectSequences(0x0000, scalar_max, &.{
        .init(&.{.{ .from = 0x00, .to = 0x7F }}),
        .init(&.{
            .{ .from = 0xC2, .to = 0xDF },
            .{ .from = 0x80, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xE0, .to = 0xE0 },
            .{ .from = 0xA0, .to = 0xBF },
            .{ .from = 0x80, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xE1, .to = 0xEC },
            .{ .from = 0x80, .to = 0xBF },
            .{ .from = 0x80, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xED, .to = 0xED },
            .{ .from = 0x80, .to = 0x9F },
            .{ .from = 0x80, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xEE, .to = 0xEF },
            .{ .from = 0x80, .to = 0xBF },
            .{ .from = 0x80, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xF0, .to = 0xF0 },
            .{ .from = 0x90, .to = 0xBF },
            .{ .from = 0x80, .to = 0xBF },
            .{ .from = 0x80, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xF1, .to = 0xF3 },
            .{ .from = 0x80, .to = 0xBF },
            .{ .from = 0x80, .to = 0xBF },
            .{ .from = 0x80, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xF4, .to = 0xF4 },
            .{ .from = 0x80, .to = 0x8F },
            .{ .from = 0x80, .to = 0xBF },
            .{ .from = 0x80, .to = 0xBF },
        }),
    });
}

test "skip pure surrogate range" {
    try expectSequences(surrogate.from, surrogate.to, &.{});
}

test "sequences around surrogate boundary" {
    try expectSequences(surrogate.from - 1, surrogate.to + 1, &.{
        .init(&.{
            .{ .from = 0xED, .to = 0xED },
            .{ .from = 0x9F, .to = 0x9F },
            .{ .from = 0xBF, .to = 0xBF },
        }),
        .init(&.{
            .{ .from = 0xEE, .to = 0xEE },
            .{ .from = 0x80, .to = 0x80 },
            .{ .from = 0x80, .to = 0x80 },
        }),
    });
}

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const ranges_mod = @import("ranges.zig");
const ByteRange = ranges_mod.ByteRange;
const ScalarRange = ranges_mod.ScalarRange;
