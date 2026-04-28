const Ast = @import("../Ast.zig");
const range_set = @import("range_set.zig");
const ByteRange = range_set.ByteRange;

pub fn getRanges(cls: anytype) []const ByteRange {
    const T = @TypeOf(cls);
    switch (T) {
        Ast.Class.Perl => return perl(cls.kind),
        Ast.Class.Ascii => return ascii(cls.kind),
        else => @compileError("expected Ast.Class.Perl or Ast.Class.Ascii, got " ++ @typeName(T)),
    }
}

pub fn isNegated(cls: anytype) bool {
    const T = @TypeOf(cls);
    switch (T) {
        Ast.Class.Perl, Ast.Class.Ascii => return cls.negated,
        else => @compileError("expected Ast.Class.Perl or Ast.Class.Ascii, got " ++ @typeName(T)),
    }
}

/// Helper to generate []const ByteRange from short hand tuples.
fn byteRanges(comptime tuples: anytype) []const ByteRange {
    const tuples_info = @typeInfo(@TypeOf(tuples));
    comptime {
        if (tuples_info != .@"struct" or !tuples_info.@"struct".is_tuple) {
            @compileError("byteRanges expects a tuple of (from, to) byte tuples");
        }
    }

    return comptime blk: {
        var ranges: [tuples_info.@"struct".fields.len]ByteRange = undefined;
        for (tuples, &ranges) |pair, *range| {
            const pair_info = @typeInfo(@TypeOf(pair));
            if (pair_info != .@"struct" or !pair_info.@"struct".is_tuple or pair_info.@"struct".fields.len != 2) {
                @compileError("byteRanges entries must be 2-tuples");
            }
            range.* = .{ .from = @as(u8, pair[0]), .to = @as(u8, pair[1]) };
        }
        const final = ranges;
        break :blk &final;
    };
}

fn perl(kind: Ast.Class.Perl.Kind) []const ByteRange {
    return switch (kind) {
        .digit => byteRanges(.{
            .{ '0', '9' },
        }),
        .word => byteRanges(.{
            .{ '0', '9' },
            .{ 'A', 'Z' },
            .{ '_', '_' },
            .{ 'a', 'z' },
        }),
        .space => byteRanges(.{
            .{ '\t', '\r' },
            .{ ' ', ' ' },
        }),
    };
}

fn ascii(kind: Ast.Class.Ascii.Kind) []const ByteRange {
    return switch (kind) {
        .alnum => byteRanges(.{
            .{ '0', '9' },
            .{ 'A', 'Z' },
            .{ 'a', 'z' },
        }),
        .alpha => byteRanges(.{
            .{ 'A', 'Z' },
            .{ 'a', 'z' },
        }),
        .ascii => byteRanges(.{
            .{ 0x00, 0x7F },
        }),
        .blank => byteRanges(.{
            .{ '\t', '\t' },
            .{ ' ', ' ' },
        }),
        .cntrl => byteRanges(.{
            .{ 0x00, 0x1F },
            .{ 0x7F, 0x7F },
        }),
        .digit => byteRanges(.{
            .{ '0', '9' },
        }),
        .graph => byteRanges(.{
            .{ '!', '~' },
        }),
        .lower => byteRanges(.{
            .{ 'a', 'z' },
        }),
        .print => byteRanges(.{
            .{ ' ', '~' },
        }),
        .punct => byteRanges(.{
            .{ '!', '/' },
            .{ ':', '@' },
            .{ '[', '`' },
            .{ '{', '~' },
        }),
        .space => byteRanges(.{
            .{ '\t', '\r' },
            .{ ' ', ' ' },
        }),
        .upper => byteRanges(.{
            .{ 'A', 'Z' },
        }),
        .word => byteRanges(.{
            .{ '0', '9' },
            .{ 'A', 'Z' },
            .{ '_', '_' },
            .{ 'a', 'z' },
        }),
        .xdigit => byteRanges(.{
            .{ '0', '9' },
            .{ 'A', 'F' },
            .{ 'a', 'f' },
        }),
    };
}
