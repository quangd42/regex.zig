pub const ByteRange = Range(.byte);
pub const ByteRangeSet = RangeSet(.byte);

const Kind = enum {
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

fn Range(kind: Kind) type {
    return struct {
        from: T,
        to: T,

        const Self = @This();
        const T = kind.Value();

        pub fn init(from: T, to: T) Self {
            return .{ .from = from, .to = to };
        }

        pub fn caseFoldSimple(self: Self, gpa: Allocator, dest: *std.ArrayList(Self)) !void {
            switch (kind) {
                .byte => {
                    if (self.to < 'A' or self.from > 'z') return;
                    if (self.intersect(.init('a', 'z'))) |r| {
                        try dest.append(gpa, .{ .from = r.from - 32, .to = r.to - 32 });
                    }
                    if (self.intersect(.init('A', 'Z'))) |r| {
                        try dest.append(gpa, .{ .from = r.from + 32, .to = r.to + 32 });
                    }
                },
                .utf8_scalar => @compileError("utf8 not yet supported"),
            }
        }

        pub fn intersect(self: Self, other: Self) ?Self {
            if (self.from > other.to or self.to < other.from) return null;
            return .init(
                @max(self.from, other.from),
                @min(self.to, other.to),
            );
        }
    };
}

/// Accumulator for inclusive ranges.
///
/// `append` and `appendSlice` do not preserve canonical ordering.
/// Call `canonicalize` before reading `slice` when set semantics are required.
/// Operations that require canonical input, such as `negate`, canonicalize
/// internally.
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

        pub fn append(self: *Self, gpa: Allocator, range: T, fold: bool) !void {
            try self.ranges.append(gpa, range);
            if (fold) try range.caseFoldSimple(gpa, &self.ranges);
            self.canonical = false;
        }

        pub fn appendSlice(self: *Self, gpa: Allocator, items: []const T, fold: bool) !void {
            const start = self.ranges.items.len;
            try self.ranges.appendSlice(gpa, items);
            if (fold) {
                // Iterating with index instead of directly on `ranges.items` because
                // slice ptr might be invalidated as we append to it.
                for (0..items.len) |i| {
                    const r = self.ranges.items[start + i];
                    try r.caseFoldSimple(gpa, &self.ranges);
                }
            }
            self.canonical = false;
        }

        pub fn len(self: *Self) usize {
            return self.ranges.items.len;
        }

        pub fn slice(self: *Self) []const T {
            return self.ranges.items;
        }

        pub fn canonicalize(self: *Self) !void {
            if (self.canonical) return;
            defer self.canonical = true;
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
        /// UTF-8 scalar negation is not yet implemented.
        pub fn negate(self: *Self, gpa: Allocator) !void {
            if (kind == .utf8_scalar) @compileError("utf8 not yet supported");
            try self.canonicalize();
            try self.ranges.ensureUnusedCapacity(gpa, 1);
            const len_ = self.len();
            self.ranges.items.len += 1;

            const max = kind.max();

            var i: usize = 0;
            var next_from: u8 = 0;

            for (self.ranges.items[0..len_]) |range| {
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

const std = @import("std");
const Allocator = std.mem.Allocator;
