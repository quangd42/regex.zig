const std = @import("std");
const Allocator = std.mem.Allocator;

const Regex = @This();
const Compiler = @import("syntax/Compiler.zig");
pub const Options = @import("Options.zig");
const PikeVM = @import("engine/PikeVm.zig");

const types = @import("types.zig");
pub const Match = types.Match;
pub const Captures = types.Captures;

engine: PikeVM,

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
const errors = @import("errors.zig");
const Diagnostics = errors.Diagnostics;
const Span = errors.Span;

test "usage: basic compile, match, find" {
    const gpa = testing.allocator;

    {
        var re = try Regex.compile(gpa, "a(b|c|)\\d", .{});
        defer re.deinit();
        try testing.expect(re.match("ab0"));
        try testing.expect(re.match("ac1"));
        try testing.expect(re.match("a1"));
        try testing.expect(!re.match("aadd"));

        try testing.expectEqual(Match{ .start = 2, .end = 5 }, re.find("xyac12").?);
        try testing.expectEqual(Match{ .start = 2, .end = 4 }, re.find("mna1x").?);
        try testing.expectEqual(null, re.find("aadd"));
    }
    {
        var re = try Regex.compile(gpa, "[\\d\\D]", .{});
        defer re.deinit();
        try testing.expect(re.match("5"));
        try testing.expect(re.match("a"));
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
                    try testing.expectEqual(Diagnostics.ParseError.invalid_class_range, parse_diag.err);
                    try testing.expectEqual(Span{ .start = 3, .end = 4 }, parse_diag.span);
                    try testing.expectEqual(Span{ .start = 1, .end = 2 }, parse_diag.aux_span.?);
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
                        try testing.expectEqual(@as(usize, 4), state_limit.limit);
                        try testing.expectEqual(@as(usize, 5), state_limit.count);
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

test {
    _ = @import("tests/regex_api.zig");
}
