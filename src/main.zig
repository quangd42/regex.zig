const std = @import("std");
const Regex = @import("Regex.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const pattern = "a(b|c)\\d";
    var re = try Regex.compile(gpa, pattern);
    defer re.deinit();

    const haystack = "zzab3yy";
    std.debug.print("pattern: {s}, haystack: {s}\n", .{ pattern, haystack });
    const is_match = re.match(haystack);
    std.debug.print("{s}\n", .{if (is_match) "matched!\n" else "no match!\n"});
    const result = re.find(haystack);
    if (result) |r| {
        std.debug.print("matched! matched text is: '{s}'\n", .{haystack[r.start..r.end]});
    } else {
        std.debug.print("no match!\n", .{});
    }
}
