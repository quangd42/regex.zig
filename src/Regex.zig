const std = @import("std");
const Allocator = std.mem.Allocator;

const PikeVm = @import("engine/PikeVm.zig");
const errors = @import("errors.zig");
pub const Diagnostics = errors.Diagnostics;
pub const Span = errors.Span;
pub const Options = @import("Options.zig");
const Compiler = @import("syntax/Compiler.zig");
const types = @import("types.zig");
pub const Match = types.Match;
pub const Captures = types.Captures;

const Regex = @This();
engine: PikeVm,

pub fn compile(gpa: Allocator, pattern: []const u8, options: Options) !Regex {
    const prog = try Compiler.compile(gpa, pattern, options);

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

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

test "usage: basic compile, match, find" {
    const gpa = testing.allocator;

    {
        var re = try Regex.compile(gpa, "a(b|c|)\\d", .{});
        defer re.deinit();
        try expect(re.match("ab0"));
        try expect(re.match("ac1"));
        try expect(re.match("a1"));
        try expect(!re.match("aadd"));

        try expectEqual(Match{ .start = 2, .end = 5 }, re.find("xyac12").?);
        try expectEqual(Match{ .start = 2, .end = 4 }, re.find("mna1x").?);
        try expectEqual(null, re.find("aadd"));
    }
    {
        var re = try Regex.compile(gpa, "[\\d\\D]", .{});
        defer re.deinit();
        try expect(re.match("5"));
        try expect(re.match("a"));
    }
}

test "usage: error with diagnostics" {
    const gpa = testing.allocator;
    {
        const pattern = "[z-a]";
        var diag: Diagnostics = undefined;
        var re = Regex.compile(gpa, pattern, .{ .diagnostics = &diag }) catch {
            switch (diag) {
                .parse => |parse_diag| {
                    try expectEqual(.invalid_class_range, parse_diag.err);
                    try expectEqual(Span{ .start = 3, .end = 4 }, parse_diag.span);
                    try expectEqual(Span{ .start = 1, .end = 2 }, parse_diag.aux_span.?);
                },
                .compile => return error.TestUnexpectedResult,
            }
            return;
        };
        re.deinit();
        return error.TestUnexpectedResult;
    }
    {
        const pattern = "ab";
        var diag: Diagnostics = undefined;
        var re = Regex.compile(gpa, pattern, .{
            .limits = .{ .states_count = 4 },
            .diagnostics = &diag,
        }) catch {
            switch (diag) {
                .compile => |compile_diag| switch (compile_diag) {
                    .too_many_states => |state_limit| {
                        try expectEqual(4, state_limit.limit);
                        try expectEqual(5, state_limit.count);
                    },
                    else => return error.TestUnexpectedResult,
                },
                .parse => return error.TestUnexpectedResult,
            }
            return;
        };
        re.deinit();
        return error.TestUnexpectedResult;
    }
}
