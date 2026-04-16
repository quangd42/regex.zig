const std = @import("std");
const Allocator = std.mem.Allocator;

const Compiler = @import("Compiler.zig");
const engines = @import("engine.zig");
const PikeVm = engines.PikeVm;
const errors = @import("errors.zig");
pub const Diagnostics = errors.Diagnostics;
pub const Span = errors.Span;
/// Iterator over capture names in capture index order.
/// The first yielded item always corresponds to group 0, the full match, and is therefore `null`.
pub const NameIterator = @import("CaptureInfo.zig").NameIterator;
pub const Options = @import("Options.zig");
const Program = @import("Program.zig");
const results = @import("results.zig");
pub const Match = results.Match;
pub const Captures = results.Captures;

const Regex = @This();
prog: Program,
engine: PikeVm,

pub fn compile(gpa: Allocator, pattern: []const u8, options: Options) !Regex {
    const prog = try Compiler.compile(gpa, pattern, options);

    // TODO: choose engine based on pattern
    return .{ .prog = prog, .engine = try .init(gpa, prog) };
}

pub fn deinit(re: *Regex) void {
    re.engine.deinit();
}

/// Perform unanchored matching on the given haystack.
///
/// This answers the question "does this regex match the haystack anywhere?"
/// This is the cheapest query.
pub fn match(re: *Regex, haystack: []const u8) bool {
    return re.engine.match(.init(haystack));
}

/// Return the start and end indices of the left-most match in the haystack.
/// Return null when there is no match.
///
/// This answers the question "does this regex match the haystack and if so, where?"
/// It performs extra work to keep track of the boundary of the matched string in the
/// haystack, and is more expensive than `Regex.match()`.
pub fn find(re: *Regex, haystack: []const u8) ?Match {
    return re.engine.find(.init(haystack));
}

/// Search for a match and return capture groups of the left-most match in the haystack.
/// The first capture group (at index 0) is always the span of the whole match. Return
/// `null` if no match is found.
///
/// This answers the question: "does this regex match the haystack and if so, where? and
/// where are the capture groups?"
///
/// This is the most expensive query as the engine needs to keep track of multiple
/// capture group boundary sets.
///
/// The returned capture data becomes invalid after the next search on this same `Regex`,
/// including advancing to the next match in the case of the future `findAllCaptures`.
/// Use `Captures.copy(dest)` to persist the full capture list across later searches.
pub fn findCaptures(re: *Regex, haystack: []const u8) ?Captures {
    return re.engine.findCaptures(.init(haystack));
}

/// Returns the user-visible capture index for `name`, or `null` when the name does not exist.
pub fn captureIndex(re: *Regex, name: []const u8) ?usize {
    const index = re.prog.capture_info.indexOf(name) orelse return null;
    return index;
}

/// Returns an iterator over capture names in capture index order.
/// Unnamed captures, including group 0 for the full match, are yielded as `null`.
pub fn captureNames(re: *Regex) NameIterator {
    return re.prog.capture_info.names();
}

/// Returns the number of capture groups (including group 0 for the full match).
/// Useful to determine the required minimum size of buffer for `Captures.copy(dest)`.
pub fn captureCount(re: *Regex) usize {
    return re.prog.capture_info.count;
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;

test "usage: basic compile, match, find, findCaptures" {
    const gpa = testing.allocator;

    {
        var re = try Regex.compile(gpa, "color=(red|blue|)\\d", .{});
        defer re.deinit();

        try expect(re.match("color=red1"));
        try expect(re.match("color=blue2"));
        try expect(re.match("color=3"));
        try expect(!re.match("shade=green"));

        try expectEqual(Match{ .start = 3, .end = 14 }, re.find("id:color=blue2;").?);
        try expectEqual(Match{ .start = 2, .end = 12 }, re.find("x color=red1 y").?);
        try expectEqual(null, re.find("no colors here"));

        const capt1 = re.findCaptures("id:color=blue2;").?;
        try expectEqual(2, capt1.len());
        try expectEqual(Match{ .start = 3, .end = 14 }, capt1.get(0).?);
        try expectEqual(Match{ .start = 9, .end = 13 }, capt1.get(1).?);

        const capt2 = re.findCaptures("x color=red1 y").?;
        try expectEqual(2, capt2.len());
        try expectEqual(Match{ .start = 2, .end = 12 }, capt2.get(0).?);
        try expectEqual(Match{ .start = 8, .end = 11 }, capt2.get(1).?);

        const capt3 = re.findCaptures("x color=3 y").?;
        try expectEqual(2, capt3.len());
        try expectEqual(Match{ .start = 2, .end = 9 }, capt3.get(0).?);
        try expectEqual(Match{ .start = 8, .end = 8 }, capt3.get(1).?);

        try expectEqual(null, re.findCaptures("no colors here"));
    }
    {
        var re = try Regex.compile(gpa, "[\\d\\D]", .{});
        defer re.deinit();
        try expect(re.match("5"));
        try expect(re.match("a"));
    }
    {
        var re = try Regex.compile(gpa, "abc", .{
            .syntax = .{ .case_insensitive = true },
        });
        defer re.deinit();
        try expect(re.match("ABC"));
        try expectEqual(Match{ .start = 2, .end = 5 }, re.find("zzAbCzz").?);
    }
}

test "usage: error with diagnostics" {
    const gpa = testing.allocator;
    {
        const pattern = "[z-a]";
        var diag: Diagnostics = undefined;
        var re = Regex.compile(gpa, pattern, .{ .diag = &diag }) catch {
            switch (diag) {
                .parse => |parse_diag| {
                    try expectEqual(.class_range_invalid, parse_diag.err);
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
            .limits = .{ .max_states = 4 },
            .diag = &diag,
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

test "usage: named capture metadata and lookup" {
    const gpa = testing.allocator;

    var re = try Regex.compile(gpa, "(?<a>.(?<b>.))(.)(?:.)(?<c>.)", .{});
    defer re.deinit();

    // Capture names can be queried on the compiled regex.
    try expectEqual(1, re.captureIndex("a"));
    try expectEqual(2, re.captureIndex("b"));
    try expectEqual(4, re.captureIndex("c"));
    try expectEqual(null, re.captureIndex("missing"));

    // Capture names can also be iterated in capture index order.
    var names = re.captureNames();
    const expected_names = [_]?[]const u8{ null, "a", "b", null, "c" };
    for (expected_names) |expected_name| {
        const actual_name = names.next() orelse return error.TestUnexpectedResult;
        if (expected_name) |name| {
            try expectEqualStrings(name, actual_name.?);
        } else {
            try expect(actual_name == null);
        }
    }
    try expectEqual(null, names.next());

    // Named captures can be accessed directly from a match result.
    const haystack = "abXYZ";
    const caps = re.findCaptures(haystack).?;
    try expectEqualStrings("ab", caps.name("a").?.bytes(haystack));
    try expectEqualStrings("b", caps.name("b").?.bytes(haystack));
    try expectEqualStrings("Z", caps.name("c").?.bytes(haystack));
    try expectEqual(null, caps.name("missing"));
}
