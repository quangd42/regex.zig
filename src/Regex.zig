const std = @import("std");
const Allocator = std.mem.Allocator;

const Regex = @This();
const Compiler = @import("syntax/Compiler.zig");
const PikeVM = @import("engine/PikeVm.zig");

const Engine = @import("engine.zig");
pub const Match = Engine.Match;
pub const Captures = Engine.Captures;

engine: PikeVM,

pub fn compile(gpa: Allocator, pattern: []const u8) !Regex {
    const prog = try Compiler.compile(gpa, pattern);

    // TODO: choose engine based on pattern
    return .{ .engine = try .init(gpa, prog) };
}

pub fn deinit(re: *Regex) void {
    re.engine.deinit();
}

/// Performs unanchored matching on the given haystack.
pub fn match(re: *Regex, haystack: []const u8) bool {
    return re.engine.match(haystack);
}

/// Returns the start and end indices of the left-most match in the haystack.
/// Returns null when there is no match.
pub fn find(re: *Regex, haystack: []const u8) ?Match {
    return re.engine.find(haystack);
}

/// Searches for a match and writes capture groups into the supplied buffer.
/// Returns Captures wrapping the buffer on match, or null if no match is found.
/// Asserts that `buffer.len` is at least `capturesLen()`.
pub fn findCaptures(re: *Regex, haystack: []const u8, buffer: []?Match) ?Captures {
    return re.engine.findCaptures(haystack, buffer);
}

/// Convenient function that creates a buffer of the correct size on the heap,
/// and call `findCaptures()` with it. Caller owns the return buffer.
/// Frees the buffer if there is no match.
pub fn findCapturesAlloc(re: *Regex, gpa: Allocator, haystack: []const u8) !?Captures {
    return re.engine.findCapturesAlloc(gpa, haystack);
}

/// Returns the number of capture groups (including group 0 for the full match).
/// Useful to determine the required minimum size of buffer for `findCaptures()`.
pub fn capturesLen(re: *Regex) usize {
    return re.engine.capturesLen();
}

test "testdata" {
    _ = @import("tests/fowler_basic.zig");
}

test "basic end-to-end" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var re = try compile(gpa, "a(b|c|)\\d");
    defer re.deinit();
    try testing.expect(re.match("ab0"));
    try testing.expect(re.match("ac1"));
    try testing.expect(re.match("a1"));
    try testing.expect(!re.match("aadd"));

    try testing.expectEqual(Match{ .start = 2, .end = 5 }, re.find("xyac12").?);
    try testing.expectEqual(Match{ .start = 2, .end = 4 }, re.find("mna1x").?);
    try testing.expectEqual(null, re.find("aadd"));

    var re2 = try compile(gpa, "a\\D");
    defer re2.deinit();
    try testing.expect(re2.match("aa"));
    try testing.expect(!re2.match("a1"));
}

test "basic empty matches" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var re4 = try compile(gpa, "|a");
    defer re4.deinit();
    const f4 = re4.find("abc");
    try testing.expect(f4 != null);
    try testing.expectEqual(Match{ .start = 0, .end = 0 }, f4.?);

    var re5 = try compile(gpa, "a|");
    defer re5.deinit();
    const f5 = re5.find("abc");
    try testing.expect(f5 != null);
    try testing.expectEqual(Match{ .start = 0, .end = 1 }, f5.?);

    var re3 = try compile(gpa, "b|");
    defer re3.deinit();
    const f3 = re3.find("abc");
    try testing.expect(f3 != null);
    try testing.expectEqual(Match{ .start = 0, .end = 0 }, f3.?);
}
