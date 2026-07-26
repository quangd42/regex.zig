const std = @import("std");
const Allocator = std.mem.Allocator;

const Compiler = @import("Compiler.zig");
const Engine = @import("Engine.zig");
const errors = @import("errors.zig");
pub const Diagnostics = errors.Diagnostics;
const Program = @import("Program.zig");
const types = @import("types.zig");
pub const Input = types.Input;
pub const Span = types.Span;
pub const CompileOptions = types.CompileOptions;
pub const Match = types.Match;
pub const Captures = types.Captures;
const iterator = @import("iterator.zig");
const replace_mod = @import("replace.zig");
pub const Replacer = replace_mod.Replacer;

const Regex = @This();
prog: *Program,
engine: Engine,

pub fn compile(gpa: Allocator, pattern: []const u8, options: CompileOptions) !Regex {
    const prog = try Compiler.compile(gpa, pattern, options);
    errdefer prog.deinit();

    return .{
        .prog = prog,
        .engine = try .init(gpa, prog),
    };
}

pub fn deinit(re: *Regex) void {
    re.engine.deinit();
    re.prog.deinit();
}

/// Perform unanchored matching on the given haystack.
///
/// This answers the question "does this regex match the haystack anywhere?"
/// This is the cheapest query.
pub fn match(re: *Regex, haystack: []const u8) bool {
    return re.matchIn(.init(haystack, .{}));
}

/// Perform matching using the given search input configuration.
pub fn matchIn(re: *Regex, input: Input) bool {
    return re.engine.search(.presence, input) != null;
}

/// Return the start and end indices of the left-most match in the haystack.
/// Return null when there is no match.
///
/// This answers the question "does this regex match the haystack and if so, where?"
/// It performs extra work to keep track of the boundary of the matched string in the
/// haystack, and is more expensive than `Regex.match()`.
pub fn find(re: *Regex, haystack: []const u8) ?Match {
    return re.findIn(.init(haystack, .{}));
}

/// Return the start and end indices of the left-most match for the given search input
/// configuration.
pub fn findIn(re: *Regex, input: Input) ?Match {
    return re.engine.search(.span, input);
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
/// including advancing to the next match when using `findAllCaptures`.
/// Use `Captures.copy(dest)` to persist the full capture list across later searches.
pub fn findCaptures(re: *Regex, haystack: []const u8) ?Captures {
    return re.findCapturesIn(.init(haystack, .{}));
}

/// Search for capture groups using the given search input configuration.
pub fn findCapturesIn(re: *Regex, input: Input) ?Captures {
    return re.engine.search(.captures, input);
}

/// Iterator over successive non-overlapping matches.
/// See `findAll` and `findAllIn`.
pub const MatchIterator = iterator.Iterator(.span, Engine);

/// Iterator over successive non-overlapping matches with capture group data.
/// Each yielded `Captures` is invalidated by the next `next()` call. Use
/// `Captures.copy(dest)` to persist data across iterations.
/// See `findAllCaptures` and `findAllCapturesIn`.
pub const CapturesIterator = iterator.Iterator(.captures, Engine);

/// Return an iterator over all successive non-overlapping matches in the haystack.
pub fn findAll(re: *Regex, haystack: []const u8) MatchIterator {
    return re.findAllIn(.init(haystack, .{}));
}

/// Return an iterator over all successive non-overlapping matches
/// within the given input window.
pub fn findAllIn(re: *Regex, input: Input) MatchIterator {
    return .init(&re.engine, input);
}

/// Return an iterator over all successive non-overlapping matches
/// with full capture group data.
///
/// Each yielded `Captures` borrows engine-internal memory and is invalidated
/// by the next `next()` call. Use `Captures.copy(dest)` to persist capture
/// data across iterations.
pub fn findAllCaptures(re: *Regex, haystack: []const u8) CapturesIterator {
    return re.findAllCapturesIn(.init(haystack, .{}));
}

/// Like `findAllCaptures`, but with a custom input window.
pub fn findAllCapturesIn(re: *Regex, input: Input) CapturesIterator {
    return .init(&re.engine, input);
}

/// Returns the user-visible capture index for `name`, or `null` when the name does not exist.
pub fn captureIndex(re: *Regex, name: []const u8) ?usize {
    const index = re.prog.capture_info.indexOf(name) orelse return null;
    return index;
}

/// Iterates over capture names in capture index order.
/// Unnamed captures, including group 0 for the full match, are yielded as `null`.
pub const NameIterator = @import("CaptureInfo.zig").NameIterator;

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

/// Iterator over spans separated by successive non-overlapping matches.
/// See `split` and `splitIn`.
pub const SplitIterator = iterator.Split(Engine);

/// Returns an iterator over spans separated by successive non-overlapping
/// matches in the haystack.
///
/// Separators at either end of the haystack and adjacent separators yield
/// empty spans. If there are no matches, the iterator yields the whole
/// haystack once.
pub fn split(re: *Regex, haystack: []const u8) SplitIterator {
    return re.splitIn(.init(haystack, .{}));
}

/// Like `split`, but restricted to the given input window.
/// Yielded spans use absolute haystack offsets and cover only the input window.
///
/// When `input.anchored` is true, separator searches remain anchored as the
/// iterator advances. Splitting stops at the first position where no separator
/// begins, and the remainder of the input window is yielded as the final span.
pub fn splitIn(re: *Regex, input: Input) SplitIterator {
    return .init(&re.engine, input);
}

/// Iterator over a limited number of spans separated by successive
/// non-overlapping matches. See `splitN` and `splitNIn`.
pub const SplitNIterator = iterator.SplitN(Engine);

/// Returns an iterator over at most `limit` spans separated by successive
/// non-overlapping matches in the haystack.
///
/// The final span contains the unsplit remainder. A limit of zero yields no
/// spans, while a limit of one yields the whole haystack without searching.
pub fn splitN(re: *Regex, haystack: []const u8, limit: usize) SplitNIterator {
    return re.splitNIn(.init(haystack, .{}), limit);
}

/// Like `splitN`, but restricted to the given input window.
/// Yielded spans use absolute haystack offsets and cover only the input window.
/// The `input.anchored` behavior is the same as for `splitIn`.
pub fn splitNIn(re: *Regex, input: Input, limit: usize) SplitNIterator {
    return .init(&re.engine, input, limit);
}

/// Replaces the first leftmost match and writes the complete result to `writer`.
/// Returns false without writing when there is no match.
///
/// `$N`, `${N}`, `$name`, and `${name}` expand capture groups. Missing or
/// nonparticipating captures expand to empty, `$$` writes a literal `$`, and
/// malformed references preserve their `$` literally. Numeric references are
/// `0` or decimal numbers without leading zeros; other identifiers are names.
pub fn replace(
    re: *Regex,
    writer: *std.Io.Writer,
    haystack: []const u8,
    replacement: []const u8,
) std.Io.Writer.Error!bool {
    return re.replaceWith(writer, haystack, .{ .template = replacement });
}

/// Replaces the first leftmost match according to `replacer` and writes the
/// complete result to `writer`. Templates expand capture references while
/// literals are inserted directly. Returns false without writing on no match.
pub fn replaceWith(
    re: *Regex,
    writer: *std.Io.Writer,
    haystack: []const u8,
    replacer: Replacer,
) std.Io.Writer.Error!bool {
    switch (replacer) {
        .template => |template| {
            if (std.mem.findScalar(u8, template, '$') == null) {
                return re.replaceWith(writer, haystack, .{ .literal = template });
            }
            const captures = re.findCaptures(haystack) orelse return false;
            const match_info = captures.span();
            try writer.writeAll(haystack[0..match_info.start]);
            try replace_mod.writeExpanded(writer, captures, haystack, template);
            try writer.writeAll(haystack[match_info.end..]);
        },
        .literal => |literal| {
            const match_info = re.find(haystack) orelse return false;
            try writer.writeAll(haystack[0..match_info.start]);
            try writer.writeAll(literal);
            try writer.writeAll(haystack[match_info.end..]);
        },
    }
    return true;
}

/// Like `replace`, but returns an allocated result.
/// Returns null when there is no match. The caller owns the returned slice.
pub fn replaceAlloc(
    re: *Regex,
    gpa: Allocator,
    haystack: []const u8,
    replacement: []const u8,
) Allocator.Error!?[]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    const replaced = re.replace(&w.writer, haystack, replacement) catch
        return error.OutOfMemory;
    if (!replaced) return null;
    return try w.toOwnedSlice();
}

/// Replaces every successive non-overlapping match by expanding `replacement`
/// as described by `replace`, then writes the complete result to `writer`.
/// Returns false without writing when there are no matches.
pub fn replaceAll(
    re: *Regex,
    writer: *std.Io.Writer,
    haystack: []const u8,
    replacement: []const u8,
) std.Io.Writer.Error!bool {
    return re.replaceAllWith(writer, haystack, .{ .template = replacement });
}

/// Replaces every successive non-overlapping match according to `replacer` and
/// writes the complete result to `writer`. Templates expand capture references
/// while literals are inserted directly. Returns false without writing on no match.
pub fn replaceAllWith(
    re: *Regex,
    writer: *std.Io.Writer,
    haystack: []const u8,
    replacer: Replacer,
) std.Io.Writer.Error!bool {
    switch (replacer) {
        .template => |template| {
            if (std.mem.findScalar(u8, template, '$') == null) {
                return re.replaceAllWith(writer, haystack, .{ .literal = template });
            }

            var it = re.findAllCaptures(haystack);
            const first = it.next() orelse return false;
            const first_span = first.span();
            try writer.writeAll(haystack[0..first_span.start]);
            try replace_mod.writeExpanded(writer, first, haystack, template);

            var last_end = first_span.end;
            while (it.next()) |captures| {
                const match_info = captures.span();
                try writer.writeAll(haystack[last_end..match_info.start]);
                try replace_mod.writeExpanded(writer, captures, haystack, template);
                last_end = match_info.end;
            }
            try writer.writeAll(haystack[last_end..]);
        },
        .literal => |literal| {
            var it = re.findAll(haystack);
            const first = it.next() orelse return false;
            try writer.writeAll(haystack[0..first.start]);
            try writer.writeAll(literal);

            var last_end = first.end;
            while (it.next()) |m| {
                try writer.writeAll(haystack[last_end..m.start]);
                try writer.writeAll(literal);
                last_end = m.end;
            }
            try writer.writeAll(haystack[last_end..]);
        },
    }
    return true;
}

/// Like `replaceAll`, but returns an allocated result.
/// Returns null when there are no matches. The caller owns the returned slice.
pub fn replaceAllAlloc(
    re: *Regex,
    gpa: Allocator,
    haystack: []const u8,
    replacement: []const u8,
) Allocator.Error!?[]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    const replaced = re.replaceAll(&w.writer, haystack, replacement) catch
        return error.OutOfMemory;
    if (!replaced) return null;
    return try w.toOwnedSlice();
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

test "usage: findAll iterates over all matches" {
    const gpa = testing.allocator;

    // findAll returns an iterator over successive non-overlapping matches.
    {
        var re = try Regex.compile(gpa, "[A-Z][a-z]+", .{});
        defer re.deinit();

        const haystack = "Hello World, Alice and Bob";
        var iter = re.findAll(haystack);

        const m1 = iter.next().?;
        try expectEqualStrings("Hello", m1.bytes(haystack));

        const m2 = iter.next().?;
        try expectEqualStrings("World", m2.bytes(haystack));

        const m3 = iter.next().?;
        try expectEqualStrings("Alice", m3.bytes(haystack));

        const m4 = iter.next().?;
        try expectEqualStrings("Bob", m4.bytes(haystack));

        try expectEqual(null, iter.next());
    }

    // findAllCaptures yields Captures for each match.
    // Each Captures is invalidated by the next next() call.
    {
        var re = try Regex.compile(gpa, "(\\d+)-(\\d+)", .{});
        defer re.deinit();

        const haystack = "12-34 and 56-78";
        var iter = re.findAllCaptures(haystack);

        const c1 = iter.next().?;
        try expectEqualStrings("12-34", c1.bytes(haystack));
        try expectEqualStrings("12", c1.get(1).?.bytes(haystack));
        try expectEqualStrings("34", c1.get(2).?.bytes(haystack));

        // Persist captures before the next next() call.
        var buf: [3]?Match = undefined;
        const saved = c1.copy(&buf);

        const c2 = iter.next().?;
        try expectEqualStrings("56-78", c2.bytes(haystack));

        // Previously saved captures are still valid.
        try expectEqualStrings("12-34", saved[0].?.bytes(haystack));
        try expectEqualStrings("12", saved[1].?.bytes(haystack));

        try expectEqual(null, iter.next());
    }
}

test "usage: split" {
    const gpa = testing.allocator;

    var re = try Regex.compile(gpa, "[ \\t]+", .{});
    defer re.deinit();

    const haystack = "a b \t  c";
    var iter = re.split(haystack);

    try expectEqualStrings("a", iter.next().?.bytes(haystack));
    try expectEqualStrings("b", iter.next().?.bytes(haystack));
    try expectEqualStrings("c", iter.next().?.bytes(haystack));
    try expectEqual(null, iter.next());
}

test "usage: replace" {
    const gpa = testing.allocator;
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    const writer = &w.writer;

    {
        var re: Regex = try .compile(gpa, " ", .{});
        defer re.deinit();

        {
            const replaced_once = try re.replace(writer, "a b c d", "X");
            try testing.expect(replaced_once);
            try testing.expectEqualStrings("aXb c d", w.written());
        }
        {
            const mb_replaced = try re.replaceAlloc(gpa, "a b c d", "X");
            const replaced = mb_replaced orelse return error.TestUnexpectedResult;
            defer gpa.free(replaced);
            try testing.expectEqualStrings("aXb c d", replaced);
        }
        {
            w.clearRetainingCapacity();
            const replaced = try re.replaceAll(writer, "a b c d", "X");
            try testing.expect(replaced);
            try testing.expectEqualStrings("aXbXcXd", w.written());
        }
        {
            const mb_replaced = try re.replaceAllAlloc(gpa, "a b c d", "X");
            const replaced = mb_replaced orelse return error.TestUnexpectedResult;
            defer gpa.free(replaced);
            try testing.expectEqualStrings("aXbXcXd", replaced);
        }
    }
    {
        var re: Regex = try .compile(gpa, "^", .{});
        defer re.deinit();
        w.clearRetainingCapacity();

        const replaced = try re.replaceAll(writer, "abc", "X");
        try testing.expect(replaced);
        try testing.expectEqualStrings("Xabc", w.written());
    }
    {
        var re: Regex = try .compile(gpa, "(\\w+) (\\d+), (?<year>\\d+)", .{});
        defer re.deinit();
        w.clearRetainingCapacity();

        const replaced = try re.replace(writer, "July 17, 2026", "$2-$1-${year}");
        try testing.expect(replaced);
        try testing.expectEqualStrings("17-July-2026", w.written());
    }
}
