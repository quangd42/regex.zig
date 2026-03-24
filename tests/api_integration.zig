//! Smoke tests for public `Regex` API integration during development.
//! These are small end-to-end checks across parser, compiler, and engine layers.
test "basic end-to-end" {
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
        var re = try Regex.compile(gpa, "a\\D", .{});
        defer re.deinit();
        try expect(re.match("aa"));
        try expect(!re.match("a1"));
    }
    {
        var re = try Regex.compile(gpa, "^r\\D$", .{});
        defer re.deinit();
        try expect(re.match("re"));
        try expect(!re.match("aarebb"));
    }
    {
        var re = try Regex.compile(gpa, "word\\b", .{});
        defer re.deinit();
        try expect(re.match("sword"));
        try expect(!re.match("swordfish"));
    }
}

test "captures buffer api" {
    var re = try Regex.compile(gpa, "(ab)(d)?", .{});
    defer re.deinit();

    try expectEqual(3, re.capturesLen());

    var buffer = [_]?Match{null} ** 3;
    const maybe_caps = re.findCaptures("zabx", &buffer);
    try expect(maybe_caps != null);

    const caps = maybe_caps.?;
    const ab_match: ?Match = .{ .start = 1, .end = 3 };
    try expectEqual(3, caps.groups.len);
    try expectEqual(ab_match, caps.groups[0]);
    try expectEqual(ab_match, caps.groups[1]);
    try expectEqual(null, caps.groups[2]);
}

test "assertions" {
    {
        var re = try Regex.compile(gpa, "foo\\b", .{});
        defer re.deinit();
        try expect(re.match("foo"));
        try expect(!re.match("foobar"));
    }
    {
        var re = try Regex.compile(gpa, "\\B\\W", .{});
        defer re.deinit();
        try expect(re.match("!a"));
        try expect(!re.match("a!"));
    }
    {
        var re = try Regex.compile(gpa, "\\Aab", .{});
        defer re.deinit();
        try expect(re.match("ab"));
        try expect(!re.match("zab"));
        try expectEqual(Match{ .start = 0, .end = 2 }, re.find("ab").?);
        try expectEqual(null, re.find("zab"));
    }
    {
        var re = try Regex.compile(gpa, "ab\\z", .{});
        defer re.deinit();
        try expect(re.match("zab"));
        try expect(!re.match("abz"));
        try expectEqual(Match{ .start = 1, .end = 3 }, re.find("zab").?);
        try expectEqual(null, re.find("abz"));
    }
    {
        var re = try Regex.compile(gpa, "\\Aab\\z", .{});
        defer re.deinit();
        try expect(re.match("ab"));
        try expect(!re.match("zab"));
        try expect(!re.match("abz"));
    }
}

test "basic empty matches" {
    {
        var re = try Regex.compile(gpa, "|a", .{});
        defer re.deinit();
        const found = re.find("abc");
        try expect(found != null);
        try expectEqual(Match{ .start = 0, .end = 0 }, found.?);
    }
    {
        var re = try Regex.compile(gpa, "a|", .{});
        defer re.deinit();
        const found = re.find("abc");
        try expect(found != null);
        try expectEqual(Match{ .start = 0, .end = 1 }, found.?);
    }
    {
        var re = try Regex.compile(gpa, "b|", .{});
        defer re.deinit();
        const found = re.find("abc");
        try expect(found != null);
        try expectEqual(Match{ .start = 0, .end = 0 }, found.?);
    }
}

test "character class with perl items" {
    {
        var re = try Regex.compile(gpa, "[\\D]", .{});
        defer re.deinit();
        try expect(re.match("a"));
        try expect(!re.match("5"));
    }
    {
        var re = try Regex.compile(gpa, "[^\\D]", .{});
        defer re.deinit();
        try expect(re.match("5"));
        try expect(!re.match("a"));
    }
    {
        var re = try Regex.compile(gpa, "[\\d\\D]", .{});
        defer re.deinit();
        try expect(re.match("5"));
        try expect(re.match("a"));
    }
    {
        var re = try Regex.compile(gpa, "[^\\d\\D]", .{});
        defer re.deinit();
        try expect(!re.match("5"));
        try expect(!re.match("a"));
    }
}

test "diag parse err" {
    const pattern = "[z-a]";

    var diag: Diagnostics = undefined;
    try expectError(error.Parse, Regex.compile(gpa, pattern, .{
        .diag = &diag,
    }));

    switch (diag) {
        .parse => |parse_diag| {
            try expectEqual(.invalid_class_range, parse_diag.err);
            try expectEqual(Span{ .start = 3, .end = 4 }, parse_diag.span);
            try expectEqual(Span{ .start = 1, .end = 2 }, parse_diag.aux_span.?);
            try expect(parse_diag.span.isValidFor(pattern.len));
            try expect(parse_diag.aux_span.?.isValidFor(pattern.len));
        },
        .compile => return error.TestUnexpectedResult,
    }
}

test "parse err no diag" {
    try expectError(error.Parse, Regex.compile(gpa, "[z-a]", .{}));
}

test "diag repeat limit" {
    const pattern = "a{4}";

    var diag: Diagnostics = undefined;
    try expectError(error.Parse, Regex.compile(gpa, pattern, .{
        .limits = .{ .max_repeat = 3 },
        .diag = &diag,
    }));

    switch (diag) {
        .parse => |parse_diag| {
            try expectEqual(.invalid_repeat_size, parse_diag.err);
            try expectEqual(Span{ .start = 2, .end = 3 }, parse_diag.span);
            try expectEqual(null, parse_diag.aux_span);
            try expect(parse_diag.span.isValidFor(pattern.len));
        },
        .compile => return error.TestUnexpectedResult,
    }
}

test "diag state limit" {
    const pattern = "ab";

    var diag: Diagnostics = undefined;
    try expectError(error.Compile, Regex.compile(gpa, pattern, .{
        .limits = .{ .max_states = 4 },
        .diag = &diag,
    }));

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
}

test "state limit no diag" {
    try expectError(error.Compile, Regex.compile(gpa, "ab", .{
        .limits = .{ .max_states = 4 },
    }));
}

test "diag invalid state limit" {
    var diag: Diagnostics = undefined;
    try expectError(error.Compile, Regex.compile(gpa, "ab", .{
        .limits = .{ .max_states = std.math.maxInt(usize) },
        .diag = &diag,
    }));

    switch (diag) {
        .compile => |compile_diag| switch (compile_diag) {
            .invalid_state_limit => |invalid_limit| {
                try expectEqual(std.math.maxInt(usize), invalid_limit);
            },
            else => return error.TestUnexpectedResult,
        },
        .parse => return error.TestUnexpectedResult,
    }
}

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;
const gpa = testing.allocator;

const export_test = @import("export_test");
const Regex = export_test.Regex;
const Match = Regex.Match;
const Diagnostics = export_test.Diagnostics;
const Span = export_test.Span;
