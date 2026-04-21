const harness = @import("../harness.zig");

pub const suite: harness.Suite = .{
    .name = "multiline",
    .cases = &cases,
};

const cases = [_]harness.Case{
    // Added for Zig regex: LF-only multiline anchor behavior.
    .{
        .name = "start-after-lf",
        .pattern = "(?m)^def",
        .haystack = "abc\ndef",
        .expected = .one(.{ 4, 7 }),
    },
    .{
        .name = "end-before-lf",
        .pattern = "(?m)abc$",
        .haystack = "abc\ndef",
        .expected = .one(.{ 0, 3 }),
    },
    .{
        .name = "whole-inner-line",
        .pattern = "(?m)^[a-z]+$",
        .haystack = "123\nabc\n456",
        .expected = .one(.{ 4, 7 }),
    },
    .{
        .name = "start-without-multiline-no",
        .pattern = "^def",
        .haystack = "abc\ndef",
        .expected = .one(null),
    },
    .{
        .name = "end-without-multiline-no",
        .pattern = "abc$",
        .haystack = "abc\ndef",
        .expected = .one(null),
    },
    .{
        .name = "empty-line",
        .pattern = "(?m)^$",
        .haystack = "abc\n\ndef",
        .expected = .one(.{ 4, 4 }),
    },

    // Ported from rust-regex testdata/multiline.toml.
    .{
        .name = "basic6",
        .pattern = "(?m)[a-z]^",
        .haystack = "abc\ndef\nxyz",
        .expected = .one(null),
    },
    .{
        .name = "basic8",
        .pattern = "(?m)$[a-z]",
        .haystack = "abc\ndef\nxyz",
        .expected = .one(null),
    },
};
