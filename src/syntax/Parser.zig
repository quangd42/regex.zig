/// Parser errors surfaced to callers.
pub const Error = error{
    InvalidEscape,
    EscapeAtEof,
    UnexpectedClassClose,
    ClassNotClosed,
    InvalidClassRange,
    InvalidAsciiClass,
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

// --- public methods ---

pub fn init(gpa: Allocator, pattern: []const u8) Parser {
    return .{
        .pattern = pattern,
        .offset = 0,
        .arena = .init(gpa),
    };
}

pub fn deinit(p: *Parser) void {
    p.arena.deinit();
}

/// Parser entry method. Returns an Ast whose root node is the last element.
pub fn parse(p: *Parser) !Ast {
    var concat = try p.createNodeList();
    const a = p.arena.allocator();

    while (p.eat()) |c| {
        switch (c) {
            '(' => concat = try p.pushGroup(concat),
            ')' => concat = try p.popGroup(concat),
            '|' => concat = try p.pushAlt(concat),
            '*' => try p.parseRepetition(concat, .star),
            '+' => try p.parseRepetition(concat, .plus),
            '?' => try p.parseRepetition(concat, .question),
            '{' => try p.parseRepetition(concat, .range),
            '[' => try concat.append(a, try p.addNode(try p.parseClass())),
            ']' => return error.UnexpectedClassClose,
            '\\' => try concat.append(a, try p.addNode(try p.parseEscape())),
            '.' => try concat.append(a, try p.addNode(.dot)),
            else => try concat.append(a, try p.addNode(
                .{ .literal = .{ .verbatim = c } },
            )),
        }
    }
    try p.popGroupAtEnd(concat);

    return .{ .nodes = try p.nodes.toOwnedSlice(a) };
}

// --- parser state manipulations ---

fn addNode(p: *Parser, node: Node) !Node.Index {
    try p.nodes.append(p.arena.allocator(), node);
    return @intCast(p.nodes.items.len - 1);
}

fn createNodeList(p: *Parser) !*NodeList {
    const a = p.arena.allocator();
    const new_concat = try a.create(NodeList);
    new_concat.* = .empty;
    return new_concat;
}

fn pushAlt(p: *Parser, cur_concat: *NodeList) !*NodeList {
    assert(p.prev() == '|');
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
    assert(p.prev() == '(');
    const a = p.arena.allocator();
    // shelf cur_concat and create new concat to parse group
    try p.group_stack.append(a, .{ .concat = cur_concat });
    return p.createNodeList();
}

fn popGroup(p: *Parser, cur_concat: *NodeList) !*NodeList {
    assert(p.prev() == ')');
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

// --- parser funcs ---

fn parseRepetition(
    p: *Parser,
    concat: *NodeList,
    kind: enum { star, plus, question, range },
) !void {
    assert(p.prev() == '*' or p.prev() == '+' or p.prev() == '?' or p.prev() == '{');

    if (concat.items.len == 0) return error.MissingRepeatArgument;
    const last_concat_node = concat.items[concat.items.len - 1];

    const rep_kind: Ast.Repetition.Kind =
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

fn parseDecimal(p: *Parser) !u16 {
    var pos = p.offset;
    while (pos < p.pattern.len) : (pos += 1) {
        const ch = p.pattern[pos];
        if (ch < '0' or ch > '9') break;
    }
    if (pos == p.offset) return error.RepeatCountEmpty;

    // NOTE: Limit the value of parsed decimal to 1000 to avoid pathological NFA growth.
    // This limit is used by RE2 familly (Go, Rust) so we're following suit.
    const max = 1000;
    var out: u16 = 0;
    for (p.pattern[p.offset..pos]) |c| {
        out = out * 10 + c - '0';
        if (out > max) return error.InvalidRepeatSize;
    }
    p.offset = pos;
    return out;
}

fn parseClassItem(p: *Parser, c: u8) !Class.Item {
    return switch (c) {
        '\\' => try p.parseEscapeInClass(),
        else => .{ .literal = .{ .verbatim = c } },
    };
}

fn unwrapItemToLiteral(item: Class.Item) !Ast.Literal {
    return switch (item) {
        .literal => |lit| lit,
        else => error.InvalidClassRange,
    };
}

fn parseClass(p: *Parser) !Node {
    assert(p.prev() == '[');
    const a = p.arena.allocator();
    var cls: ArrayList(Class.Item) = .empty;
    const cls_negated = p.eatIf('^');

    while (p.eat()) |c| {
        if (c == ']' and cls.items.len > 0) break;
        const item: Class.Item = item: {
            if (c == '-') {
                // Range item
                if (cls.items.len == 0 or p.peek() == null or p.peek().? == ']') {
                    break :item .{ .literal = .{ .verbatim = '-' } };
                }
                const top = cls.pop().?;
                const from_lit = try unwrapItemToLiteral(top);
                const to_char = p.eat() orelse return error.ClassNotClosed;
                const to_item = try p.parseClassItem(to_char);
                const to_lit = try unwrapItemToLiteral(to_item);
                if (from_lit.char() > to_lit.char()) return error.InvalidClassRange;
                break :item .{ .range = .{ .from = from_lit, .to = to_lit } };
            } else if (c == '[' and p.eatIf(':')) {
                // ASCII class (POSIX class) item
                const negated = p.eatIf('^');
                const start = p.offset;
                const end = while (p.eat()) |cur| {
                    if (cur == ':') break p.offset - 1;
                } else return error.ClassNotClosed;
                if (!p.eatIf(']')) return error.InvalidAsciiClass;
                const name = p.pattern[start..end];
                const kind = Class.Ascii.Kind.fromName(name) orelse return error.InvalidAsciiClass;
                break :item .{ .ascii = .{ .kind = kind, .negated = negated } };
            } else {
                break :item try p.parseClassItem(c);
            }
        };

        try cls.append(a, item);
    } else return error.ClassNotClosed;

    return .{ .class = .{
        .items = try cls.toOwnedSlice(a),
        .negated = cls_negated,
    } };
}

fn parseEscape(p: *Parser) !Node {
    assert(p.prev() == '\\');
    const c = p.eat() orelse return error.EscapeAtEof;
    if (parseClassPerl(c)) |prl| return .{ .class_perl = prl };
    if (try p.parseEscapeLiteral(c)) |lit| return .{ .literal = lit };
    return error.InvalidEscape;
}

fn parseEscapeInClass(p: *Parser) !Class.Item {
    assert(p.prev() == '\\');
    const c = p.eat() orelse return error.EscapeAtEof;
    if (parseClassPerl(c)) |prl| return .{ .perl = prl };
    if (try p.parseEscapeLiteral(c)) |lit| return .{ .literal = lit };
    return error.InvalidEscape;
}

fn parseCStyleEscape(c: u8) Ast.Literal.CStyle {
    return switch (c) {
        'a' => .bell,
        'f' => .form_feed,
        'n' => .line_feed,
        'r' => .carriage_return,
        't' => .tab,
        'v' => .vertical_tab,
        else => unreachable,
    };
}

fn parseHex(p: *Parser) !Ast.Literal {
    assert(p.prev() == 'x');
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
    return .{ .hex = byte };
}

fn parseEscapeLiteral(p: *Parser, c: u8) !?Ast.Literal {
    return switch (c) {
        'a', 'f', 'n', 'r', 't', 'v' => .{ .c_style = parseCStyleEscape(c) },
        'x' => try p.parseHex(),
        // zig fmt: off
        '\\', '.', '+', '*', '?', '(', ')', ',', '[', ']', '{', '}',
        '^', '$', '#', '&', '-', '~' => .{ .escaped = c } ,
        // zig fmt: on
        else => null,
    };
}

fn parseClassPerl(c: u8) ?Class.Perl {
    return switch (c) {
        'd' => .{ .kind = .digit, .negated = false },
        'D' => .{ .kind = .digit, .negated = true },
        'w' => .{ .kind = .word, .negated = false },
        'W' => .{ .kind = .word, .negated = true },
        's' => .{ .kind = .space, .negated = false },
        'S' => .{ .kind = .space, .negated = true },
        else => null,
    };
}

// --- string iteration helpers ---

fn atEnd(p: *Parser) bool {
    return p.offset >= p.pattern.len;
}

fn peek(p: *Parser) ?u8 {
    if (p.atEnd()) return null;
    return p.pattern[p.offset];
}

fn eat(p: *Parser) ?u8 {
    if (p.atEnd()) return null;
    const c = p.pattern[p.offset];
    p.offset += 1;
    return c;
}

fn eatIf(p: *Parser, target: u8) bool {
    const c = p.peek() orelse return false;
    if (c == target) {
        p.offset += 1;
        return true;
    }
    return false;
}

/// Only used for assertions.
fn prev(p: *Parser) u8 {
    return p.pattern[p.offset - 1];
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
        "ab.\\d\\D\\w\\W\\s\\S", // perl class
        "[abc][a-z][^a-z][a\\-z][\\d\\D\\w\\W\\s\\S]",
        "a[\\]]b",
        "a[^\\]b]c",
        "\\\\\\.\\[\\]\\.\\+\\*\\?\\(\\)\\{\\}\\^\\$\\^\\&\\-\\~", // meta
        "\\x41\\x0a", // hex literal

        // character class
        "a[]]b_&&_a[\\]]b",
        "a[-]b_&&_a[c-]_&&_[-c]_&&_a[\\-]b_&&_a[^-]",
        "a[^]b]c_&_a[^\\]b]c",
        "a[[:alpha:]]",
        "b[[:^alnum:]]",

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
        .{
            .pattern = "[",
            .expected = error.ClassNotClosed,
        },
        .{
            .pattern = "]",
            .expected = error.UnexpectedClassClose,
        },
        .{
            .pattern = "[z-a]",
            .expected = error.InvalidClassRange,
        },
        .{
            .pattern = "[a-\\d]",
            .expected = error.InvalidClassRange,
        },
        .{
            .pattern = "[[:alpaca:]]",
            .expected = error.InvalidAsciiClass,
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
const Class = Ast.Class;
const NodeList = ArrayList(Node.Index);

const assert = std.debug.assert;
const panic = std.debug.panic;
