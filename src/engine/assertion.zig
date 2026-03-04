const std = @import("std");
const testing = std.testing;

const Program = @import("../syntax/Program.zig");
const Predicate = Program.Predicate;
const Offset = Program.Offset;
const ascii = @import("./ascii.zig");

pub fn assert(pred: Predicate, haystack: []const u8, at: Offset) bool {
    return switch (pred) {
        .start_text => at == 0,
        .end_text => at == haystack.len,
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
    try testing.expect(isWordBoundary(haystack, 0));
    try testing.expect(isWordBoundary(haystack, haystack.len));
}

test "word boundary between non-word and word bytes" {
    const haystack = "a b";
    try testing.expect(isWordBoundary(haystack, 0));
    try testing.expect(isWordBoundary(haystack, 1));
    try testing.expect(isWordBoundary(haystack, 2));
    try testing.expect(!isWordBoundary("ab", 1));
}

test "word boundary on empty input" {
    try testing.expect(!isWordBoundary("", 0));
}
