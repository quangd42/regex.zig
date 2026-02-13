const std = @import("std");
const Allocator = std.mem.Allocator;

const Regex = @This();
const Compiler = @import("syntax/Compiler.zig");
const PikeVM = @import("engine/PikeVm.zig");

const Engine = @import("engine.zig");
pub const Match = Engine.Match;

engine: PikeVM,

pub fn compile(gpa: Allocator, pattern: []const u8) !Regex {
    const prog = try Compiler.compile(gpa, pattern);

    // TODO: choose engine based on pattern
    return .{ .engine = try .init(gpa, prog) };
}

pub fn deinit(re: *Regex) void {
    re.engine.deinit();
}

pub fn match(re: *Regex, haystack: []const u8) bool {
    return re.engine.match(haystack);
}

pub fn find(re: *Regex, haystack: []const u8) ?Match {
    return re.engine.find(haystack);
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
