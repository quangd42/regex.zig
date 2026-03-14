const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;

const Regex = @import("../Regex.zig");
const Match = Regex.Match;

const errors = @import("../errors.zig");
const Diagnostics = errors.Diagnostics;
const Span = errors.Span;

test "testdata" {
    _ = @import("fowler_basic.zig");
}

test "basic end-to-end" {
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
        var re = try Regex.compile(gpa, "a\\D", .{});
        defer re.deinit();
        try testing.expect(re.match("aa"));
        try testing.expect(!re.match("a1"));
    }
    {
        var re = try Regex.compile(gpa, "^r\\D$", .{});
        defer re.deinit();
        try testing.expect(re.match("re"));
        try testing.expect(!re.match("aarebb"));
    }
    {
        var re = try Regex.compile(gpa, "word\\b", .{});
        defer re.deinit();
        try testing.expect(re.match("sword"));
        try testing.expect(!re.match("swordfish"));
    }
}

test "basic empty matches" {
    {
        var re = try Regex.compile(gpa, "|a", .{});
        defer re.deinit();
        const found = re.find("abc");
        try testing.expect(found != null);
        try testing.expectEqual(Match{ .start = 0, .end = 0 }, found.?);
    }
    {
        var re = try Regex.compile(gpa, "a|", .{});
        defer re.deinit();
        const found = re.find("abc");
        try testing.expect(found != null);
        try testing.expectEqual(Match{ .start = 0, .end = 1 }, found.?);
    }
    {
        var re = try Regex.compile(gpa, "b|", .{});
        defer re.deinit();
        const found = re.find("abc");
        try testing.expect(found != null);
        try testing.expectEqual(Match{ .start = 0, .end = 0 }, found.?);
    }
}

test "character class with perl items" {
    {
        var re = try Regex.compile(gpa, "[\\D]", .{});
        defer re.deinit();
        try testing.expect(re.match("a"));
        try testing.expect(!re.match("5"));
    }
    {
        var re = try Regex.compile(gpa, "[^\\D]", .{});
        defer re.deinit();
        try testing.expect(re.match("5"));
        try testing.expect(!re.match("a"));
    }
    {
        var re = try Regex.compile(gpa, "[\\d\\D]", .{});
        defer re.deinit();
        try testing.expect(re.match("5"));
        try testing.expect(re.match("a"));
    }
    {
        var re = try Regex.compile(gpa, "[^\\d\\D]", .{});
        defer re.deinit();
        try testing.expect(!re.match("5"));
        try testing.expect(!re.match("a"));
    }
}

test "diag parse err" {
    const pattern = "[z-a]";

    var diag: Diagnostics = undefined;
    try testing.expectError(error.Parse, Regex.compile(gpa, pattern, .{
        .diagnostics = &diag,
    }));

    switch (diag) {
        .parse => |parse_diag| {
            try testing.expectEqual(Diagnostics.ParseError.invalid_class_range, parse_diag.err);
            try testing.expectEqual(Span{ .start = 3, .end = 4 }, parse_diag.span);
            try testing.expectEqual(Span{ .start = 1, .end = 2 }, parse_diag.aux_span.?);
            try testing.expect(parse_diag.span.isValidFor(pattern.len));
            try testing.expect(parse_diag.aux_span.?.isValidFor(pattern.len));
        },
        .compile => return error.TestUnexpectedResult,
    }
}

test "parse err no diag" {
    try testing.expectError(error.Parse, Regex.compile(gpa, "[z-a]", .{}));
}

test "diag repeat limit" {
    const pattern = "a{4}";

    var diag: Diagnostics = undefined;
    try testing.expectError(error.Parse, Regex.compile(gpa, pattern, .{
        .limits = .{ .repeat_size = 3 },
        .diagnostics = &diag,
    }));

    switch (diag) {
        .parse => |parse_diag| {
            try testing.expectEqual(Diagnostics.ParseError.invalid_repeat_size, parse_diag.err);
            try testing.expectEqual(Span{ .start = 2, .end = 3 }, parse_diag.span);
            try testing.expectEqual(null, parse_diag.aux_span);
            try testing.expect(parse_diag.span.isValidFor(pattern.len));
        },
        .compile => return error.TestUnexpectedResult,
    }
}

test "diag state limit" {
    const pattern = "ab";

    var diag: Diagnostics = undefined;
    try testing.expectError(error.Compile, Regex.compile(gpa, pattern, .{
        .limits = .{ .states_count = 4 },
        .diagnostics = &diag,
    }));

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
}

test "state limit no diag" {
    try testing.expectError(error.Compile, Regex.compile(gpa, "ab", .{
        .limits = .{ .states_count = 4 },
    }));
}

test "diag invalid state limit" {
    var diag: Diagnostics = undefined;
    try testing.expectError(error.Compile, Regex.compile(gpa, "ab", .{
        .limits = .{ .states_count = std.math.maxInt(usize) },
        .diagnostics = &diag,
    }));

    switch (diag) {
        .compile => |compile_diag| switch (compile_diag) {
            .invalid_state_limit => |invalid_limit| {
                try testing.expectEqual(std.math.maxInt(usize), invalid_limit);
            },
            else => return error.TestUnexpectedResult,
        },
        .parse => return error.TestUnexpectedResult,
    }
}
