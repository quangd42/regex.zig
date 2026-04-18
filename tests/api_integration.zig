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
        var re = try Regex.compile(gpa, "a{2,4}?", .{});
        defer re.deinit();
        try expectEqual(Match{ .start = 0, .end = 2 }, re.find("aaaa").?);
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

test "captures" {
    var re = try Regex.compile(gpa, "(ab)(d)?", .{});
    defer re.deinit();

    try expectEqual(3, re.captureCount());

    const maybe_caps = re.findCaptures("zabx");
    try expect(maybe_caps != null);

    const caps = maybe_caps.?;
    const ab_match: ?Match = .{ .start = 1, .end = 3 };
    try expectEqual(3, caps.len());
    try expectEqual(ab_match, caps.get(0));
    try expectEqual(ab_match, caps.get(1));
    try expectEqual(null, caps.get(2));

    // Preserve capture data
    var buf = [_]?Match{null} ** 3;
    const copied = caps.copy(&buf);

    _ = re.find("no match here");

    try expectEqual(3, copied.len);
    try expectEqual(Match{ .start = 1, .end = 3 }, copied[0].?);
    try expectEqual(Match{ .start = 1, .end = 3 }, copied[1].?);
    try expectEqual(null, copied[2]);
}

test "find*In with search window" {
    var re = try Regex.compile(gpa, "(ab)", .{});
    defer re.deinit();

    const yes = Regex.Input.init("zabx", .{ .start = 1, .end = 3, .anchored = true });
    try expect(re.matchIn(yes));
    try expectEqual(Match{ .start = 1, .end = 3 }, re.findIn(yes).?);

    const caps = re.findCapturesIn(yes).?;
    try expectEqual(Match{ .start = 1, .end = 3 }, caps.get(0).?);
    try expectEqual(Match{ .start = 1, .end = 3 }, caps.get(1).?);

    const no = Regex.Input.init("zabx", .{ .start = 0, .end = 2, .anchored = true });
    try expect(!re.matchIn(no));
    try expectEqual(null, re.findIn(no));
    try expectEqual(null, re.findCapturesIn(no));
}

test "named capture metadata and lookup" {
    var re = try Regex.compile(gpa, "(?<a>.(?<b>.))(.)(?:.)(?<c>.)", .{});
    defer re.deinit();

    const index_cases = [_]struct {
        name: []const u8,
        expected: ?usize,
    }{
        .{ .name = "a", .expected = 1 },
        .{ .name = "b", .expected = 2 },
        .{ .name = "c", .expected = 4 },
        .{ .name = "missing", .expected = null },
    };
    for (index_cases) |tc| {
        try expectEqual(tc.expected, re.captureIndex(tc.name));
    }

    var names = re.captureNames();
    const expected_names = [_]?[]const u8{ null, "a", "b", null, "c" };
    for (expected_names) |expected_name| {
        const actual_name = names.next() orelse return error.TestUnexpectedResult;
        if (expected_name) |name| {
            try expect(actual_name != null);
            try expectEqualStrings(name, actual_name.?);
        } else {
            try expect(actual_name == null);
        }
    }
    try expectEqual(null, names.next());

    const haystack = "abXYZ";
    const caps = re.findCaptures(haystack).?;
    const capture_cases = [_]struct {
        name: []const u8,
        span: Match,
        text: []const u8,
    }{
        .{ .name = "a", .span = .{ .start = 0, .end = 2 }, .text = "ab" },
        .{ .name = "b", .span = .{ .start = 1, .end = 2 }, .text = "b" },
        .{ .name = "c", .span = .{ .start = 4, .end = 5 }, .text = "Z" },
    };
    for (capture_cases) |tc| {
        const actual = caps.name(tc.name) orelse return error.TestUnexpectedResult;
        try expectEqual(tc.span, actual);
        try expectEqualStrings(tc.text, actual.bytes(haystack));
    }
    try expectEqual(null, caps.name("missing"));
}

test "named captures can be absent in a match" {
    var re = try Regex.compile(gpa, "(?<letters>[A-Za-z]+)(?:(?<digits>\\d+)|(?<punct>[!?]+))", .{});
    defer re.deinit();

    const cases = [_]struct {
        haystack: []const u8,
        full: []const u8,
        letters: []const u8,
        digits: ?[]const u8,
        punct: ?[]const u8,
    }{
        .{ .haystack = "abc123", .full = "abc123", .letters = "abc", .digits = "123", .punct = null },
        .{ .haystack = "abc!!", .full = "abc!!", .letters = "abc", .digits = null, .punct = "!!" },
    };

    for (cases) |tc| {
        const caps = re.findCaptures(tc.haystack).?;
        try expectEqualStrings(tc.full, caps.get(0).?.bytes(tc.haystack));
        try expectEqualStrings(tc.letters, caps.name("letters").?.bytes(tc.haystack));

        if (tc.digits) |digits| {
            try expectEqualStrings(digits, caps.name("digits").?.bytes(tc.haystack));
        } else {
            try expectEqual(null, caps.name("digits"));
        }

        if (tc.punct) |punct| {
            try expectEqualStrings(punct, caps.name("punct").?.bytes(tc.haystack));
        } else {
            try expectEqual(null, caps.name("punct"));
        }
    }
}

test "duplicate named captures" {
    const pattern = "(?<x>a)(?P<x>b)";

    var diag: Diagnostics = undefined;
    try expectError(error.Parse, Regex.compile(gpa, pattern, .{
        .diag = &diag,
    }));

    switch (diag) {
        .parse => |parse_diag| {
            try expectEqual(.group_name_duplicated, parse_diag.err);
            try expectEqual(Span{ .start = 11, .end = 12 }, parse_diag.span);
            try expectEqual(Span{ .start = 3, .end = 4 }, parse_diag.aux_span);
            try expect(parse_diag.span.isValidFor(pattern.len));
        },
        .compile => return error.TestUnexpectedResult,
    }
}

test "non capturing groups" {
    {
        var re = try Regex.compile(gpa, "(?i)Re", .{});
        defer re.deinit();
        try expect(re.match("rE"));
        try expect(re.match("re"));
    }
    {
        var re = try Regex.compile(gpa, "(?i:Re)", .{});
        defer re.deinit();
        try expect(re.match("rE"));
        try expect(re.match("re"));
    }
    {
        var re = try Regex.compile(gpa, "(?i)(?-i:Re)", .{});
        defer re.deinit();
        try expect(!re.match("rE"));
        try expect(!re.match("re"));
    }
    {
        var re = try Regex.compile(gpa, "(?m:^re$)", .{});
        defer re.deinit();
        try expect(re.match("ab\nre\ncd"));
        try expect(re.match("re"));
    }
    {
        var re = try Regex.compile(gpa, "(?sm:^re.l)", .{});
        defer re.deinit();
        try expect(re.match("ab\nre\nld"));
        try expect(re.match("real"));
    }
    {
        var re = try Regex.compile(gpa, "(?U:^re+)", .{});
        defer re.deinit();
        try expectEqual(Match{ .start = 0, .end = 2 }, re.find("reeee"));
    }
}

test "syntax options" {
    {
        var re = try Regex.compile(gpa, "^ab$", .{
            .syntax = .{ .multi_line = true },
        });
        defer re.deinit();
        try expectEqual(Match{ .start = 3, .end = 5 }, re.find("zz\nab\nyy").?);
    }
    {
        var re = try Regex.compile(gpa, "a+", .{
            .syntax = .{ .swap_greed = true },
        });
        defer re.deinit();
        try expectEqual(Match{ .start = 0, .end = 1 }, re.find("aa").?);
    }
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

test "dot matches new line option" {
    {
        var re = try Regex.compile(gpa, ".", .{});
        defer re.deinit();
        try expect(re.match("a"));
        try expect(!re.match("\n"));
    }
    {
        var re = try Regex.compile(gpa, ".", .{ .syntax = .{ .dot_matches_new_line = true } });
        defer re.deinit();
        try expect(re.match("a"));
        try expect(re.match("\n"));
    }
    {
        var re = try Regex.compile(gpa, "a.b", .{});
        defer re.deinit();
        try expect(!re.match("a\nb"));
    }
    {
        var re = try Regex.compile(gpa, "a.b", .{ .syntax = .{ .dot_matches_new_line = true } });
        defer re.deinit();
        try expect(re.match("a\nb"));
    }
}

test "ignore case option" {
    {
        var re = try Regex.compile(gpa, "\\Aabc\\z", .{});
        defer re.deinit();
        try expect(!re.match("ABC"));
    }
    {
        var re = try Regex.compile(gpa, "\\Aabc\\z", .{ .syntax = .{ .case_insensitive = true } });
        defer re.deinit();
        try expect(re.match("ABC"));
    }
    {
        var re = try Regex.compile(gpa, "\\A[a-z]+\\z", .{});
        defer re.deinit();
        try expect(!re.match("AB"));
    }
    {
        var re = try Regex.compile(gpa, "\\A[a-z]+\\z", .{ .syntax = .{ .case_insensitive = true } });
        defer re.deinit();
        try expect(re.match("AB"));
    }
    {
        var re = try Regex.compile(gpa, "\\A[[:^lower:]]+\\z", .{});
        defer re.deinit();
        try expect(re.match("AZ"));
    }
    {
        var re = try Regex.compile(gpa, "\\A[[:^lower:]]+\\z", .{ .syntax = .{ .case_insensitive = true } });
        defer re.deinit();
        try expect(!re.match("AZ"));
    }
    {
        var re = try Regex.compile(gpa, "\\A\\w+\\z", .{ .syntax = .{ .case_insensitive = true } });
        defer re.deinit();
        try expect(re.match("aZ_0"));
    }
    {
        var re = try Regex.compile(gpa, "\\A\\W+\\z", .{ .syntax = .{ .case_insensitive = true } });
        defer re.deinit();
        try expect(re.match("!@"));
        try expect(!re.match("AZ"));
    }
    {
        var re = try Regex.compile(gpa, "\\A[[:lower:]]+\\z", .{});
        defer re.deinit();
        try expect(!re.match("AB"));
    }
    {
        var re = try Regex.compile(gpa, "\\A[[:lower:]]+\\z", .{ .syntax = .{ .case_insensitive = true } });
        defer re.deinit();
        try expect(re.match("AB"));
    }
    {
        var re = try Regex.compile(gpa, "\\A[[:upper:]]+\\z", .{});
        defer re.deinit();
        try expect(!re.match("ab"));
    }
    {
        var re = try Regex.compile(gpa, "\\A[[:upper:]]+\\z", .{ .syntax = .{ .case_insensitive = true } });
        defer re.deinit();
        try expect(re.match("ab"));
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
            try expectEqual(.class_range_invalid, parse_diag.err);
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
            try expectEqual(.repeat_size_invalid, parse_diag.err);
            try expectEqual(Span{ .start = 2, .end = 3 }, parse_diag.span);
            try expectEqual(null, parse_diag.aux_span);
            try expect(parse_diag.span.isValidFor(pattern.len));
        },
        .compile => return error.TestUnexpectedResult,
    }
}

test "max_states limit" {
    const pattern = "ab";
    // The limit is inclusive: exactly 5 states is allowed.
    {
        var re = try Regex.compile(gpa, pattern, .{
            .limits = .{ .max_states = 5 },
        });
        defer re.deinit();
        try expect(re.match(pattern));
    }
    // Over limit with diag reporting
    {
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
    // Over limit without diag reporting
    {
        try expectError(error.Compile, Regex.compile(gpa, pattern, .{
            .limits = .{ .max_states = 4 },
        }));
    }
    // Limits larger than the compiler's intrinsic state-id range are rejected.
    {
        var diag: Diagnostics = undefined;
        try expectError(error.Compile, Regex.compile(gpa, pattern, .{
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
}

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const gpa = testing.allocator;

const export_test = @import("export_test");
const Regex = export_test.Regex;
const Match = Regex.Match;
const Diagnostics = export_test.Diagnostics;
const Span = export_test.Span;
