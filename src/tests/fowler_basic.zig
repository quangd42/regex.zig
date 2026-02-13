const std = @import("std");

const Regex = @import("../Regex.zig");
const Match = Regex.Match;

const Case = struct {
    name: []const u8,
    pattern: []const u8,
    haystack: []const u8,
    start: usize,
    end: usize,
};

const cases = [_]Case{
    .{ .name = "basic5", .pattern = "XXXXXX", .haystack = "..XXXXXX", .start = 2, .end = 8 },
    .{ .name = "basic45", .pattern = "aba|bab|bba", .haystack = "baaabbbaba", .start = 5, .end = 8 },
    .{ .name = "basic46", .pattern = "aba|bab", .haystack = "baaabbbaba", .start = 6, .end = 9 },
    .{ .name = "basic55", .pattern = ":::1:::0:|:::1:1:0:", .haystack = ":::0:::1:::1:::0:", .start = 8, .end = 17 },
    .{ .name = "basic56", .pattern = ":::1:::0:|:::1:1:1:", .haystack = ":::0:::1:::1:::0:", .start = 8, .end = 17 },
    .{ .name = "basic70", .pattern = "xxx", .haystack = "xxx", .start = 0, .end = 3 },
    .{ .name = "basic82", .pattern = "abaa|abbaa|abbbaa|abbbbaa", .haystack = "ababbabbbabbbabbbbabbbbaa", .start = 18, .end = 25 },
    .{ .name = "basic83", .pattern = "abaa|abbaa|abbbaa|abbbbaa", .haystack = "ababbabbbabbbabbbbabaa", .start = 18, .end = 22 },
    .{ .name = "basic84", .pattern = "aaac|aabc|abac|abbc|baac|babc|bbac|bbbc", .haystack = "baaabbbabac", .start = 7, .end = 11 },
    .{ .name = "basic87", .pattern = "aaaa|bbbb|cccc|ddddd|eeeeee|fffffff|gggg|hhhh|iiiii|jjjjj|kkkkk|llll", .haystack = "XaaaXbbbXcccXdddXeeeXfffXgggXhhhXiiiXjjjXkkkXlllXcbaXaaaa", .start = 53, .end = 57 },
    .{ .name = "basic94", .pattern = "abc", .haystack = "abc", .start = 0, .end = 3 },
    .{ .name = "basic95", .pattern = "abc", .haystack = "xabcy", .start = 1, .end = 4 },
    .{ .name = "basic96", .pattern = "abc", .haystack = "ababc", .start = 2, .end = 5 },
    .{ .name = "basic124", .pattern = "ab|cd", .haystack = "abc", .start = 0, .end = 2 },
    .{ .name = "basic125", .pattern = "ab|cd", .haystack = "abcd", .start = 0, .end = 2 },
    .{ .name = "basic144", .pattern = "a|b|c|d|e", .haystack = "e", .start = 0, .end = 1 },
    .{ .name = "basic166", .pattern = "(((((((((a)))))))))", .haystack = "a", .start = 0, .end = 1 },
    .{ .name = "basic167", .pattern = "multiple words", .haystack = "multiple words yeah", .start = 0, .end = 14 },
    .{ .name = "basic169", .pattern = "abcd", .haystack = "abcd", .start = 0, .end = 4 },
    .{ .name = "basic170", .pattern = "a(bc)d", .haystack = "abcd", .start = 0, .end = 4 },
};

test "fowler basic subset" {
    const testing = std.testing;
    const gpa = testing.allocator;

    for (cases) |tc| {
        var re = try Regex.compile(gpa, tc.pattern);
        defer re.deinit();

        try testing.expect(re.match(tc.haystack));

        const found = re.find(tc.haystack);
        testing.expect(found != null) catch |err| switch (err) {
            error.TestUnexpectedResult => {
                std.debug.print("No match! Test name: {s}\n", .{tc.name});
                continue;
            },
            else => return err,
        };
        testing.expectEqual(Match{ .start = tc.start, .end = tc.end }, found.?) catch |err| switch (err) {
            error.TestExpectedEqual => std.debug.print("Test name: {s}\n", .{tc.name}),
            else => return err,
        };
    }
}
