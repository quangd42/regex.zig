const std = @import("std");
const Regex = @import("regex");
const Match = Regex.Match;
const Captures = Regex.Captures;

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    std.debug.print("regex.zig demo\n\n", .{});

    try demoMatchAndFind(gpa);
    try demoCharacterClasses(gpa);
    try demoCaptures(gpa);
}

fn demoMatchAndFind(gpa: std.mem.Allocator) !void {
    const pattern = "a(b|c)\\d";
    const haystack = "zzab3yy";

    var re = try Regex.compile(gpa, pattern, .{});
    defer re.deinit();

    std.debug.print("alternation + digit\n", .{});
    std.debug.print("  pattern:  {s}\n", .{pattern});
    std.debug.print("  haystack: {s}\n", .{haystack});
    std.debug.print("  match():  {}\n", .{re.match(haystack)});
    printFind(re.find(haystack), haystack);
    std.debug.print("\n", .{});
}

fn demoCharacterClasses(gpa: std.mem.Allocator) !void {
    const pattern = "[A-Z][a-z][a-z]";
    const haystack = "IDs: Ada, BOB, and Eve";

    var re = try Regex.compile(gpa, pattern, .{});
    defer re.deinit();

    std.debug.print("character classes\n", .{});
    std.debug.print("  pattern:  {s}\n", .{pattern});
    std.debug.print("  haystack: {s}\n", .{haystack});
    printFind(re.find(haystack), haystack);
    std.debug.print("\n", .{});
}

fn demoCaptures(gpa: std.mem.Allocator) !void {
    const pattern = "(\\d\\d)/(\\d\\d)/(\\d\\d\\d\\d)";
    const haystack = "date=03/18/2026";

    var re = try Regex.compile(gpa, pattern, .{});
    defer re.deinit();

    const capture_count = re.captureCount();
    var stack_buf: [8]?Match = undefined;

    std.debug.print("captures with caller-managed buffer\n", .{});
    std.debug.print("  pattern:  {s}\n", .{pattern});
    std.debug.print("  haystack: {s}\n", .{haystack});
    std.debug.print("  captureCount(): {}\n", .{capture_count});

    if (capture_count <= stack_buf.len) {
        const captures = try re.findCaptures(haystack, stack_buf[0..capture_count]);
        std.debug.print("  storage:  stack\n", .{});
        printCaptures(captures, haystack);
    } else {
        const heap_buf = try gpa.alloc(?Match, capture_count);
        defer gpa.free(heap_buf);
        const captures = try re.findCaptures(haystack, heap_buf);
        std.debug.print("  storage:  heap\n", .{});
        printCaptures(captures, haystack);
    }
    std.debug.print("\n", .{});
}

fn printFind(result: ?Match, haystack: []const u8) void {
    if (result) |m| {
        std.debug.print(
            "  find():   {s} [{}, {})\n",
            .{ haystack[m.start..m.end], m.start, m.end },
        );
        return;
    }

    std.debug.print("  find():   no match\n", .{});
}

fn printCaptures(result: ?Captures, haystack: []const u8) void {
    const captures = result orelse {
        std.debug.print("  no match\n", .{});
        return;
    };

    for (captures.items, 0..) |group, i| {
        if (group) |m| {
            std.debug.print(
                "  group {}: {s} [{}, {})\n",
                .{ i, haystack[m.start..m.end], m.start, m.end },
            );
        } else {
            std.debug.print("  group {}: <null>\n", .{i});
        }
    }
}
