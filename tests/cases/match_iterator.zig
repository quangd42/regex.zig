const harness = @import("../harness.zig");

pub const suite: harness.Suite = .{
    .name = "match-iterator",
    .cases = &cases,
};

const cases = [_]harness.Case{
    // Added for Zig regex
    .{
        .name = "adjacent-literals",
        .pattern = "a",
        .haystack = "aaa",
        .expected = .all(&.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 } }),
    },
    .{
        .name = "non-adjacent-literals",
        .pattern = "a",
        .haystack = "aba",
        .expected = .all(&.{ .{ 0, 1 }, .{ 2, 3 } }),
    },
    .{
        .name = "no-matches",
        .pattern = "z",
        .haystack = "abc",
        .expected = .all(&[_]harness.Span{}),
    },
    .{
        .name = "empty-pattern-empty-haystack",
        .pattern = "",
        .haystack = "",
        .expected = .all(&.{.{ 0, 0 }}),
    },
    .{
        .name = "empty-pattern-nonempty-haystack",
        .pattern = "",
        .haystack = "abc",
        .expected = .all(&.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 } }),
    },
    .{
        .name = "empty-after-nonempty",
        .pattern = "b|(?:)+",
        .haystack = "abc",
        .expected = .all(&.{ .{ 0, 0 }, .{ 1, 2 }, .{ 3, 3 } }),
    },
    .{
        .name = "nonempty-before-empty",
        .pattern = "abc|.*?",
        .haystack = "abczzz",
        .expected = .all(&.{ .{ 0, 3 }, .{ 4, 4 }, .{ 5, 5 }, .{ 6, 6 } }),
    },
    .{
        .name = "anchored-stop-on-first-miss",
        .pattern = "a",
        .haystack = "aaba",
        .anchored = true,
        .expected = .all(&.{ .{ 0, 1 }, .{ 1, 2 } }),
    },
    .{
        .name = "search-window",
        .pattern = "\\d+",
        .haystack = "abc 123 456 xyz",
        .start = 4,
        .end = 11,
        .expected = .all(&.{ .{ 4, 7 }, .{ 8, 11 } }),
    },
    .{
        .name = "start-anchor",
        .pattern = "^a",
        .haystack = "aa",
        .expected = .all(&.{.{ 0, 1 }}),
    },
    .{
        .name = "captures",
        .pattern = "(a)",
        .haystack = "aba",
        .expected = .allCapt(&.{
            &.{ .{ 0, 1 }, .{ 0, 1 } },
            &.{ .{ 2, 3 }, .{ 2, 3 } },
        }),
    },
};
