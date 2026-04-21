const harness = @import("../harness.zig");

pub const suite: harness.Suite = .{
    .name = "flags",
    .cases = &cases,
};

const cases = [_]harness.Case{
    // Ported from rust-regex testdata/flags.toml.
    .{
        .name = "1",
        .pattern = "(?i)abc",
        .haystack = "ABC",
        .expected = .one(.{ 0, 3 }),
    },
    .{
        .name = "2",
        .pattern = "(?i)a(?-i)bc",
        .haystack = "Abc",
        .expected = .one(.{ 0, 3 }),
    },
    .{
        .name = "3",
        .pattern = "(?i)a(?-i)bc",
        .haystack = "ABC",
        .expected = .one(null),
    },
    .{
        .name = "4",
        .pattern = "(?is)a.",
        .haystack = "A\n",
        .expected = .one(.{ 0, 2 }),
    },
    .{
        .name = "5",
        .pattern = "(?is)a.(?-is)a.",
        .haystack = "A\nab",
        .expected = .one(.{ 0, 4 }),
    },
    .{
        .name = "6",
        .pattern = "(?is)a.(?-is)a.",
        .haystack = "A\na\n",
        .expected = .one(null),
    },
    .{
        .name = "7",
        .pattern = "(?is)a.(?-is:a.)?",
        .haystack = "A\na\n",
        .expected = .one(.{ 0, 2 }),
    },
    .{
        .name = "8",
        .pattern = "(?U)a+",
        .haystack = "aa",
        .expected = .one(.{ 0, 1 }),
    },
    .{
        .name = "9",
        .pattern = "(?U)a+?",
        .haystack = "aa",
        .expected = .one(.{ 0, 2 }),
    },
    .{
        .name = "10",
        .pattern = "(?U)(?-U)a+",
        .haystack = "aa",
        .expected = .one(.{ 0, 2 }),
    },
    .{
        .name = "11",
        .pattern = "(?m)(?:^\\d+$\\n?)+",
        .haystack = "123\n456\n789",
        .expected = .one(.{ 0, 11 }),
    },

    // Ported from rust-regex testdata/regression.toml.
    .{
        .name = "flags-are-unset",
        .pattern = "(?:(?i)foo)|Bar",
        .haystack = "bar",
        .expected = .one(null),
    },
    .{
        .name = "negated-char-class-100",
        .pattern = "(?i)[^x]",
        .haystack = "x",
        .expected = .one(null),
    },
    .{
        .name = "negated-char-class-200",
        .pattern = "(?i)[^x]",
        .haystack = "X",
        .expected = .one(null),
    },

    // Added for Zig regex
    .{
        .name = "mid-pattern-ignore-case",
        .pattern = "a(?i)b",
        .haystack = "aB",
        .expected = .one(.{ 0, 2 }),
    },
    .{
        .name = "mid-pattern-ignore-case-not-retroactive",
        .pattern = "a(?i)b",
        .haystack = "AB",
        .expected = .one(null),
    },
    .{
        .name = "scoped-disable-ignore-case-restores",
        .pattern = "(?i)(?-i:ab)C",
        .haystack = "abc",
        .expected = .one(.{ 0, 3 }),
    },
    .{
        .name = "scoped-disable-ignore-case-no-retroactive",
        .pattern = "(?i)(?-i:ab)C",
        .haystack = "Abc",
        .expected = .one(null),
    },
    .{
        .name = "option-multiline-scoped-disable",
        .pattern = "(?-m:^ab$)|^cd$",
        .haystack = "ab\ncd",
        .expected = .one(.{ 3, 5 }),
        .options = .{ .syntax = .{
            .multi_line = true,
        } },
    },
    .{
        .name = "scoped-set-dotall-clear-ignore-case",
        .pattern = "(?s-i:a.)",
        .haystack = "a\n",
        .expected = .one(.{ 0, 2 }),
        .options = .{ .syntax = .{
            .case_insensitive = true,
        } },
    },
    .{
        .name = "scoped-set-dotall-clear-ignore-case-no",
        .pattern = "(?s-i:a.)",
        .haystack = "A\n",
        .expected = .one(null),
        .options = .{ .syntax = .{
            .case_insensitive = true,
        } },
    },
    .{
        .name = "capture-inside-ignore-case-group",
        .pattern = "(?i:(ab))c",
        .haystack = "ABc",
        .expected = .capt(&.{ .{ 0, 3 }, .{ 0, 2 } }),
    },
    .{
        .name = "capture-inside-ignore-case-noncapture-group",
        .pattern = "(?i:(?:x(ab)))c",
        .haystack = "XABc",
        .expected = .capt(&.{ .{ 0, 4 }, .{ 1, 3 } }),
    },
    .{
        .name = "bare-ignore-case-crosses-alt",
        .pattern = "(?i)foo|bar",
        .haystack = "BAR",
        .expected = .one(.{ 0, 3 }),
    },
    .{
        .name = "capture-bare-ignore-case-applies-inside",
        .pattern = "((?i)a)b",
        .haystack = "Ab",
        .expected = .capt(&.{ .{ 0, 2 }, .{ 0, 1 } }),
    },
    .{
        .name = "capture-bare-ignore-case-restores-after",
        .pattern = "((?i)a)b",
        .haystack = "AB",
        .expected = .one(null),
    },
    .{
        .name = "capture-bare-disable-ignore-case-applies-inside",
        .pattern = "(?i)((?-i)a)b",
        .haystack = "aB",
        .expected = .capt(&.{ .{ 0, 2 }, .{ 0, 1 } }),
    },
    .{
        .name = "capture-bare-disable-ignore-case-restores-after",
        .pattern = "(?i)((?-i)a)b",
        .haystack = "AB",
        .expected = .one(null),
    },
    .{
        .name = "alt-bare-ignore-case-crosses-branches",
        .pattern = "((?i)a|b)c",
        .haystack = "Bc",
        .expected = .capt(&.{ .{ 0, 2 }, .{ 0, 1 } }),
    },
    .{
        .name = "alt-bare-ignore-case-restores-before-tail",
        .pattern = "((?i)a|b)c",
        .haystack = "BC",
        .expected = .one(null),
    },
};
