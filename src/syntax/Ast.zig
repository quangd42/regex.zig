const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Ast = @This();

nodes: []Node,

pub const Node = union(enum) {
    literal: Literal,
    // dot,
    class_perl: ClassPerl,
    group: Group,
    alternation: Alternation,
    concat: Concat,
    repetition: Repetition,
    // assertion: Assertion,

    pub const Index = u32;

    pub const Literal = struct {
        char: u8,
    };

    pub const ClassPerl = struct {
        kind: Kind,
        negated: bool,

        const Kind = enum { digit, word, space };
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

    pub const Repetition = struct {
        kind: Kind,
        node: Index,
        lazy: bool, // false = greedy

        /// Repetition count is capped at 1000 during parsing,
        /// so an u16 is enough.
        pub const Kind = union(enum) {
            zero_or_one,
            zero_or_more,
            one_or_more,
            exactly: u16,
            at_least: u16,
            between: struct { min: u16, max: u16 },
        };
    };
};

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
        .repetition => |r| {
            try self.formatNode(writer, r.node);
            switch (r.kind) {
                .zero_or_one => try writer.printAsciiChar('?', .{}),
                .zero_or_more => try writer.printAsciiChar('*', .{}),
                .one_or_more => try writer.printAsciiChar('+', .{}),
                .exactly => |b| try writer.print("{{{d}}}", .{b}),
                .at_least => |b| try writer.print("{{{d},}}", .{b}),
                .between => |b| try writer.print("{{{d},{d}}}", .{ b.min, b.max }),
            }
            if (r.lazy) try writer.printAsciiChar('?', .{});
        },
        // .assertion => |a| {
        //     switch (a.kind) {
        //         .start_line_or_string => try writer.printAsciiChar('^', .{}),
        //         .end_line_or_string => try writer.printAsciiChar('$', .{}),
        //     }
        // },
    }
}

test "maximum Node size" {
    const expected = 3 * @sizeOf(usize);
    std.testing.expect(@sizeOf(Node) <= expected) catch {
        std.debug.print("Expected Node size = {d}, got {d}\n", .{ expected, @sizeOf(Node) });
        return error.TestUnexpectedResult;
    };
}
