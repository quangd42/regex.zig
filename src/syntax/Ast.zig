const std = @import("std");
const CaptureInfo = @import("CaptureInfo.zig");

const Ast = @This();

nodes: []Node,
capture_info: CaptureInfo,
arena: std.heap.ArenaAllocator,

pub fn deinit(ast: *Ast) void {
    ast.capture_info.deinit();
    ast.arena.deinit();
}

pub const Node = union(enum) {
    literal: Literal,
    dot,
    class_perl: Class.Perl,
    class: Class,
    group: Group,
    set_flags: Flags,
    alternation: Alternation,
    concat: Concat,
    repetition: Repetition,
    assertion: Assertion,

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
        ascii: Ascii,
    };

    pub const Perl = struct {
        kind: Kind,
        negated: bool,

        pub const Kind = enum { digit, word, space };
    };

    pub const Range = struct { from: Literal, to: Literal };

    pub const Ascii = struct {
        kind: Kind,
        negated: bool,

        pub const Kind = enum {
            /// alphanumeric `[0-9A-Za-z]`
            alnum,
            /// alphabetic `[A-Za-z]`
            alpha,
            /// ASCII `[\x00-\x7F]`
            ascii,
            /// blank `[\t ]`
            blank,
            /// control `[\x00-\x1F\x7F]`
            cntrl,
            /// digits `[0-9]`
            digit,
            /// graphical `[!-~]`
            graph,
            /// lower case `[a-z]`
            lower,
            /// printable `[ -~]`
            print,
            /// punctuation `[!-/:-@\[-`{-~]`
            punct,
            /// whitespace `[\t\n\v\f\r ]`
            space,
            /// upper case `[A-Z]`
            upper,
            /// word characters `[0-9A-Za-z_]`
            word,
            /// hex digit `[0-9A-Fa-f]`
            xdigit,

            pub fn fromName(name: []const u8) ?Kind {
                return std.meta.stringToEnum(Kind, name);
            }
        };
    };
};

pub const Group = struct {
    node: Node.Index,
    kind: Kind,

    pub const Kind = union(enum) {
        /// Capturing group without a name.
        numbered: u16,
        /// Capturing group with a name.
        named: Named,
        /// Non-capturing group with optional inline flags, e.g. `(?:re)` or `(?im:re)`.
        non_capturing: Flags,
    };

    pub const Named = struct {
        /// User-visible capture index. Group 0 is the full match.
        index: u16,
        /// True when this capture used the `(?P<name>re)` spelling instead of `(?<name>re)`.
        p_prefix: bool,

        pub fn bytes(self: @This(), ast: Ast) []const u8 {
            return ast.capture_info.nameAt(self.index).?;
        }
    };
};

pub const Flag = enum {
    case_insensitive, // i
    multi_line, // m
    dot_matches_new_line, // s
    swap_greed, // U
};

pub const Flags = struct {
    items: [max_len]Item = undefined,
    len: u8 = 0,

    /// Parser limit for the number of items in one inline flag list.
    pub const max_len = 5;

    pub const Item = union(enum) {
        /// Separates enabled flags from disabled flags, as in `im-s`.
        disable_op,
        /// A single inline flag.
        flag: Flag,
    };

    pub fn isEmpty(self: *const Flags) bool {
        return self.len == 0;
    }

    pub fn slice(self: *const Flags) []const Item {
        return self.items[0..self.len];
    }

    pub fn push(self: *Flags, item: Item) void {
        std.debug.assert(self.len < max_len);
        self.items[self.len] = item;
        self.len += 1;
    }
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
    /// True when the repetition uses an explicit `?` suffix, e.g. `*?` or `+?`.
    lazy_suffix: bool,

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

pub const Assertion = enum {
    /// `^`
    start_line_or_text,
    /// `$`
    end_line_or_text,
    /// `\A`
    start_text,
    /// `\z`
    end_text,
    /// `\b`
    word_boundary,
    /// `\B`
    not_word_boundary,
};

/// Returns the root node, which is the last node in Ast.nodes.
pub fn root(ast: Ast) Node.Index {
    std.debug.assert(ast.nodes.len > 0);
    return @intCast(ast.nodes.len - 1);
}

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
            switch (group.kind) {
                .named => |named| {
                    try writer.print("?{s}<{s}>", .{
                        if (named.p_prefix) "P" else "",
                        named.bytes(self),
                    });
                },
                .numbered => {},
                .non_capturing => |flags| {
                    try writer.writeAll("?");
                    try formatFlags(writer, flags);
                    try writer.writeAll(":");
                },
            }
            try self.formatNode(writer, group.node);
            try writer.printAsciiChar(')', .{});
        },
        .set_flags => |flags| {
            try writer.writeAll("(?");
            try formatFlags(writer, flags);
            try writer.writeAll(")");
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
            if (r.lazy_suffix) try writer.printAsciiChar('?', .{});
        },
        .assertion => |a| {
            switch (a) {
                .start_line_or_text => try writer.printAsciiChar('^', .{}),
                .end_line_or_text => try writer.printAsciiChar('$', .{}),
                .start_text => try writer.print("\\A", .{}),
                .end_text => try writer.print("\\z", .{}),
                .word_boundary => try writer.print("\\b", .{}),
                .not_word_boundary => try writer.print("\\B", .{}),
            }
        },
    }
}

fn formatFlag(writer: *std.Io.Writer, flag: Flag) std.Io.Writer.Error!void {
    try writer.writeAll(switch (flag) {
        .case_insensitive => "i",
        .multi_line => "m",
        .dot_matches_new_line => "s",
        .swap_greed => "U",
    });
}

fn formatFlags(writer: *std.Io.Writer, flags: Flags) !void {
    for (flags.slice()) |op| {
        switch (op) {
            .disable_op => try writer.writeAll("-"),
            .flag => |flag| try formatFlag(writer, flag),
        }
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
            .ascii => |ascii| try writer.print(
                "[:{s}{s}:]",
                .{ if (ascii.negated) "^" else "", @tagName(ascii.kind) },
            ),
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
