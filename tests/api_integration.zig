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

test "named capture metadata and lookup" {
    var re = try Regex.compile(gpa, "(?<a>.(?<b>.))(.)(?:.)(?<c>.)", .{});
    defer re.deinit();

    try expectEqual(@as(?usize, 1), re.captureIndex("a"));
    try expectEqual(@as(?usize, 2), re.captureIndex("b"));
    try expectEqual(@as(?usize, 4), re.captureIndex("c"));
    try expectEqual(@as(?usize, null), re.captureIndex("missing"));

    const err = error.TestUnexpectedResult;
    var names = re.captureNames();
    const name0 = names.next() orelse return err;
    try expect(name0 == null);
    try expectEqualStrings("a", (names.next() orelse return err).?);
    try expectEqualStrings("b", (names.next() orelse return err).?);
    const name3 = names.next() orelse return err;
    try expect(name3 == null);
    try expectEqualStrings("c", (names.next() orelse return err).?);
    try expectEqual(null, names.next());

    const caps = re.findCaptures("abXYZ").?;
    try expectEqual(Match{ .start = 0, .end = 2 }, caps.name("a").?);
    try expectEqual(Match{ .start = 1, .end = 2 }, caps.name("b").?);
    try expectEqual(Match{ .start = 4, .end = 5 }, caps.name("c").?);
    try expectEqualStrings("ab", caps.name("a").?.bytes("abXYZ"));
    try expectEqualStrings("b", caps.name("b").?.bytes("abXYZ"));
    try expectEqualStrings("Z", caps.name("c").?.bytes("abXYZ"));
    try expectEqual(null, caps.name("missing"));
}

test "named captures can be absent in a match" {
    var re = try Regex.compile(gpa, "(?<letters>[A-Za-z]+)(?:(?<digits>\\d+)|(?<punct>[!?]+))", .{});
    defer re.deinit();

    {
        const caps = re.findCaptures("abc123").?;
        try expectEqualStrings("abc123", caps.get(0).?.bytes("abc123"));
        try expectEqualStrings("abc", caps.name("letters").?.bytes("abc123"));
        try expectEqualStrings("123", caps.name("digits").?.bytes("abc123"));
        try expectEqual(null, caps.name("punct"));
    }
    {
        const caps = re.findCaptures("abc!!").?;
        try expectEqualStrings("abc", caps.name("letters").?.bytes("abc!!"));
        try expectEqualStrings("!!", caps.name("punct").?.bytes("abc!!"));
        try expectEqual(null, caps.name("digits"));
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

test "flag options and scoping" {
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
    {
        var re = try Regex.compile(gpa, "a+?", .{
            .syntax = .{ .swap_greed = true },
        });
        defer re.deinit();
        try expectEqual(Match{ .start = 0, .end = 2 }, re.find("aa").?);
    }
    {
        var re = try Regex.compile(gpa, "a(?-i)b", .{
            .syntax = .{ .case_insensitive = true },
        });
        defer re.deinit();
        try expect(re.match("Ab"));
        try expect(!re.match("AB"));
    }
    {
        var re = try Regex.compile(gpa, ".(?-s:.)", .{
            .syntax = .{ .dot_matches_new_line = true },
        });
        defer re.deinit();
        try expect(re.match("\na"));
        try expect(!re.match("\n\n"));
    }
    {
        var re = try Regex.compile(gpa, "a(?i)b", .{});
        defer re.deinit();
        try expect(re.match("aB"));
        try expect(!re.match("AB"));
    }
    {
        var re = try Regex.compile(gpa, "(?i)(?-i:ab)C", .{});
        defer re.deinit();
        try expect(re.match("abC"));
        try expect(re.match("abc"));
        try expect(!re.match("AbC"));
    }
    {
        var re = try Regex.compile(gpa, "(?-m:^ab$)|^cd$", .{
            .syntax = .{ .multi_line = true },
        });
        defer re.deinit();
        try expectEqual(Match{ .start = 3, .end = 5 }, re.find("ab\ncd").?);
    }
    {
        var re = try Regex.compile(gpa, "(?s-i:a.)", .{
            .syntax = .{ .case_insensitive = true },
        });
        defer re.deinit();
        try expect(re.match("a\n"));
        try expect(!re.match("A\n"));
    }
}

test "captures through flagged groups" {
    {
        var re = try Regex.compile(gpa, "(?i:(ab))c", .{});
        defer re.deinit();

        const caps = re.findCaptures("ABc").?;
        try expectEqual(Match{ .start = 0, .end = 3 }, caps.get(0).?);
        try expectEqual(Match{ .start = 0, .end = 2 }, caps.get(1).?);
    }
    {
        var re = try Regex.compile(gpa, "(?i:(?:x(ab)))c", .{});
        defer re.deinit();

        const caps = re.findCaptures("XABc").?;
        try expectEqual(Match{ .start = 0, .end = 4 }, caps.get(0).?);
        try expectEqual(Match{ .start = 1, .end = 3 }, caps.get(1).?);
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
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const gpa = testing.allocator;

const export_test = @import("export_test");
const Regex = export_test.Regex;
const Match = Regex.Match;
const Diagnostics = export_test.Diagnostics;
const Span = export_test.Span;
