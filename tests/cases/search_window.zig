const harness = @import("../harness.zig");

pub const suite: harness.Suite = .{
    .name = "search-window",
    .cases = &cases,
};

const cases = [_]harness.Case{
    // Ported from rust-regex testdata/substring.toml.
    .{
        .name = "ascii-word-start",
        .pattern = "\\b[0-9]+\\b",
        .haystack = "β123",
        .start = 2,
        .end = 5,
        .expected = .one(.{ 2, 5 }),
    },
    .{
        .name = "ascii-word-end",
        .pattern = "\\b[0-9]+\\b",
        .haystack = "123β",
        .start = 0,
        .end = 3,
        .expected = .one(.{ 0, 3 }),
    },

    // Ported from rust-regex testdata/word-boundary.toml.
    .{
        .name = "alt-with-assertion-repetition",
        .pattern = "(?:\\b|%)+",
        .haystack = "z%",
        .start = 1,
        .end = 2,
        .anchored = true,
        .expected = .one(.{ 1, 1 }),
    },

    // Added for Zig regex: bounded search keeps absolute offsets.
    .{
        .name = "anchored-window-captures",
        .pattern = "(ab)",
        .haystack = "zabx",
        .start = 1,
        .end = 3,
        .anchored = true,
        .expected = .capt(&.{ .{ 1, 3 }, .{ 1, 3 } }),
    },
    .{
        .name = "anchored-window-no-match",
        .pattern = "(ab)",
        .haystack = "zabx",
        .start = 0,
        .end = 2,
        .anchored = true,
        .expected = .one(null),
    },

    // Added for Zig regex: assertions see full haystack context, not a slice.
    .{
        .name = "text-start-anchor-uses-haystack-start",
        .pattern = "\\Aab",
        .haystack = "zab",
        .start = 1,
        .end = 3,
        .anchored = true,
        .expected = .one(null),
    },
    .{
        .name = "word-boundary-left-context",
        .pattern = "\\b[0-9]+\\b",
        .haystack = "a123",
        .start = 1,
        .end = 4,
        .expected = .one(null),
    },
    .{
        .name = "word-boundary-right-context",
        .pattern = "\\b[0-9]+\\b",
        .haystack = "123a",
        .start = 0,
        .end = 3,
        .expected = .one(null),
    },
    .{
        .name = "word-boundary-clean-window",
        .pattern = "\\b[0-9]+\\b",
        .haystack = " 123!",
        .start = 1,
        .end = 4,
        .expected = .one(.{ 1, 4 }),
    },

    // Added for Zig regex: zero-width matches can occur at a bounded end.
    .{
        .name = "empty-at-bounded-end",
        .pattern = "",
        .haystack = "abc",
        .start = 3,
        .end = 3,
        .anchored = true,
        .expected = .one(.{ 3, 3 }),
    },
    .{
        .name = "line-end-at-bounded-text-end",
        .pattern = "$",
        .haystack = "abc",
        .start = 3,
        .end = 3,
        .anchored = true,
        .expected = .one(.{ 3, 3 }),
    },
    .{
        .name = "line-end-ignores-window-end",
        .pattern = "$",
        .haystack = "abc",
        .start = 1,
        .end = 1,
        .anchored = true,
        .expected = .one(null),
    },
};
