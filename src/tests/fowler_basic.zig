const std = @import("std");

const Regex = @import("../Regex.zig");
const Match = Regex.Match;

const Case = struct {
    name: []const u8,
    pattern: []const u8,
    haystack: []const u8,
    expected: []const ?Match,
};

const cases = [_]Case{
    .{
        .name = "basic133",
        .pattern = "(a*)*",
        .haystack = "-",
        .expected = &[_]?Match{ .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 } },
    },
};

const all_cases = [_]Case{
    .{
        .name = "basic5",
        .pattern = "XXXXXX",
        .haystack = "..XXXXXX",
        .expected = &[_]?Match{.{ .start = 2, .end = 8 }},
    },
    .{
        .name = "basic4",
        .pattern = "a...b",
        .haystack = "abababbb",
        .expected = &[_]?Match{.{ .start = 2, .end = 7 }},
    },
    .{
        .name = "basic45",
        .pattern = "aba|bab|bba",
        .haystack = "baaabbbaba",
        .expected = &[_]?Match{.{ .start = 5, .end = 8 }},
    },
    .{
        .name = "basic46",
        .pattern = "aba|bab",
        .haystack = "baaabbbaba",
        .expected = &[_]?Match{.{ .start = 6, .end = 9 }},
    },
    .{
        .name = "basic55",
        .pattern = ":::1:::0:|:::1:1:0:",
        .haystack = ":::0:::1:::1:::0:",
        .expected = &[_]?Match{.{ .start = 8, .end = 17 }},
    },
    .{
        .name = "basic56",
        .pattern = ":::1:::0:|:::1:1:1:",
        .haystack = ":::0:::1:::1:::0:",
        .expected = &[_]?Match{.{ .start = 8, .end = 17 }},
    },
    .{
        .name = "basic70",
        .pattern = "xxx",
        .haystack = "xxx",
        .expected = &[_]?Match{.{ .start = 0, .end = 3 }},
    },
    .{
        .name = "basic82",
        .pattern = "abaa|abbaa|abbbaa|abbbbaa",
        .haystack = "ababbabbbabbbabbbbabbbbaa",
        .expected = &[_]?Match{.{ .start = 18, .end = 25 }},
    },
    .{
        .name = "basic83",
        .pattern = "abaa|abbaa|abbbaa|abbbbaa",
        .haystack = "ababbabbbabbbabbbbabaa",
        .expected = &[_]?Match{.{ .start = 18, .end = 22 }},
    },
    .{
        .name = "basic84",
        .pattern = "aaac|aabc|abac|abbc|baac|babc|bbac|bbbc",
        .haystack = "baaabbbabac",
        .expected = &[_]?Match{.{ .start = 7, .end = 11 }},
    },
    .{
        .name = "basic87",
        .pattern = "aaaa|bbbb|cccc|ddddd|eeeeee|fffffff|gggg|hhhh|iiiii|jjjjj|kkkkk|llll",
        .haystack = "XaaaXbbbXcccXdddXeeeXfffXgggXhhhXiiiXjjjXkkkXlllXcbaXaaaa",
        .expected = &[_]?Match{.{ .start = 53, .end = 57 }},
    },
    .{
        .name = "basic94",
        .pattern = "abc",
        .haystack = "abc",
        .expected = &[_]?Match{.{ .start = 0, .end = 3 }},
    },
    .{
        .name = "basic95",
        .pattern = "abc",
        .haystack = "xabcy",
        .expected = &[_]?Match{.{ .start = 1, .end = 4 }},
    },
    .{
        .name = "basic96",
        .pattern = "abc",
        .haystack = "ababc",
        .expected = &[_]?Match{.{ .start = 2, .end = 5 }},
    },
    .{
        .name = "basic97",
        .pattern = "ab*c",
        .haystack = "abc",
        .expected = &[_]?Match{.{ .start = 0, .end = 3 }},
    },
    .{
        .name = "basic98",
        .pattern = "ab*bc",
        .haystack = "abc",
        .expected = &[_]?Match{.{ .start = 0, .end = 3 }},
    },
    .{
        .name = "basic99",
        .pattern = "ab*bc",
        .haystack = "abbc",
        .expected = &[_]?Match{.{ .start = 0, .end = 4 }},
    },
    .{
        .name = "basic100",
        .pattern = "ab*bc",
        .haystack = "abbbbc",
        .expected = &[_]?Match{.{ .start = 0, .end = 6 }},
    },
    .{
        .name = "basic101",
        .pattern = "ab+bc",
        .haystack = "abbc",
        .expected = &[_]?Match{.{ .start = 0, .end = 4 }},
    },
    .{
        .name = "basic102",
        .pattern = "ab+bc",
        .haystack = "abbbbc",
        .expected = &[_]?Match{.{ .start = 0, .end = 6 }},
    },
    .{
        .name = "basic103",
        .pattern = "ab?bc",
        .haystack = "abbc",
        .expected = &[_]?Match{.{ .start = 0, .end = 4 }},
    },
    .{
        .name = "basic104",
        .pattern = "ab?bc",
        .haystack = "abc",
        .expected = &[_]?Match{.{ .start = 0, .end = 3 }},
    },
    .{
        .name = "basic105",
        .pattern = "ab?c",
        .haystack = "abc",
        .expected = &[_]?Match{.{ .start = 0, .end = 3 }},
    },
    .{
        .name = "basic111",
        .pattern = "a.c",
        .haystack = "abc",
        .expected = &[_]?Match{.{ .start = 0, .end = 3 }},
    },
    .{
        .name = "basic112",
        .pattern = "a.c",
        .haystack = "axc",
        .expected = &[_]?Match{.{ .start = 0, .end = 3 }},
    },
    .{
        .name = "basic113",
        .pattern = "a.*c",
        .haystack = "axyzc",
        .expected = &[_]?Match{.{ .start = 0, .end = 5 }},
    },
    .{
        .name = "basic124",
        .pattern = "ab|cd",
        .haystack = "abc",
        .expected = &[_]?Match{.{ .start = 0, .end = 2 }},
    },
    .{
        .name = "basic125",
        .pattern = "ab|cd",
        .haystack = "abcd",
        .expected = &[_]?Match{.{ .start = 0, .end = 2 }},
    },
    .{
        .name = "basic131",
        .pattern = "a+b+c",
        .haystack = "aabbabc",
        .expected = &[_]?Match{.{ .start = 4, .end = 7 }},
    },
    .{
        .name = "basic132",
        .pattern = "a*",
        .haystack = "aaa",
        .expected = &[_]?Match{.{ .start = 0, .end = 3 }},
    },
    // .{
    //     .name = "basic133",
    //     .pattern = "(a*)*",
    //     .haystack = "-",
    //     .expected = &[_]?Match{ .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 } },
    // },
    // .{
    //     .name = "basic134",
    //     .pattern = "(a*)+",
    //     .haystack = "-",
    //     .expected = &[_]?Match{ .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 } },
    // },
    // .{
    //     .name = "basic135",
    //     .pattern = "(a*|b)*",
    //     .haystack = "-",
    //     .expected = &[_]?Match{ .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 } },
    // },
    .{
        .name = "basic136",
        .pattern = "(a+|b)*",
        .haystack = "ab",
        .expected = &[_]?Match{ .{ .start = 0, .end = 2 }, .{ .start = 1, .end = 2 } },
    },
    .{
        .name = "basic137",
        .pattern = "(a+|b)+",
        .haystack = "ab",
        .expected = &[_]?Match{ .{ .start = 0, .end = 2 }, .{ .start = 1, .end = 2 } },
    },
    .{
        .name = "basic138",
        .pattern = "(a+|b)?",
        .haystack = "ab",
        .expected = &[_]?Match{ .{ .start = 0, .end = 1 }, .{ .start = 0, .end = 1 } },
    },
    .{
        .name = "basic141",
        .pattern = "a*",
        .haystack = "",
        .expected = &[_]?Match{.{ .start = 0, .end = 0 }},
    },
    .{
        .name = "basic144",
        .pattern = "a|b|c|d|e",
        .haystack = "e",
        .expected = &[_]?Match{.{ .start = 0, .end = 1 }},
    },
    .{
        .name = "basic166",
        .pattern = "(((((((((a)))))))))",
        .haystack = "a",
        .expected = &[_]?Match{.{ .start = 0, .end = 1 }} ** 10,
    },
    .{
        .name = "basic167",
        .pattern = "multiple words",
        .haystack = "multiple words yeah",
        .expected = &[_]?Match{.{ .start = 0, .end = 14 }},
    },
    .{
        .name = "basic169",
        .pattern = "abcd",
        .haystack = "abcd",
        .expected = &[_]?Match{.{ .start = 0, .end = 4 }},
    },
    .{
        .name = "basic170",
        .pattern = "a(bc)d",
        .haystack = "abcd",
        .expected = &[_]?Match{ .{ .start = 0, .end = 4 }, .{ .start = 1, .end = 3 } },
    },
    .{
        .name = "basic26",
        .pattern = "(ab|a)(bc|c)",
        .haystack = "zabcx",
        .expected = &[_]?Match{ .{ .start = 1, .end = 4 }, .{ .start = 1, .end = 3 }, .{ .start = 3, .end = 4 } },
    },
    .{
        .name = "basic27",
        .pattern = "(ab)c|abc",
        .haystack = "abc",
        .expected = &[_]?Match{ .{ .start = 0, .end = 3 }, .{ .start = 0, .end = 2 } },
    },
    .{
        .name = "basic32",
        .pattern = "((a|a)|a)",
        .haystack = "a",
        .expected = &[_]?Match{ .{ .start = 0, .end = 1 }, .{ .start = 0, .end = 1 }, .{ .start = 0, .end = 1 } },
    },
    .{
        .name = "basic35",
        .pattern = "a(b)|c(d)|a(e)f",
        .haystack = "aef",
        .expected = &[_]?Match{ .{ .start = 0, .end = 3 }, null, null, .{ .start = 1, .end = 2 } },
    },
    .{
        .name = "basic37",
        .pattern = "(a|b)c|a(b|c)",
        .haystack = "ac",
        .expected = &[_]?Match{ .{ .start = 0, .end = 2 }, .{ .start = 0, .end = 1 }, null },
    },
    .{
        .name = "basic38",
        .pattern = "(a|b)c|a(b|c)",
        .haystack = "ab",
        .expected = &[_]?Match{ .{ .start = 0, .end = 2 }, null, .{ .start = 1, .end = 2 } },
    },
    .{
        .name = "basic44",
        .pattern = "ab|abab",
        .haystack = "abbabab",
        .expected = &[_]?Match{.{ .start = 0, .end = 2 }},
    },
    .{
        .name = "basic34",
        .pattern = "a*(a.|aa)",
        .haystack = "aaaa",
        .expected = &[_]?Match{ .{ .start = 0, .end = 4 }, .{ .start = 2, .end = 4 } },
    },
    .{
        .name = "basic41",
        .pattern = "(.a|.b).*|.*(.a|.b)",
        .haystack = "xa",
        .expected = &[_]?Match{ .{ .start = 0, .end = 2 }, .{ .start = 0, .end = 2 }, null },
    },
    .{
        .name = "basic48",
        .pattern = "(a.|.a.)*|(a|.a...)",
        .haystack = "aa",
        .expected = &[_]?Match{ .{ .start = 0, .end = 2 }, .{ .start = 0, .end = 2 }, null },
    },
    .{
        .name = "basic49",
        .pattern = "ab|a",
        .haystack = "xabc",
        .expected = &[_]?Match{.{ .start = 1, .end = 3 }},
    },
    .{
        .name = "basic50",
        .pattern = "ab|a",
        .haystack = "xxabc",
        .expected = &[_]?Match{.{ .start = 2, .end = 4 }},
    },
    .{
        .name = "basic69",
        .pattern = "(a)(b)(c)",
        .haystack = "abc",
        .expected = &[_]?Match{ .{ .start = 0, .end = 3 }, .{ .start = 0, .end = 1 }, .{ .start = 1, .end = 2 }, .{ .start = 2, .end = 3 } },
    },
    .{
        .name = "basic129",
        .pattern = "((a))",
        .haystack = "abc",
        .expected = &[_]?Match{ .{ .start = 0, .end = 1 }, .{ .start = 0, .end = 1 }, .{ .start = 0, .end = 1 } },
    },
    .{
        .name = "basic130",
        .pattern = "(a)b(c)",
        .haystack = "abc",
        .expected = &[_]?Match{ .{ .start = 0, .end = 3 }, .{ .start = 0, .end = 1 }, .{ .start = 2, .end = 3 } },
    },
    .{
        .name = "basic145",
        .pattern = "(a|b|c|d|e)f",
        .haystack = "ef",
        .expected = &[_]?Match{ .{ .start = 0, .end = 2 }, .{ .start = 0, .end = 1 } },
    },
    // .{
    //     .name = "basic146",
    //     .pattern = "((a*|b))*",
    //     .haystack = "-",
    //     .expected = &[_]?Match{ .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 } },
    // },
    .{
        .name = "basic147",
        .pattern = "abcd*efg",
        .haystack = "abcdefg",
        .expected = &[_]?Match{.{ .start = 0, .end = 7 }},
    },
    .{
        .name = "basic148",
        .pattern = "ab*",
        .haystack = "xabyabbbz",
        .expected = &[_]?Match{.{ .start = 1, .end = 3 }},
    },
    .{
        .name = "basic149",
        .pattern = "ab*",
        .haystack = "xayabbbz",
        .expected = &[_]?Match{.{ .start = 1, .end = 2 }},
    },
    .{
        .name = "basic150",
        .pattern = "(ab|cd)e",
        .haystack = "abcde",
        .expected = &[_]?Match{ .{ .start = 2, .end = 5 }, .{ .start = 2, .end = 4 } },
    },
    .{
        .name = "basic152",
        .pattern = "(a|b)c*d",
        .haystack = "abcd",
        .expected = &[_]?Match{ .{ .start = 1, .end = 4 }, .{ .start = 1, .end = 2 } },
    },
    .{
        .name = "basic153",
        .pattern = "(ab|ab*)bc",
        .haystack = "abc",
        .expected = &[_]?Match{ .{ .start = 0, .end = 3 }, .{ .start = 0, .end = 1 } },
    },
    // .{
    //     .name = "basic154",
    //     .pattern = "a([bc]*)c*",
    //     .haystack = "abc",
    //     .expected = &[_]?Match{ .{ .start = 0, .end = 3 }, .{ .start = 1, .end = 3 } },
    // },
    // .{
    //     .name = "basic155",
    //     .pattern = "a([bc]*)(c*d)",
    //     .haystack = "abcd",
    //     .expected = &[_]?Match{ .{ .start = 0, .end = 4 }, .{ .start = 1, .end = 3 }, .{ .start = 3, .end = 4 } },
    // },
    // .{
    //     .name = "basic156",
    //     .pattern = "a([bc]+)(c*d)",
    //     .haystack = "abcd",
    //     .expected = &[_]?Match{ .{ .start = 0, .end = 4 }, .{ .start = 1, .end = 3 }, .{ .start = 3, .end = 4 } },
    // },
    // .{
    //     .name = "basic157",
    //     .pattern = "a([bc]*)(c+d)",
    //     .haystack = "abcd",
    //     .expected = &[_]?Match{ .{ .start = 0, .end = 4 }, .{ .start = 1, .end = 2 }, .{ .start = 2, .end = 4 } },
    // },
    .{
        .name = "basic159",
        .pattern = "(ab|a)b*c",
        .haystack = "abc",
        .expected = &[_]?Match{ .{ .start = 0, .end = 3 }, .{ .start = 0, .end = 2 } },
    },
    .{
        .name = "basic160",
        .pattern = "((a)(b)c)(d)",
        .haystack = "abcd",
        .expected = &[_]?Match{ .{ .start = 0, .end = 4 }, .{ .start = 0, .end = 3 }, .{ .start = 0, .end = 1 }, .{ .start = 1, .end = 2 }, .{ .start = 3, .end = 4 } },
    },
    .{
        .name = "basic189",
        .pattern = "a+(b|c)*d+",
        .haystack = "aabcdd",
        .expected = &[_]?Match{ .{ .start = 0, .end = 6 }, .{ .start = 3, .end = 4 } },
    },
    .{
        .name = "basic197",
        .pattern = "((foo)|(bar))!bas",
        .haystack = "bar!bas",
        .expected = &[_]?Match{ .{ .start = 0, .end = 7 }, .{ .start = 0, .end = 3 }, null, .{ .start = 0, .end = 3 } },
    },
    .{
        .name = "basic198",
        .pattern = "((foo)|(bar))!bas",
        .haystack = "foo!bar!bas",
        .expected = &[_]?Match{ .{ .start = 4, .end = 11 }, .{ .start = 4, .end = 7 }, null, .{ .start = 4, .end = 7 } },
    },
    .{
        .name = "basic199",
        .pattern = "((foo)|(bar))!bas",
        .haystack = "foo!bas",
        .expected = &[_]?Match{ .{ .start = 0, .end = 7 }, .{ .start = 0, .end = 3 }, .{ .start = 0, .end = 3 }, null },
    },
    .{
        .name = "basic200",
        .pattern = "((foo)|bar)!bas",
        .haystack = "bar!bas",
        .expected = &[_]?Match{ .{ .start = 0, .end = 7 }, .{ .start = 0, .end = 3 }, null },
    },
    .{
        .name = "basic201",
        .pattern = "((foo)|bar)!bas",
        .haystack = "foo!bar!bas",
        .expected = &[_]?Match{ .{ .start = 4, .end = 11 }, .{ .start = 4, .end = 7 }, null },
    },
    .{
        .name = "basic202",
        .pattern = "((foo)|bar)!bas",
        .haystack = "foo!bas",
        .expected = &[_]?Match{ .{ .start = 0, .end = 7 }, .{ .start = 0, .end = 3 }, .{ .start = 0, .end = 3 } },
    },
    .{
        .name = "basic203",
        .pattern = "(foo|(bar))!bas",
        .haystack = "bar!bas",
        .expected = &[_]?Match{ .{ .start = 0, .end = 7 }, .{ .start = 0, .end = 3 }, .{ .start = 0, .end = 3 } },
    },
    .{
        .name = "basic204",
        .pattern = "(foo|(bar))!bas",
        .haystack = "foo!bar!bas",
        .expected = &[_]?Match{ .{ .start = 4, .end = 11 }, .{ .start = 4, .end = 7 }, .{ .start = 4, .end = 7 } },
    },
    .{
        .name = "basic205",
        .pattern = "(foo|(bar))!bas",
        .haystack = "foo!bas",
        .expected = &[_]?Match{ .{ .start = 0, .end = 7 }, .{ .start = 0, .end = 3 }, null },
    },
    .{
        .name = "basic206",
        .pattern = "(foo|bar)!bas",
        .haystack = "xxbar!bas",
        .expected = &[_]?Match{ .{ .start = 2, .end = 9 }, .{ .start = 2, .end = 5 } },
    },
    .{
        .name = "basic207",
        .pattern = "(foo|bar)!bas",
        .haystack = "foo!bar!bas",
        .expected = &[_]?Match{ .{ .start = 4, .end = 11 }, .{ .start = 4, .end = 7 } },
    },
    .{
        .name = "basic208",
        .pattern = "(foo|bar)!bas",
        .haystack = "foo!bas",
        .expected = &[_]?Match{ .{ .start = 0, .end = 7 }, .{ .start = 0, .end = 3 } },
    },
};

test "fowler basic subset" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const verbose = false;

    for (all_cases) |tc| {
        var re = try Regex.compile(gpa, tc.pattern);
        defer re.deinit();

        if (verbose) re.engine.prog.dumpDebug();

        if (!re.match(tc.haystack)) {
            std.debug.print("FAIL [{s}] match() returned false\n", .{tc.name});
            return error.TestUnexpectedResult;
        }

        const maybe_found = re.find(tc.haystack);
        if (maybe_found == null) {
            std.debug.print("FAIL [{s}] find() returned null\n", .{tc.name});
            return error.TestUnexpectedResult;
        }
        testing.expectEqual(tc.expected[0], maybe_found.?) catch {
            std.debug.print("  FAIL [{s}] find() mismatch\n", .{tc.name});
            return error.TestExpectedEqual;
        };

        const maybe_caps = try re.findCapturesAlloc(gpa, tc.haystack);
        if (maybe_caps == null) {
            std.debug.print("FAIL [{s}] findCaptures() returned null\n", .{tc.name});
            return error.TestUnexpectedResult;
        }

        var caps = maybe_caps.?;
        defer caps.deinit(gpa);

        testing.expectEqual(tc.expected.len, caps.groups.len) catch {
            std.debug.print("  FAIL [{s}] group count mismatch\n", .{tc.name});
            return error.TestExpectedEqual;
        };
        for (tc.expected, 0..) |value, i| {
            testing.expectEqual(value, caps.groups[i]) catch {
                std.debug.print("  FAIL [{s}] group[{d}] mismatch\n", .{ tc.name, i });
                return error.TestExpectedEqual;
            };
        }
        if (verbose) std.debug.print("{s} passed.\n", .{tc.name});
    }
}
