const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

const Program = @import("../syntax/Program.zig");
const Predicate = Program.State.Assertion.Predicate;
const Offset = Program.Offset;
const ascii = @import("./ascii.zig");

pub fn assert(pred: Predicate, haystack: []const u8, at: Offset) bool {
    return switch (pred) {
        .start_text => at == 0,
        .end_text => at == haystack.len,
        .start_line => at == 0 or haystack[at - 1] == '\n',
        .end_line => at == haystack.len or (at < haystack.len and haystack[at] == '\n'),
        .word_boundary => isWordBoundary(haystack, at),
        .not_word_boundary => !isWordBoundary(haystack, at),
    };
}

fn isWordBoundary(haystack: []const u8, at: Offset) bool {
    const left_is_word = at > 0 and ascii.isWordByte(haystack[at - 1]);
    const right_is_word = at < haystack.len and ascii.isWordByte(haystack[at]);
    return left_is_word != right_is_word;
}

test "word boundary at beginning and end of text" {
    const haystack = "word";
    try expect(isWordBoundary(haystack, 0));
    try expect(isWordBoundary(haystack, haystack.len));
}

test "word boundary between non-word and word bytes" {
    const haystack = "a b";
    try expect(isWordBoundary(haystack, 0));
    try expect(isWordBoundary(haystack, 1));
    try expect(isWordBoundary(haystack, 2));
    try expect(!isWordBoundary("ab", 1));
}

test "word boundary on empty input" {
    try expect(!isWordBoundary("", 0));
}

test "line boundary symmetry across newline" {
    const haystack = "ab\ncd";
    const want_start = [_]bool{ true, false, false, true, false, false };
    const want_end = [_]bool{ false, false, true, false, false, true };

    for (want_start, want_end, 0..) |exp_start, exp_end, at| {
        const off: Offset = @intCast(at);
        try expect(assert(.start_line, haystack, off) == exp_start);
        try expect(assert(.end_line, haystack, off) == exp_end);
    }
}

test "line boundaries with trailing newline" {
    const haystack = "ab\n";
    try expect(assert(.end_line, haystack, 2));
    try expect(assert(.start_line, haystack, 3));
    try expect(assert(.end_line, haystack, 3));
}
