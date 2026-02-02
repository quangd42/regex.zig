const std = @import("std");
const Allocator = std.mem.Allocator;

const ArrayList = std.ArrayList;

nodes: []Node,

pub const Node = union(enum) {
    literal: Literal,
    // dot,
    class_perl: ClassPerl,
    group: Group,
    alternation: Alternation,
    concat: Concat,
    // assertion: Assertion,

    pub const Index = u32;

    pub const Literal = struct {
        char: u8,
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

    pub const Group = struct {
        node: Index,
    };

    pub const Alternation = struct {
        nodes: []Index,
    };

    pub const Concat = struct {
        nodes: []Index,
    };
};

const Ast = @This();

pub fn format(
    self: @This(),
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    if (self.nodes.len == 0) return;
    try self.formatNode(writer, @intCast(self.nodes.len - 1));
}

fn formatNode(self: @This(), writer: *std.Io.Writer, index: Node.Index) std.Io.Writer.Error!void {
    const node = self.nodes[@intCast(index)];
    switch (node) {
        .literal => |l| try writer.printAsciiChar(l.char, .{}),
        // .dot => try writer.printAsciiChar('.', .{}),
        .class_perl => |cl| {
            const char: u8 = switch (cl.kind) {
                .digit => if (cl.negated) 'D' else 'd',
                .word => if (cl.negated) 'W' else 'w',
                .space => if (cl.negated) 'S' else 's',
            };
            try writer.print("\\{c}", .{char});
        },
        .group => |group| {
            try writer.printAsciiChar('(', .{});
            try self.formatNode(writer, group.node);
            try writer.printAsciiChar(')', .{});
        },
        .alternation => |a| {
            try self.formatNode(writer, a.nodes[0]);
            for (a.nodes[1..]) |node_index| {
                try writer.printAsciiChar('|', .{});
                try self.formatNode(writer, node_index);
            }
        },
        .concat => |c| {
            for (c.nodes) |node_index| {
                try self.formatNode(writer, node_index);
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
