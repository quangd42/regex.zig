const std = @import("std");
const Allocator = std.mem.Allocator;

const ascii = std.ascii;
const ArrayList = std.ArrayList;

pub const Node = union(enum) {
    literal: Literal,
    // dot,
    class_perl: ClassPerl,
    group: Group,
    alternation: Alternation,
    concat: Concat,
    // assertion: Assertion,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .literal => |l| try writer.printAsciiChar(l.c, .{}),
            // .dot => try writer.printAsciiChar('.', .{}),
            .class_perl => |cl| {
                const char: u8 = switch (cl.kind) {
                    .digit => if (cl.negated) 'D' else 'd',
                    .word => if (cl.negated) 'W' else 'w',
                    .space => if (cl.negated) 'S' else 's',
                };
                try writer.print("\\{c}", .{char});
            },
            .group => |gr| {
                try writer.printAsciiChar('(', .{});
                switch (gr) {
                    .concat => |concat| {
                        for (concat.nodes) |node| {
                            try writer.print("{f}", .{node});
                        }
                    },
                    .alt => |alt| {
                        for (alt.nodes, 0..) |node, i| {
                            if (i != 0) try writer.printAsciiChar('|', .{});
                            try writer.print("{f}", .{node});
                        }
                    },
                }
                try writer.printAsciiChar(')', .{});
            },
            .alternation => |a| {
                for (a.nodes, 0..) |node, i| {
                    if (i != 0) try writer.printAsciiChar('|', .{});
                    try writer.print("{f}", .{node});
                }
            },
            .concat => |c| {
                for (c.nodes) |node| {
                    try writer.print("{f}", .{node});
                }
            },
            // .assertion => |a| {
            //     switch (a.kind) {
            //         .start_line_or_string => try writer.printAsciiChar('^', .{}),
            //         .end_line_or_string => try writer.printAsciiChar('$', .{}),
            //     }
            // },
        }
    }
};

pub const Literal = struct {
    c: u8,
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

pub const Group = union(enum) {
    concat: Concat,
    alt: Alternation,
};

pub const Alternation = struct {
    nodes: []const Node,
};

pub const Concat = struct {
    nodes: []const Node,
};
//
// pub const Assertion = struct {
//     kind: Kind,
//
//     const Kind = enum {
//         start_line_or_string,
//         end_line_or_string,
//     };
// };
