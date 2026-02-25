/// Parser errors surfaced to callers.
pub const Error = error{
    InvalidEscape,
    EscapeAtEof,
    UnexpectedGroupClose,
    GroupNotClosed,
    RepeatCountNotClosed,
    MissingRepeatArgument, // '*', '+', '?' as first item in pattern
    RepeatCountEmpty,
    InvalidRepeatSize,
    InvalidRepeatCountFormat,
    OutOfMemory,
};

const Parser = @This();
arena: ArenaAllocator,

pattern: []const u8,
offset: usize,

nodes: ArrayList(Node) = .empty,

group_stack: ArrayList(union(enum) {
    concat: *NodeList, // The in-progress concat before group is opened
    alt: *NodeList, // The in-progress alternation, which will include current concat
}) = .empty,

pub fn init(gpa: Allocator, pattern: []const u8) Parser {
    return .{
        .pattern = pattern,
        .offset = 0,
        .arena = ArenaAllocator.init(gpa),
    };
}

pub fn deinit(p: *Parser) void {
    p.arena.deinit();
}

// String iteration helpers.

fn atEnd(p: *Parser) bool {
    return p.offset >= p.pattern.len;
}

fn char(p: *Parser) u8 {
    return p.pattern[p.offset];
}

fn eat(p: *Parser) void {
    p.offset += 1;
}

fn eatIf(p: *Parser, target: u8) bool {
    if (!p.atEnd() and p.char() == target) {
        p.eat();
        return true;
    }
    return false;
}

// --- parser funcs ---

/// Parser entry method. Returns an Ast whose root node is the last element.
pub fn parse(p: *Parser) !Ast {
    var concat = try p.createNodeList();
    const a = p.arena.allocator();

    while (!p.atEnd()) {
        switch (p.char()) {
            '(' => concat = try p.pushGroup(concat),
            ')' => concat = try p.popGroup(concat),
            '|' => concat = try p.pushAlt(concat),
            '*' => try p.parseRepetition(concat, .star),
            '+' => try p.parseRepetition(concat, .plus),
            '?' => try p.parseRepetition(concat, .question),
            '{' => try p.parseRepetition(concat, .range),
            else => try concat.append(a, try p.parseAtom()),
        }
    }
    try p.popGroupAtEnd(concat);

    return .{ .nodes = try p.nodes.toOwnedSlice(a) };
}

fn createNodeList(p: *Parser) !*NodeList {
    const a = p.arena.allocator();
    const new_concat = try a.create(NodeList);
    new_concat.* = .empty;
    return new_concat;
}

fn addNode(p: *Parser, node: Node) !Node.Index {
    try p.nodes.append(p.arena.allocator(), node);
    return @intCast(p.nodes.items.len - 1);
}

fn pushAlt(p: *Parser, cur_concat: *NodeList) !*NodeList {
    assert(p.char() == '|');
    p.eat();
    const a = p.arena.allocator();
    if (p.group_stack.items.len > 0) {
        const stack_top = p.group_stack.items[p.group_stack.items.len - 1];
        switch (stack_top) {
            .alt => |alt| {
                // there is an existing alternation builder
                // remember to convert concat builder to Node to store in alternation builder!
                const concat_index = try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } });
                try alt.append(a, concat_index);
                return p.createNodeList();
            },
            else => {},
        }
    }
    // stack is empty or stack top is not an alternation builder, so add a new one
    // remember to convert concat builder to Node to store in alternation builder!
    const new_alt = try p.createNodeList();
    const concat_index = try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } });
    try new_alt.append(a, concat_index);
    try p.group_stack.append(a, .{ .alt = new_alt });
    return p.createNodeList();
}

fn pushGroup(p: *Parser, cur_concat: *NodeList) !*NodeList {
    assert(p.char() == '(');
    p.eat();
    const a = p.arena.allocator();
    // shelf cur_concat and create new concat to parse group
    try p.group_stack.append(a, .{ .concat = cur_concat });
    return p.createNodeList();
}

fn popGroup(p: *Parser, cur_concat: *NodeList) !*NodeList {
    assert(p.char() == ')');
    p.eat();
    const a = p.arena.allocator();
    const prev_group_state = p.group_stack.pop() orelse return error.UnexpectedGroupClose;
    switch (prev_group_state) {
        .concat => |prev_concat| {
            // cur_concat contains the content of the Group node
            const concat_index = try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } });
            const group_index = try p.addNode(.{ .group = .{ .node = concat_index } });
            try prev_concat.append(a, group_index);
            return prev_concat;
        },
        .alt => |alt| {
            // cur_concat is the else branch of last alternation, pop stack once more to find prev_concat
            try alt.append(a, try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } }));
            const prev_prev_group_state = p.group_stack.pop() orelse return error.UnexpectedGroupClose;
            switch (prev_prev_group_state) {
                .concat => |prev_concat| {
                    const alt_index = try p.addNode(.{ .alternation = .{ .nodes = try alt.toOwnedSlice(a) } });
                    try prev_concat.append(a, try p.addNode(.{ .group = .{ .node = alt_index } }));
                    return prev_concat;
                },
                .alt => {
                    // we never push alternation builder twice
                    panic("back to back `alt` builders on group_stack", .{});
                },
            }
        },
    }
}

/// This is called when the parser has reached the end. There are only two valid scenarios:
/// either the stack is empty or there is only one alternation builder on the stack.
/// Otherwise an error is returned.
fn popGroupAtEnd(p: *Parser, cur_concat: *NodeList) !void {
    if (p.group_stack.items.len > 1) {
        return error.GroupNotClosed;
    }
    const a = p.arena.allocator();

    // valid: nothing on the stack, return the final concat node
    const prev_group_state = p.group_stack.pop() orelse {
        _ = try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } });
        return;
    };

    switch (prev_group_state) {
        .concat => return error.GroupNotClosed,
        .alt => |alt| {
            // valid: return the final alt node
            const concat_index = try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } });
            try alt.append(a, concat_index);
            _ = try p.addNode(.{ .alternation = .{ .nodes = try alt.toOwnedSlice(a) } });
        },
    }
}

fn parseEscape(p: *Parser) !Node.Index {
    assert(p.char() == '\\');
    p.eat();

    if (p.atEnd()) return error.EscapeAtEof;
    const c = p.char();

    // This could just be helper functions for `p`.
    // But there are a few other types of literal to come, so we can reassess then.
    const LiteralBuilder = struct {
        p: *Parser,

        fn addEscaped(l: *@This(), byte: u8) !Node.Index {
            l.p.eat();
            return l.p.addNode(.{ .literal = .{ .escaped = byte } });
        }

        fn addC(l: *@This(), kind: Node.Literal.CStyle) !Node.Index {
            l.p.eat();
            return l.p.addNode(.{ .literal = .{ .c_style = kind } });
        }
    };
    var lb: LiteralBuilder = .{ .p = p };

    return switch (c) {
        'd', 'D', 'w', 'W', 's', 'S' => p.parsePerlClass(),
        'a' => lb.addC(.bell),
        'f' => lb.addC(.form_feed),
        'n' => lb.addC(.line_feed),
        'r' => lb.addC(.carriage_return),
        't' => lb.addC(.tab),
        'v' => lb.addC(.vertical_tab),
        'x' => p.parseHex(),
        // zig fmt: off
        '\\', '.', '+', '*', '?', '(', ')', ',', '[', ']',
        '{', '}', '^', '$', '#', '&', '-', '~' => lb.addEscaped(c),
        // zig fmt: on
        else => error.InvalidEscape,
    };
}

fn parseHex(p: *Parser) !Node.Index {
    assert(p.char() == 'x');
    p.eat();
    if (p.offset + 2 > p.pattern.len) return error.InvalidEscape;
    var byte: u8 = 0;
    for (p.pattern[p.offset..][0..2]) |c| {
        const d = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidEscape,
        };
        byte = (byte << 4) | d;
    }
    p.offset += 2;
    return p.addNode(.{ .literal = .{ .hex = byte } });
}

fn parsePerlClass(p: *Parser) !Node.Index {
    const c = p.char();
    p.eat();
    return p.addNode(.{
        .class_perl = switch (c) {
            'd' => .{ .kind = .digit, .negated = false },
            'D' => .{ .kind = .digit, .negated = true },
            'w' => .{ .kind = .word, .negated = false },
            'W' => .{ .kind = .word, .negated = true },
            's' => .{ .kind = .space, .negated = false },
            'S' => .{ .kind = .space, .negated = true },
            else => panic("expected Perl class character, got {c}\n", .{c}),
        },
    });
}

fn parseRepetition(
    p: *Parser,
    concat: *NodeList,
    kind: enum { star, plus, question, range },
) !void {
    const c = p.char();
    assert(c == '*' or c == '+' or c == '?' or c == '{');
    p.eat();

    if (concat.items.len == 0) return error.MissingRepeatArgument;
    const last_concat_node = concat.items[concat.items.len - 1];

    const rep_kind: Node.Repetition.Kind =
        switch (kind) {
            .question => .zero_or_one,
            .star => .zero_or_more,
            .plus => .one_or_more,
            .range => b: {
                const min = try p.parseDecimal();
                if (p.eatIf('}')) {
                    break :b .{ .exactly = min };
                }
                if (!p.eatIf(',')) return error.InvalidRepeatCountFormat;
                if (p.eatIf('}')) break :b .{ .at_least = min };
                if (p.atEnd()) return error.RepeatCountNotClosed;
                const max = try p.parseDecimal();
                if (max < min) return error.InvalidRepeatSize;
                if (!p.eatIf('}')) return error.RepeatCountNotClosed;
                break :b .{ .between = .{ .min = min, .max = max } };
            },
        };
    const lazy = p.eatIf('?');
    const repeat_node = try p.addNode(.{
        .repetition = .{ .kind = rep_kind, .lazy = lazy, .node = last_concat_node },
    });
    concat.items[concat.items.len - 1] = repeat_node;
}

fn parseDecimal(p: *Parser) !u32 {
    var pos = p.offset;
    while (pos < p.pattern.len) : (pos += 1) {
        const ch = p.pattern[pos];
        if (ch < '0' or ch > '9') break;
    }
    if (pos == p.offset) return error.RepeatCountEmpty;

    // NOTE: Limit the value of parsed decimal to 1000 to avoid pathological NFA growth.
    // This limit is used by RE2 familly (Go, Rust) so we're following suit.
    const max = 1000;
    var out: u32 = 0;
    for (p.pattern[p.offset..pos]) |c| {
        out = out * 10 + c - '0';
        if (out > max) return error.InvalidRepeatSize;
    }
    p.offset = pos;
    return out;
}

fn parseAtom(p: *Parser) Error!Node.Index {
    switch (p.char()) {
        '\\' => return p.parseEscape(),
        '.' => {
            p.eat();
            return p.addNode(.dot);
        },
        else => |c| {
            p.eat();
            return p.addNode(.{ .literal = .{ .verbatim = c } });
        },
    }
}

const testing = std.testing;

fn expectParseOk(gpa: Allocator, pattern: []const u8, expected: []const u8) !void {
    var parser: Parser = .init(gpa, pattern);
    defer parser.deinit();
    const ast = try parser.parse();
    var buffer: [256]u8 = undefined;
    const actual = try std.fmt.bufPrint(&buffer, "{f}", .{ast});
    try testing.expectEqualStrings(expected, actual);
}

fn expectParseError(gpa: Allocator, pattern: []const u8, expected: anyerror) !void {
    var parser: Parser = .init(gpa, pattern);
    defer parser.deinit();
    try testing.expectError(expected, parser.parse());
}

test "parse to string round trip" {
    const gpa = testing.allocator;

    const patterns = &[_][]const u8{
        // parse group & alternation
        "a(b|c|\\d)",
        "\\d|a|\\s",
        "a|", // empty alt
        "|a",

        // parse atom & concat
        "ab.\\d\\D\\w\\W\\s\\S", // perl
        "\\\\\\.\\[\\]\\.\\+\\*\\?\\(\\)\\{\\}\\^\\$\\^\\&\\-\\~", // meta
        "\\x41\\x0a", // hex literal

        // parse repetition
        "(a|b)?c*d+",
        "(a|b)??c*?d+?",
        "(a|b|c){5}|(a|b|c){5}?",
        "(a|b|c){5,}|(a|b|c){5,}",
        "(a|b|c){5,10}|(a|b|c){5,10}",
    };

    for (patterns) |pattern| {
        try expectParseOk(gpa, pattern, pattern);
    }
}

test "parse to []byte round trip" {
    const gpa = testing.allocator;

    const cases = &[_]struct {
        pattern: []const u8,
        expected: []const u8,
    }{
        .{
            .pattern = "\\a\\f\\t\\n\\r\\v",
            .expected = &[_]u8{ '\x07', '\x0C', '\t', '\n', '\r', '\x0B' },
        },
    };
    for (cases) |tc| {
        try expectParseOk(gpa, tc.pattern, tc.expected);
    }
}

test "parse errors" {
    const gpa = testing.allocator;

    const test_cases = &[_]struct {
        pattern: []const u8,
        expected: anyerror,
    }{
        .{
            .pattern = "a|b\\", // trailing backslash
            .expected = error.EscapeAtEof,
        },
        .{
            .pattern = "*",
            .expected = error.MissingRepeatArgument,
        },
        .{
            .pattern = "a{,}",
            .expected = error.RepeatCountEmpty,
        },
        .{
            .pattern = "a{5,",
            .expected = error.RepeatCountNotClosed,
        },
        .{
            .pattern = "a{5.0}",
            .expected = error.InvalidRepeatCountFormat,
        },
        .{
            .pattern = "\\z0B",
            .expected = error.InvalidEscape,
        },
        .{
            .pattern = "\\x1",
            .expected = error.InvalidEscape,
        },
        .{
            .pattern = "\\xZZ",
            .expected = error.InvalidEscape,
        },
    };

    for (test_cases) |tc| {
        try expectParseError(gpa, tc.pattern, tc.expected);
    }
}

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const NodeList = ArrayList(Node.Index);

const assert = std.debug.assert;
const panic = std.debug.panic;
