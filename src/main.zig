const std = @import("std");
const Regex = @import("Regex.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var re = try Regex.compile(gpa, "a(b|c)\\d");
    defer re.deinit();

    const haystack = "zzab3yy";
    const is_match = re.match(haystack);
    const found = re.find(haystack);

    std.debug.print("match: {any}, find: {any}\n", .{ is_match, found });
}
