const std = @import("std");
const Captures = @import("types.zig").Captures;

/// Controls whether replacement text is expanded as a template or inserted literally.
pub const Replacer = union(enum) {
    template: []const u8,
    literal: []const u8,

    // TODO: Add a callback variant
};

/// Write `replacement` to `writer`, expanding `$N`, `${N}`, `$name`, and
/// `${name}` against `captures`.
///
/// Missing and nonparticipating captures expand to empty. `$$` writes a literal
/// `$`; a malformed reference (trailing `$`, `$-`, `${oops`) preserves its `$`
/// literally and leaves the following bytes untouched.
pub fn writeExpanded(
    writer: *std.Io.Writer,
    captures: Captures,
    haystack: []const u8,
    replacement: []const u8,
) std.Io.Writer.Error!void {
    var remaining = replacement;
    while (std.mem.findScalar(u8, remaining, '$')) |dollar| {
        try writer.writeAll(remaining[0..dollar]);
        remaining = remaining[dollar + 1 ..];

        if (remaining.len == 0) {
            try writer.writeByte('$');
            return;
        }
        if (remaining[0] == '$') {
            try writer.writeByte('$');
            remaining = remaining[1..];
            continue;
        }
        const parsed = parseCaptureId(remaining) orelse {
            try writer.writeByte('$');
            continue;
        };
        remaining = remaining[parsed.end..];
        const span = if (parseUint(parsed.id)) |index|
            captures.get(index)
        else |err| switch (err) {
            error.InvalidCharacter => captures.name(parsed.id),
            error.Overflow => null,
        };
        if (span) |match| {
            try writer.writeAll(match.bytes(haystack));
        }
    }
    try writer.writeAll(remaining);
}

/// Parses a capture identifier from the text immediately following `$`.
/// Returns `null` if the capture identifier is malformed.
fn parseCaptureId(input: []const u8) ?struct { id: []const u8, end: usize } {
    if (input.len == 0) return null;
    if (input[0] == '{') {
        const brace_end = std.mem.findScalarPos(u8, input, 1, '}') orelse return null;
        return .{ .id = input[1..brace_end], .end = brace_end + 1 };
    }
    var end: usize = 0;
    while (end < input.len and isValid(input[end])) {
        end += 1;
    }
    if (end == 0) return null;
    return .{ .id = input[0..end], .end = end };
}

fn isValid(c: u8) bool {
    return switch (c) {
        '0'...'9', 'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

fn parseUint(input: []const u8) error{ InvalidCharacter, Overflow }!u16 {
    if (input.len == 0 or (input.len > 1 and input[0] == '0')) {
        return error.InvalidCharacter;
    }

    var number: u16 = 0;
    var overflowed = false;
    for (input) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidCharacter;
        if (overflowed) continue; // continue in case there is invalid character afterwards

        const digit: u16 = c - '0';
        if (number > (std.math.maxInt(u16) - digit) / 10) {
            overflowed = true;
        } else {
            number = number * 10 + digit;
        }
    }
    if (overflowed) return error.Overflow;
    return number;
}

const testing = std.testing;

test "parseRef" {
    const Case = struct {
        template: []const u8,
        end: usize = 0,
        id: ?[]const u8 = null,
        malformed: bool = false,
    };
    const cases = [_]Case{
        .{ .template = "$0", .end = 1, .id = "0" },
        .{ .template = "$1", .end = 1, .id = "1" },
        .{ .template = "${1}", .end = 3, .id = "1" },
        .{ .template = "${1}x", .end = 3, .id = "1" },
        .{ .template = "$10", .end = 2, .id = "10" },
        .{ .template = "$65536", .end = 5, .id = "65536" },
        .{ .template = "${65536}", .end = 7, .id = "65536" },
        .{ .template = "$01", .end = 2, .id = "01" },
        .{ .template = "${01}", .end = 4, .id = "01" },
        .{ .template = "$name", .end = 4, .id = "name" },
        .{ .template = "${name}", .end = 6, .id = "name" },
        .{ .template = "$name1", .end = 5, .id = "name1" },
        .{ .template = "$1x", .end = 2, .id = "1x" },
        .{ .template = "${1x}", .end = 4, .id = "1x" },
        .{ .template = "$1_2", .end = 3, .id = "1_2" },
        .{ .template = "$65536x", .end = 6, .id = "65536x" },
        .{ .template = "${}", .end = 2, .id = "" },
        .{ .template = "$", .malformed = true },
        .{ .template = "$-", .malformed = true },
        .{ .template = "$}", .malformed = true },
        .{ .template = "${oops", .malformed = true },
        .{ .template = "${", .malformed = true },
    };
    for (cases) |tc| {
        const parsed = parseCaptureId(tc.template[1..]);
        if (tc.malformed) {
            try testing.expect(parsed == null);
            continue;
        }
        const p = parsed orelse return error.TestUnexpectedResult;
        try testing.expectEqual(tc.end, p.end);
        try testing.expectEqualStrings(tc.id.?, p.id);
    }
}

test "parseUint" {
    const valid = [_]struct { input: []const u8, expected: u16 }{
        .{ .input = "0", .expected = 0 },
        .{ .input = "1", .expected = 1 },
        .{ .input = "10", .expected = 10 },
        .{ .input = "65535", .expected = 65535 },
    };
    for (valid) |tc| {
        try testing.expectEqual(tc.expected, try parseUint(tc.input));
    }

    for ([_][]const u8{ "", "01", "name", "1x", "1_2", "65536x", "999999999x" }) |input| {
        try testing.expectError(error.InvalidCharacter, parseUint(input));
    }
    for ([_][]const u8{ "65536", "999999999" }) |input| {
        try testing.expectError(error.Overflow, parseUint(input));
    }
}
