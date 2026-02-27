const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Ast = @This();

nodes: []Node,

pub const Node = union(enum) {
    literal: Literal,
    dot,
    class_perl: Class.Perl,
    class: Class,
    group: Group,
    alternation: Alternation,
    concat: Concat,
    repetition: Repetition,
    // assertion: Assertion,

    pub const Index = u32;
};

pub const Literal = union(enum) {
    /// Stored literal is the exact same as input.
    verbatim: u8,
    /// Parsed from escaped meta characters.
    escaped: u8,
    /// Parsed from C style escape characters such as `\n`, `\t`.
    c_style: CStyle,
    /// Parsed from hex escape '\xNN' such as '\x0B'
    hex: u8,

    pub const CStyle = enum(u8) {
        /// `\a` === `\x07`
        bell = '\x07',
        /// `\f` === `\x0C`
        form_feed = '\x0C',
        /// `\t` === `\x09`
        tab = '\t',
        /// `\n` === `\x0A`
        line_feed = '\n',
        /// `\r` === `\x0D`
        carriage_return = '\r',
        /// `\v` === `\x0B`
        vertical_tab = '\x0B',
        // `\ ` === `\x20`
        // space,
    };

    pub fn char(self: @This()) u8 {
        return switch (self) {
            .c_style => |c| @intFromEnum(c),
            inline else => |c| c,
        };
    }
};

pub const ClassPerl = Class.Perl;

pub const Class = struct {
    items: []Item,
    negated: bool,

    pub const Item = union(enum) {
        literal: Literal,
        range: Range,
        perl: Perl,
    };

    pub const Perl = struct {
        kind: Kind,
        negated: bool,

        const Kind = enum { digit, word, space };
    };
    pub const Range = struct { from: Literal, to: Literal };
};

pub const Group = struct {
    node: Node.Index,
};

pub const Alternation = struct {
    nodes: []Node.Index,
};

pub const Concat = struct {
    nodes: []Node.Index,
};

pub const Repetition = struct {
    kind: Kind,
    node: Node.Index,
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
        .literal => |lit| try formatLiteral(writer, lit),
        .dot => try writer.printAsciiChar('.', .{}),
        .class_perl => |perl| try formatClassPerl(writer, perl),
        .class => |cls| try formatClass(writer, cls),
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

fn formatClass(writer: *std.Io.Writer, class: Class) std.Io.Writer.Error!void {
    try writer.printAsciiChar('[', .{});
    if (class.negated) try writer.printAsciiChar('^', .{});
    for (class.items) |item| {
        switch (item) {
            .literal => |lit| try formatLiteral(writer, lit),
            .range => |range| {
                try formatLiteral(writer, range.from);
                try writer.printAsciiChar('-', .{});
                try formatLiteral(writer, range.to);
            },
            .perl => |perl| try formatClassPerl(writer, perl),
        }
    }
    try writer.printAsciiChar(']', .{});
}

fn formatClassPerl(writer: *std.Io.Writer, perl: Class.Perl) !void {
    const char: u8 = switch (perl.kind) {
        .digit => if (perl.negated) 'D' else 'd',
        .word => if (perl.negated) 'W' else 'w',
        .space => if (perl.negated) 'S' else 's',
    };
    try writer.print("\\{c}", .{char});
}

fn formatLiteral(writer: *std.Io.Writer, lit: Literal) !void {
    switch (lit) {
        .verbatim => |c| try writer.printAsciiChar(c, .{}),
        .escaped => |c| try writer.print("\\{c}", .{c}),
        .c_style => |c| try writer.printAsciiChar(@intFromEnum(c), .{}),
        .hex => |c| try writer.print("\\x{x:0>2}", .{c}),
    }
}

test "maximum Node size" {
    const expected = 4 * @sizeOf(usize);
    std.testing.expect(@sizeOf(Node) <= expected) catch {
        std.debug.print("Expected Node size = {d}, got {d}\n", .{ expected, @sizeOf(Node) });
        return error.TestUnexpectedResult;
    };
}
