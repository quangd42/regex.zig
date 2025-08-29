const std = @import("std");
const Allocator = std.mem.Allocator;

const ascii = std.ascii;
const ArrayList = std.ArrayList;

pub const Node = union(enum) {
    literal: Literal,
    dot,
    class_perl: ClassPerl,
    // group,
    alternation: Alternation,
    concat: Concat,
    assertion: Assertion,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .literal => |l| try writer.printAsciiChar(l.c, .{}),
            .dot => try writer.printAsciiChar('.', .{}),
            .class_perl => |cl| {
                const char: u8 = switch (cl.kind) {
                    .digit => if (cl.negated) 'D' else 'd',
                    .word => if (cl.negated) 'W' else 'w',
                    .space => if (cl.negated) 'S' else 's',
                };
                try writer.print("\\{c}", .{char});
            },
            .alternation => |a| {
                for (a.data.items, 0..) |alt, i| {
                    if (i != 0) try writer.printAsciiChar('|', .{});
                    try writer.print("{f}", .{alt});
                }
            },
            .concat => |c| {
                for (c.data.items) |alt| {
                    try writer.print("{f}", .{alt});
                }
            },
            .assertion => |a| {
                switch (a.kind) {
                    .start_line_or_string => try writer.printAsciiChar('^', .{}),
                    .end_line_or_string => try writer.printAsciiChar('$', .{}),
                }
            },
        }
    }
};

pub const Literal = struct {
    c: u8,
    kind: Kind,

    const Kind = enum {
        verbatim,
        meta,
        special,
    };
};

pub const ClassPerl = struct {
    kind: Kind,
    negated: bool,

    const Kind = enum {
        digit,
        word,
        space,
    };
};

pub const Alternation = struct {
    data: ArrayList(Node),
};

pub const Concat = struct {
    data: ArrayList(Node),
};

pub const Assertion = struct {
    kind: Kind,

    const Kind = enum {
        start_line_or_string,
        end_line_or_string,
    };
};

pub const Error = error{
    UnsupportedEscape,
};
