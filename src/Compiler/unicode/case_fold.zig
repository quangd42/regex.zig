//! Simple Unicode case folding for compiler character class construction.

const std = @import("std");
const testing = std.testing;

const ranges = @import("../ranges.zig");
const table = @import("case_fold_table.zig");

pub const unicode_version = table.unicode_version;

pub const even_odd: i22 = 1;
pub const odd_even: i22 = -1;

pub const ScalarRange = ranges.ScalarRange;

/// Packed range/delta entry for one step in a simple fold cycle.
pub const Entry = packed struct(u64) {
    lo: u21,
    hi: u21,
    delta: i22,

    /// Maps an overlapping source range through this entry's fold step.
    fn foldRange(self: Entry, range: ScalarRange) ScalarRange {
        return switch (self.delta) {
            even_odd => .init(
                if (range.from % 2 == 1) range.from - 1 else range.from,
                if (range.to % 2 == 0) range.to + 1 else range.to,
            ),
            odd_even => .init(
                if (range.from % 2 == 0) range.from - 1 else range.from,
                if (range.to % 2 == 1) range.to + 1 else range.to,
            ),
            else => |d| .init(
                @intCast(@as(i22, range.from) + d),
                @intCast(@as(i22, range.to) + d),
            ),
        };
    }
};

/// Iterates the simple case fold table for one source scalar range.
///
/// Each call to `next` scans to the next table entry that overlaps `range`,
/// maps only that overlap by one fold step, and returns the mapped range.
///
/// ```zig
/// const expect = testing.expectEqual;
///
/// var upper = Iterator.init(.init('J', 'L'));
/// try expect(.init('j', 'l'), upper.next().?);
/// try expect(null, upper.next());
///
/// var lower = Iterator.init(.init('j', 'l'));
/// try expect(.init('J', 'J'), lower.next().?);
/// try expect(.init(0x212A, 0x212A), lower.next().?); // Kelvin
/// try expect(.init('L', 'L'), lower.next().?);
/// try expect(null, lower.next());
/// ```
pub const Iterator = struct {
    range: ScalarRange,
    index: usize,

    /// Initializes an iterator at the first table entry that can overlap `range`.
    pub fn init(range: ScalarRange) Iterator {
        return .{
            .range = range,
            .index = std.sort.lowerBound(Entry, &table.entries, range.from, struct {
                fn order(cp: u21, entry: Entry) std.math.Order {
                    return std.math.order(cp, entry.hi);
                }
            }.order),
        };
    }

    /// Returns the next mapped table overlap, or null when no overlaps remain.
    pub fn next(self: *Iterator) ?ScalarRange {
        while (self.index < table.entries.len) {
            const entry = table.entries[self.index];
            self.index += 1;

            if (entry.lo > self.range.to) return null;

            const overlap = self.range.intersect(.init(entry.lo, entry.hi)) orelse continue;
            return entry.foldRange(overlap);
        }
        return null;
    }
};

fn expectFolded(from: u21, to: u21, expected: []const ScalarRange) !void {
    var it = Iterator.init(.init(from, to));
    for (expected) |want| {
        const actual = it.next();
        try testing.expect(actual != null);
        try testing.expectEqual(want, actual.?);
    }
    try testing.expectEqual(null, it.next());
}

test "Entry is packed into one u64" {
    try testing.expectEqual(64, @bitSizeOf(Entry));
    try testing.expectEqual(8, @sizeOf(Entry));
}

test "Iterator folds ranges by table overlap" {
    try expectFolded('J', 'L', &.{
        .init('j', 'l'),
    });
    try expectFolded('j', 'l', &.{
        .init('J', 'J'),
        .init(0x212A, 0x212A),
        .init('L', 'L'),
    });
}

test "Iterator folds special cycles" {
    try expectFolded(0x212A, 0x212A, &.{
        .init('K', 'K'),
    });
    try expectFolded(0x03A3, 0x03A3, &.{
        .init(0x03C2, 0x03C2),
    });
    try expectFolded(0x03C2, 0x03C2, &.{
        .init(0x03C2, 0x03C3),
    });
    try expectFolded(0x03C3, 0x03C3, &.{
        .init(0x03A3, 0x03A3),
    });
}

test "Iterator folds even odd entries" {
    try expectFolded(0x0100, 0x0100, &.{
        .init(0x0100, 0x0101),
    });
    try expectFolded(0x0101, 0x0101, &.{
        .init(0x0100, 0x0101),
    });
}
