pub const ByteRange = Range(.byte);
pub const ScalarRange = Range(.utf8_scalar);
pub const ByteRangeSet = RangeSet(.byte);
pub const ScalarRangeSet = RangeSet(.utf8_scalar);
pub const ByteClassBuilder = ClassBuilder(.byte);
pub const ScalarClassBuilder = ClassBuilder(.utf8_scalar);

/// The value domain for a range set.
pub const Kind = enum {
    byte,
    utf8_scalar,

    fn Value(kind: Kind) type {
        return switch (kind) {
            .byte => u8,
            .utf8_scalar => u21,
        };
    }

    pub fn min(comptime kind: Kind) kind.Value() {
        return switch (kind) {
            .byte => 0x00,
            .utf8_scalar => 0x0000,
        };
    }

    pub fn max(comptime kind: Kind) kind.Value() {
        return switch (kind) {
            .byte => 0xFF,
            .utf8_scalar => 0x10FFFF,
        };
    }
};

/// Inclusive range over the domain selected by `kind`.
pub fn Range(kind: Kind) type {
    return struct {
        from: T,
        to: T,

        const Self = @This();
        const T = kind.Value();

        pub fn init(from: T, to: T) Self {
            return .{ .from = from, .to = to };
        }

        pub fn full() Self {
            return .init(kind.min(), kind.max());
        }

        pub fn isValid(self: Self) bool {
            return self.from <= self.to;
        }

        pub fn inBounds(self: Self) bool {
            return self.from >= kind.min() and self.to <= kind.max();
        }

        pub fn contains(self: Self, target: T) bool {
            return self.from <= target and target <= self.to;
        }

        pub fn intersect(self: Self, other: Self) ?Self {
            if (self.from > other.to or self.to < other.from) return null;
            return .init(
                @max(self.from, other.from),
                @min(self.to, other.to),
            );
        }

        /// Promotes a byte range into this range kind.
        ///
        /// This is intended for byte-defined ASCII classes that can be treated
        /// as the same scalar values in Unicode mode. It does not decode UTF-8.
        pub fn fromBytes(from: u8, to: u8) Self {
            return .init(from, to);
        }

        /// Returns this range as a byte range only when it is entirely ASCII.
        pub fn asAscii(self: Self) ?Range(.byte) {
            std.debug.assert(self.isValid());
            if (self.to > 0x7f) return null;
            switch (kind) {
                .byte => return self,
                .utf8_scalar => return .{
                    .from = @as(u8, @intCast(self.from)),
                    .to = @as(u8, @intCast(self.to)),
                },
            }
        }

        /// Appends ASCII simple case equivalents for this range to `set`,
        /// not including the original range.
        pub fn appendAsciiFold(self: Self, gpa: Allocator, set: *RangeSet(kind)) Allocator.Error!void {
            if (self.to < 'A' or self.from > 'z') return;
            if (self.intersect(.init('a', 'z'))) |r| {
                try set.append(gpa, .init(r.from - 32, r.to - 32));
            }
            if (self.intersect(.init('A', 'Z'))) |r| {
                try set.append(gpa, .init(r.from + 32, r.to + 32));
            }
        }
    };
}

/// Accumulator for inclusive ranges.
///
/// `append` and `appendSlice` do not preserve canonical ordering internally.
/// Public readers such as `len` and `slice` canonicalize before returning, so
/// callers observe sorted, non-overlapping, non-adjacent ranges.
///
/// utf-8 scalar ranges are not split around surrogate values here.
pub fn RangeSet(kind: Kind) type {
    return struct {
        const Self = @This();
        const T = Range(kind);

        ranges: std.ArrayList(T) = .empty,
        canonical: bool = false,

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.ranges.deinit(gpa);
        }

        pub fn clear(self: *Self) void {
            self.ranges.clearRetainingCapacity();
            self.canonical = false;
        }

        pub fn append(self: *Self, gpa: Allocator, range: T) !void {
            try self.ranges.append(gpa, range);
            self.canonical = false;
        }

        pub fn appendSlice(self: *Self, gpa: Allocator, items: []const T) !void {
            try self.ranges.appendSlice(gpa, items);
            self.canonical = false;
        }

        /// Canonicalizes and returns the set ranges.
        ///
        /// The returned slice is valid until the next mutation or `clear`.
        pub fn slice(self: *Self) []const T {
            self.canonicalize();
            return self.ranges.items;
        }

        /// Canonicalize ranges in place. The resulting ranges are sorted by start byte/scalar,
        /// and no two ranges overlap or are adjacent.
        pub fn canonicalize(self: *Self) void {
            if (self.canonical) return;
            self.canonical = true;
            const ranges = self.ranges.items;
            if (ranges.len == 0) return;
            std.mem.sortUnstable(T, ranges, {}, lessRange);

            var i: usize = 1;
            for (ranges[1..]) |current| {
                var previous = &ranges[i - 1];
                if (current.from <= previous.to +| 1) {
                    previous.to = @max(previous.to, current.to);
                } else {
                    ranges[i] = current;
                    i += 1;
                }
            }
            self.ranges.shrinkRetainingCapacity(i);
        }

        fn lessRange(_: void, lhs: T, rhs: T) bool {
            if (lhs.from < rhs.from) return true;
            if (lhs.from > rhs.from) return false;
            return lhs.to > rhs.to;
        }

        /// Replace the set with its complement. The bound of the set is defined
        /// by `kind`.
        ///
        /// Callers must apply any required case folding before calling this.
        ///
        /// The resulting ranges might contain surrogate values.
        pub fn negate(self: *Self, gpa: Allocator) !void {
            self.canonicalize();
            try self.ranges.ensureUnusedCapacity(gpa, 1);
            const len = self.ranges.items.len;
            self.ranges.items.len += 1;

            const max = kind.max();

            var i: usize = 0;
            var next_from = kind.min();

            for (self.ranges.items[0..len]) |range| {
                if (next_from < range.from) {
                    self.ranges.items[i] = .{
                        .from = next_from,
                        .to = range.from - 1,
                    };
                    i += 1;
                }
                if (range.to == max) break;
                next_from = range.to + 1;
            } else {
                self.ranges.items[i] = .{
                    .from = next_from,
                    .to = max,
                };
                i += 1;
            }

            self.ranges.shrinkRetainingCapacity(i);
        }
    };
}

fn expectRanges(comptime kind: Kind, actual: []const Range(kind), expected: []const Range(kind)) !void {
    try testing.expectEqualSlices(Range(kind), expected, actual);
}

test "Range.full returns full domain" {
    try testing.expectEqual(ByteRange.init(0x00, 0xff), ByteRange.full());
    try testing.expectEqual(ScalarRange.init(0x0000, 0x10ffff), ScalarRange.full());
}

test "RangeSet.slice canonicalizes unsorted overlapping adjacent ranges" {
    const a = testing.allocator;
    var set: ByteRangeSet = .empty;
    defer set.deinit(a);

    try set.append(a, .init(10, 20));
    try set.append(a, .init(50, 55));
    try set.append(a, .init(0, 4));
    try set.append(a, .init(5, 9));
    try set.append(a, .init(18, 40));

    try expectRanges(.byte, set.slice(), &.{
        .init(0, 40),
        .init(50, 55),
    });
}

test "RangeSet.negate empty byte set returns full range" {
    const a = testing.allocator;
    var set: ByteRangeSet = .empty;
    defer set.deinit(a);

    try set.negate(a);

    try expectRanges(.byte, set.slice(), &.{
        .init(0x00, 0xff),
    });
}

test "RangeSet.negate full range returns empty" {
    const a = testing.allocator;
    var bytes: ByteRangeSet = .empty;
    defer bytes.deinit(a);

    try bytes.append(a, .full());
    try bytes.negate(a);
    try expectRanges(.byte, bytes.slice(), &.{});

    var scalars: ScalarRangeSet = .empty;
    defer scalars.deinit(a);

    try scalars.append(a, .full());
    try scalars.negate(a);
    try expectRanges(.utf8_scalar, scalars.slice(), &.{});
}

test "RangeSet.negate canonicalizes before complement" {
    const a = testing.allocator;
    var set: ByteRangeSet = .empty;
    defer set.deinit(a);

    try set.append(a, .init(0x80, 0xff));
    try set.append(a, .init(0x00, 0x7f));
    try set.negate(a);

    try expectRanges(.byte, set.slice(), &.{});
}

test "RangeSet.negate returns surrounding gaps" {
    const a = testing.allocator;
    var set: ByteRangeSet = .empty;
    defer set.deinit(a);

    try set.append(a, .init(10, 20));
    try set.negate(a);

    try expectRanges(.byte, set.slice(), &.{
        .init(0, 9),
        .init(21, 0xff),
    });
}

/// Builds canonical byte or Unicode scalar ranges for regex classes.
///
/// The builder owns a scratch set for class negation and case folding. Appended
/// ranges may be unsorted or overlapping. `slice` canonicalizes before returning
/// the view used by the compiler, which may contain surrogate values.
pub fn ClassBuilder(kind: Kind) type {
    return struct {
        set: RangeSet(kind) = .empty,
        tmp: RangeSet(kind) = .empty,

        const Self = @This();
        const T = Range(kind);

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.set.deinit(gpa);
            self.tmp.deinit(gpa);
        }

        pub fn clear(self: *Self) void {
            self.set.clear();
            self.tmp.clear();
        }

        /// Appends `range` to the main set, optionally adding simple case-fold
        /// equivalents before any later negation.
        pub fn appendRange(self: *Self, gpa: Allocator, range: T, fold: bool) !void {
            try self.set.append(gpa, range);
            if (fold) try appendFoldedRanges(gpa, &self.set, range);
        }

        fn appendFoldedRanges(gpa: Allocator, dest: *RangeSet(kind), range: T) Allocator.Error!void {
            switch (kind) {
                .byte => try range.appendAsciiFold(gpa, dest),
                .utf8_scalar => try case_fold.appendSimpleFold(gpa, dest, range),
            }
        }

        pub fn appendDotClass(self: *Self, gpa: Allocator, matches_nl: bool) !void {
            if (matches_nl) {
                try self.appendRange(gpa, .full(), false);
                return;
            }

            self.tmp.clear();
            try self.tmp.append(gpa, .init('\n', '\n'));
            try self.tmp.negate(gpa);
            try self.set.appendSlice(gpa, self.tmp.slice());
        }

        pub fn appendPerlClass(self: *Self, gpa: Allocator, cls: Ast.Class.Perl, fold: bool) !void {
            return self.appendByteRanges(gpa, ascii_class.getPerlRanges(cls.kind), cls.negated, fold);
        }

        pub fn appendPosixClass(self: *Self, gpa: Allocator, cls: Ast.Class.Ascii, fold: bool) !void {
            return self.appendByteRanges(gpa, ascii_class.getPosixRanges(cls.kind), cls.negated, fold);
        }

        /// Appends byte-valued named-class ranges to this builder.
        ///
        /// When `kind == .utf8_scalar`, each byte range is promoted to the same
        /// scalar range. This is intended for ASCII/byte-defined classes such
        /// as Perl and POSIX classes, not for arbitrary UTF-8 byte ranges.
        ///
        /// If `negated` is true, negation is applied to the named class locally
        /// using `tmp` before unioning into `set`; this preserves bracket-class
        /// semantics such as `[\D_]`.
        ///
        /// If `fold` is true, ranges are case-folded before any local negation.
        pub fn appendByteRanges(
            self: *Self,
            gpa: Allocator,
            ranges: []const ByteRange,
            negated: bool,
            fold: bool,
        ) !void {
            if (!negated) {
                for (ranges) |r| {
                    try self.appendRange(gpa, .fromBytes(r.from, r.to), fold);
                }
                return;
            }

            self.tmp.clear();
            for (ranges) |r| {
                const converted: T = .fromBytes(r.from, r.to);
                try self.tmp.append(gpa, converted);
                if (fold) try appendFoldedRanges(gpa, &self.tmp, converted);
            }
            try self.tmp.negate(gpa);
            try self.set.appendSlice(gpa, self.tmp.slice());
        }

        pub fn negate(self: *Self, gpa: Allocator) !void {
            try self.set.negate(gpa);
        }

        /// Returns a canonical view of the accumulated ranges.
        ///
        /// The returned slice is valid until the next mutation or `clear`;
        /// callers are expected to clear the builder before starting another
        /// class.
        pub fn slice(self: *Self) []const T {
            return self.set.slice();
        }
    };
}

test "ClassBuilder.appendByteRanges promotes byte ranges to scalar ranges" {
    const a = testing.allocator;
    var builder: ScalarClassBuilder = .empty;
    defer builder.deinit(a);

    try builder.appendByteRanges(a, &.{.{ .from = 'A', .to = 'Z' }}, false, false);

    try expectRanges(.utf8_scalar, builder.slice(), &.{
        .init('A', 'Z'),
    });
}

test "ClassBuilder.appendDotClass" {
    const a = testing.allocator;
    {
        // excludes LF
        var builder: ByteClassBuilder = .empty;
        defer builder.deinit(a);

        try builder.appendDotClass(a, false);

        try expectRanges(.byte, builder.slice(), &.{
            .init(0x00, '\n' - 1),
            .init('\n' + 1, 0xff),
        });
    }
    {
        // includes LF
        var builder: ScalarClassBuilder = .empty;
        defer builder.deinit(a);

        try builder.appendDotClass(a, true);

        try expectRanges(.utf8_scalar, builder.slice(), &.{
            .full(),
        });
    }
}

test "ClassBuilder.appendByteRanges applies local negation" {
    const a = testing.allocator;
    var builder: ScalarClassBuilder = .empty;
    defer builder.deinit(a);

    try builder.appendByteRanges(a, &.{.{ .from = 0x00, .to = 0x7f }}, true, false);

    try expectRanges(.utf8_scalar, builder.slice(), &.{
        .init(0x80, 0x10ffff),
    });
}

test "ClassBuilder.appendByteRanges composes local negation with union" {
    const a = testing.allocator;
    var builder: ScalarClassBuilder = .empty;
    defer builder.deinit(a);

    try builder.appendByteRanges(a, &.{
        .{ .from = '0', .to = '9' },
        .{ .from = 'A', .to = 'Z' },
        .{ .from = 'a', .to = 'z' },
    }, false, false);
    try builder.appendByteRanges(a, &.{.{ .from = 0x00, .to = 0x7f }}, true, false);

    try expectRanges(.utf8_scalar, builder.slice(), &.{
        .init('0', '9'),
        .init('A', 'Z'),
        .init('a', 'z'),
        .init(0x80, 0x10ffff),
    });
}

test "ClassBuilder.appendByteRanges folds before local negation" {
    const a = testing.allocator;
    var builder: ScalarClassBuilder = .empty;
    defer builder.deinit(a);

    try builder.appendByteRanges(a, &.{.{ .from = 'K', .to = 'K' }}, true, true);

    try expectRanges(.utf8_scalar, builder.slice(), &.{
        .init(0x0000, 'K' - 1),
        .init('K' + 1, 'k' - 1),
        .init('k' + 1, 0x212a - 1),
        .init(0x212a + 1, 0x10ffff),
    });
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Ast = @import("../Ast.zig");
const ascii_class = @import("ascii_class.zig");
const case_fold = @import("case_fold.zig");
