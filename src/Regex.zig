const std = @import("std");
const Allocator = std.mem.Allocator;

const Regex = @This();
const Compiler = @import("syntax/Compiler.zig");
const PikeVM = @import("engine/PikeVm.zig");

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

test "basic end-to-end" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var re = try compile(gpa, "a(b|c|)\\d");
    defer re.deinit();
    try testing.expect(re.match("ab0"));
    try testing.expect(re.match("ac1"));
    try testing.expect(re.match("a1"));
    try testing.expect(!re.match("aadd"));
}
