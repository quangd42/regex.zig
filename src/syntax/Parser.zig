const Parser = @This();
arena: ArenaAllocator,

// Not owned by parser
pattern: []const u8,
offset: usize,
group_count: u16 = 1,

nodes: ArrayList(Node) = .empty,
stack: ArrayList(Frame) = .empty,

options: Options,

pub const Error = error{Parse} || Allocator.Error;

const Frame = union(enum) {
    /// When a group is encountered, the in-progress concat is pushed to the stack as `prev`,
    /// and a new concat is created to parse the group. When the group concat is finished,
    /// this `prev` concat is popped and receives the group concat as child.
    concat: struct {
        /// The actual value of the prev concat.
        value: *NodeList,
        /// Capture group index assigned at the opening `(`.
        group_index: u16,
        /// Span of the opening `(`, mostly used for unclosed-group diagnostics.
        opener_span: Span,
    },
    /// When a new branch of alternation is encountered, the in-progress concat is finalized
    /// and becomes child of an "alt builder". This alt builder is the one on top of the stack
    /// if one exists, otherwise a new alt builder is created and pushed to the stack.
    alt: *NodeList,
};

pub const Options = struct {
    diag: ?*Diagnostics = null,
    max_repeat: u16 = 1000,
};

pub fn init(gpa: Allocator, pattern: []const u8, options: Options) Parser {
    return .{
        .pattern = pattern,
        .offset = 0,
        .arena = .init(gpa),
        .options = options,
    };
}

/// Parser entry method. Returns an `Ast` which owns all allocated resources.
pub fn parse(p: *Parser) Error!Ast {
    errdefer p.arena.deinit();
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
            '\\' => try concat.append(a, try p.addNode(try p.parseEscape())),
            '.' => try concat.append(a, try p.addNode(.dot)),
            '^' => try concat.append(a, try p.addNode(.{ .assertion = .start_line_or_text })),
            '$' => try concat.append(a, try p.addNode(.{ .assertion = .end_line_or_text })),
            else => try concat.append(a, try p.addNode(
                .{ .literal = .{ .verbatim = c } },
            )),
        }
    } else try p.popGroupAtEnd(concat);

    return .{
        .nodes = try p.nodes.toOwnedSlice(a),
        .group_count = p.group_count,
        .arena = p.arena.state,
    };
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
    if (p.stack.items.len > 0) {
        const stack_top = p.stack.items[p.stack.items.len - 1];
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
    try p.stack.append(a, .{ .alt = new_alt });
    return p.createNodeList();
}

fn pushGroup(p: *Parser, cur_concat: *NodeList) !*NodeList {
    assert(p.prev() == '(');
    const a = p.arena.allocator();
    // shelf cur_concat and create new concat to parse group
    try p.stack.append(a, .{ .concat = .{
        .value = cur_concat,
        .group_index = p.group_count,
        .opener_span = p.prevSpan(),
    } });
    p.group_count += 1;
    return p.createNodeList();
}

fn popGroup(p: *Parser, cur_concat: *NodeList) !*NodeList {
    assert(p.prev() == ')');
    const a = p.arena.allocator();
    const stack_top = p.stack.pop() orelse return p.err(.unexpected_group_close);
    switch (stack_top) {
        .concat => |concat| {
            // cur_concat contains the content of the Group node
            const concat_index = try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } });
            const group_index = try p.addNode(.{
                .group = .{ .node = concat_index, .index = concat.group_index },
            });
            try concat.value.append(a, group_index);
            return concat.value;
        },
        .alt => |alt| {
            // cur_concat is the else branch of last alternation, pop stack once more to find prev_concat
            try alt.append(a, try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } }));
            const next_top = p.stack.pop() orelse return p.err(.unexpected_group_close);
            switch (next_top) {
                .concat => |concat| {
                    const alt_index = try p.addNode(.{ .alternation = .{ .nodes = try alt.toOwnedSlice(a) } });
                    try concat.value.append(a, try p.addNode(.{
                        .group = .{ .node = alt_index, .index = concat.group_index },
                    }));
                    return concat.value;
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
    if (p.stack.items.len > 1) {
        return p.errAt(.group_not_closed, p.unclosedGroupSpan());
    }
    const a = p.arena.allocator();

    const stack_top = p.stack.pop() orelse {
        // valid state: nothing on the stack, simply wrap up the current concat node as root
        _ = try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } });
        return;
    };

    switch (stack_top) {
        .concat => |concat| return p.errAt(.group_not_closed, concat.opener_span),
        .alt => |alt| {
            // valid state: current concat is a branch of alternation
            const concat_index = try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } });
            try alt.append(a, concat_index);
            _ = try p.addNode(.{ .alternation = .{ .nodes = try alt.toOwnedSlice(a) } });
        },
    }

    assert(p.stack.items.len == 0);
}

// --- parser funcs ---

fn parseRepetition(
    p: *Parser,
    concat: *NodeList,
    kind: enum { star, plus, question, range },
) !void {
    assert(p.prev() == '*' or p.prev() == '+' or p.prev() == '?' or p.prev() == '{');

    if (concat.items.len == 0) return p.err(.missing_repeat_argument);
    const last_concat_node = concat.items[concat.items.len - 1];

    const rep_kind: Ast.Repetition.Kind =
        switch (kind) {
            .question => .zero_or_one,
            .star => .zero_or_more,
            .plus => .one_or_more,
            .range => b: {
                const span_start = p.offset - 1; // asserted to be valid at top of function
                const min = try p.parseDecimal();
                if (p.eatIf('}')) {
                    break :b .{ .exactly = min.value };
                }
                if (!p.eatIf(',')) return p.errAt(.invalid_repeat_count_format, p.spanFrom(span_start));
                if (p.eatIf('}')) break :b .{ .at_least = min.value };
                if (p.atEnd()) return p.errAt(.repeat_count_not_closed, p.spanFrom(span_start));
                const max = try p.parseDecimal();
                if (max.value < min.value) return p.errWithAuxAt(.invalid_repeat_size, max.span, min.span);
                if (!p.eatIf('}')) return p.errAt(.repeat_count_not_closed, p.spanFrom(span_start));
                break :b .{ .between = .{ .min = min.value, .max = max.value } };
            },
        };
    const lazy = p.eatIf('?');
    const repeat_node = try p.addNode(.{
        .repetition = .{ .kind = rep_kind, .lazy = lazy, .node = last_concat_node },
    });
    concat.items[concat.items.len - 1] = repeat_node;
}

fn parseDecimal(p: *Parser) !struct { value: u16, span: Span } {
    var pos = p.offset;
    while (pos < p.pattern.len) : (pos += 1) {
        const ch = p.pattern[pos];
        if (ch < '0' or ch > '9') break;
    }
    if (pos == p.offset) return p.errCurrent(.repeat_count_empty);

    var val: u16 = 0;
    for (p.pattern[p.offset..pos]) |c| {
        val = val * 10 + c - '0';
        if (val > p.options.max_repeat) return p.errAt(.invalid_repeat_size, .{ .start = p.offset, .end = pos });
    }
    const span: Span = .{ .start = p.offset, .end = pos };
    p.offset = pos;
    return .{ .value = val, .span = span };
}

fn parseClassItem(p: *Parser, c: u8) !Class.Item {
    return switch (c) {
        '\\' => try p.parseEscapeInClass(),
        else => .{ .literal = .{ .verbatim = c } },
    };
}

fn unwrapItemToLiteral(p: *Parser, item: Class.Item, span: Span) !Ast.Literal {
    return switch (item) {
        .literal => |lit| lit,
        else => p.errAt(.invalid_class_range, span),
    };
}

fn parseClass(p: *Parser) !Node {
    assert(p.prev() == '[');
    const a = p.arena.allocator();
    var cls: ArrayList(Class.Item) = .empty;
    var last_item_span: Span = undefined;
    const cls_negated = p.eatIf('^');

    const cls_span_start = p.offset - 1; // asserted p.prev() == '['
    while (p.eat()) |c| {
        if (c == ']' and cls.items.len > 0) break;
        var item_span_start = p.offset - 1;
        const item: Class.Item = item: {
            if (c == '-') {
                // Range item
                if (cls.items.len == 0 or p.peek() == null or p.peek().? == ']') {
                    break :item .{ .literal = .{ .verbatim = '-' } };
                }
                const top = cls.pop().?;
                const from_lit = try p.unwrapItemToLiteral(top, last_item_span);
                const to_char = p.eat() orelse return p.errAt(.class_not_closed, p.spanFrom(cls_span_start));
                const to_item_span_start = p.offset - 1;
                const to_item = try p.parseClassItem(to_char);
                const to_item_span = p.spanFrom(to_item_span_start);
                const to_lit = try p.unwrapItemToLiteral(to_item, to_item_span);
                if (from_lit.char() > to_lit.char()) return p.errWithAuxAt(.invalid_class_range, to_item_span, last_item_span);
                item_span_start = last_item_span.start; // set `item_span_start` to start of `from_lit`
                break :item .{ .range = .{ .from = from_lit, .to = to_lit } };
            } else if (c == '[' and p.eatIf(':')) {
                // ASCII class (POSIX class) item
                const negated = p.eatIf('^');
                const start = p.offset;
                const end = while (p.eat()) |cur| {
                    if (cur == ':') break p.offset - 1;
                } else return p.errAt(.class_not_closed, p.spanFrom(cls_span_start));
                if (!p.eatIf(']')) return p.errAt(.invalid_ascii_class, p.spanFrom(item_span_start));
                const name = p.pattern[start..end];
                const kind = Class.Ascii.Kind.fromName(name) orelse
                    return p.errAt(.invalid_ascii_class, p.spanFrom(item_span_start));
                break :item .{ .ascii = .{ .kind = kind, .negated = negated } };
            } else {
                break :item try p.parseClassItem(c);
            }
        };

        try cls.append(a, item);
        last_item_span = .{ .start = item_span_start, .end = p.offset };
    } else return p.errAt(.class_not_closed, p.spanFrom(cls_span_start));

    return .{ .class = .{
        .items = try cls.toOwnedSlice(a),
        .negated = cls_negated,
    } };
}

fn parseEscape(p: *Parser) !Node {
    assert(p.prev() == '\\');
    const c = p.eat() orelse return p.err(.escape_at_eof);
    if (parseClassPerl(c)) |perl| return .{ .class_perl = perl };
    if (parseAssertion(c)) |asrt| return .{ .assertion = asrt };
    if (try p.parseEscapeLiteral(c)) |lit| return .{ .literal = lit };
    return p.err(.invalid_escape);
}

fn parseEscapeInClass(p: *Parser) !Class.Item {
    assert(p.prev() == '\\');
    const c = p.eat() orelse return p.err(.escape_at_eof);
    if (parseClassPerl(c)) |perl| return .{ .perl = perl };
    if (try p.parseEscapeLiteral(c)) |lit| return .{ .literal = lit };
    return p.err(.invalid_escape);
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
    const hex_span_start = p.offset - 1;
    if (p.offset + 2 > p.pattern.len)
        return p.errAt(.invalid_escape, .{ .start = hex_span_start, .end = p.pattern.len });
    var byte: u8 = 0;
    for (p.pattern[p.offset..][0..2]) |c| {
        p.offset += 1;
        const d = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return p.errAt(.invalid_escape, p.spanFrom(hex_span_start)),
        };
        byte = (byte << 4) | d;
    }
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

fn parseAssertion(c: u8) ?Ast.Assertion {
    return switch (c) {
        'A' => .start_text,
        'z' => .end_text,
        'b' => .word_boundary,
        'B' => .not_word_boundary,
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

// --- errors ---

fn errAt(p: *Parser, tag: Diagnostics.ParseError, span: Span) error{Parse} {
    return p.errWithAuxAt(tag, span, null);
}

fn errWithAuxAt(p: *Parser, tag: Diagnostics.ParseError, span: Span, aux_span: ?Span) error{Parse} {
    assert(span.isValidFor(p.pattern.len));
    if (aux_span) |as| assert(as.isValidFor(p.pattern.len));
    if (p.options.diag) |diagnostics| {
        diagnostics.* = Diagnostics.fromParse(tag, span, aux_span);
    }
    return error.Parse;
}

fn err(p: *Parser, tag: Diagnostics.ParseError) error{Parse} {
    return p.errAt(tag, p.prevSpan());
}

fn prevSpan(p: *Parser) Span {
    const end = p.offset;
    const start = if (end == 0) 0 else end - 1;
    return .{ .start = start, .end = end };
}

fn errCurrent(p: *Parser, tag: Diagnostics.ParseError) error{Parse} {
    const start = p.offset;
    const end = if (start < p.pattern.len) start + 1 else start;
    return p.errAt(tag, .{ .start = start, .end = end });
}

fn spanFrom(p: *Parser, start: usize) Span {
    return .{ .start = start, .end = p.offset };
}

fn unclosedGroupSpan(p: *Parser) Span {
    var i = p.stack.items.len;
    while (i > 0) {
        i -= 1;
        switch (p.stack.items[i]) {
            .concat => |concat| return concat.opener_span,
            .alt => {},
        }
    }
    panic("unclosedGroupSpan: missing concat frame on parser stack", .{});
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

/// Only used for internal invariants.
fn prev(p: *Parser) u8 {
    return p.pattern[p.offset - 1];
}

const testing = std.testing;

fn expectParseOk(gpa: Allocator, pattern: []const u8, expected: []const u8) !void {
    var parser: Parser = .init(gpa, pattern, .{});
    var ast = try parser.parse();
    defer ast.deinit(gpa);
    var buffer: [256]u8 = undefined;
    const actual = try std.fmt.bufPrint(&buffer, "{f}", .{ast});
    try testing.expectEqualStrings(expected, actual);
}

fn expectParseError(
    gpa: Allocator,
    pattern: []const u8,
    expected: struct {
        err: Diagnostics.ParseError,
        span: Span,
        aux_span: ?Span = null,
    },
) !void {
    var diagnostics: Diagnostics = undefined;
    var parser: Parser = .init(gpa, pattern, .{ .diag = &diagnostics });
    try testing.expectError(error.Parse, parser.parse());
    switch (diagnostics) {
        .parse => |diag| {
            try testing.expect(diag.span.isValidFor(pattern.len));
            if (diag.aux_span) |aux_span| {
                try testing.expect(aux_span.isValidFor(pattern.len));
            }
            try testing.expectEqual(expected.err, diag.err);
            try testing.expectEqual(expected.span, diag.span);
            try testing.expectEqual(expected.aux_span, diag.aux_span);
        },
        .compile => return error.TestUnexpectedResult,
    }
}

test "parse to string round trip" {
    const gpa = testing.allocator;

    const patterns = &[_][]const u8{
        // empty pattern
        "",

        // group & alternation
        "a(b|c|\\d)",
        "\\d|a|\\s",
        "a|", // empty alt
        "|a",

        // atom & concat
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

        // repetition
        "(a|b)?c*d+",
        "(a|b)??c*?d+?",
        "(a|b|c){5}|(a|b|c){5}?",
        "(a|b|c){5,}|(a|b|c){5,}",
        "(a|b|c){5,10}|(a|b|c){5,10}",

        // assertions
        "^re$",
        "\\A\\z",
        "\\b\\B",
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
        tag: Diagnostics.ParseError,
        start: usize,
        end: usize,
        aux_span: ?Span = null,
    }{
        .{
            .pattern = "a|b\\", // trailing backslash
            .tag = .escape_at_eof,
            .start = 3,
            .end = 4,
        },
        .{
            .pattern = "*",
            .tag = .missing_repeat_argument,
            .start = 0,
            .end = 1,
        },
        .{
            .pattern = "a{,}",
            .tag = .repeat_count_empty,
            .start = 2,
            .end = 3,
        },
        .{
            .pattern = "a{5,",
            .tag = .repeat_count_not_closed,
            .start = 1,
            .end = 4,
        },
        .{
            .pattern = "a{5.0}",
            .tag = .invalid_repeat_count_format,
            .start = 1,
            .end = 3,
        },
        .{
            .pattern = "a{1001}",
            .tag = .invalid_repeat_size,
            .start = 2,
            .end = 6,
        },
        .{
            .pattern = "a{5,3}",
            .tag = .invalid_repeat_size,
            .start = 4,
            .end = 5,
            .aux_span = .{ .start = 2, .end = 3 },
        },
        .{
            .pattern = "\\Z0B",
            .tag = .invalid_escape,
            .start = 1,
            .end = 2,
        },
        .{
            .pattern = "\\x1",
            .tag = .invalid_escape,
            .start = 1,
            .end = 3,
        },
        .{
            .pattern = "\\xZZ",
            .tag = .invalid_escape,
            .start = 1,
            .end = 3,
        },
        .{
            .pattern = "[",
            .tag = .class_not_closed,
            .start = 0,
            .end = 1,
        },
        .{
            .pattern = "[a-",
            .tag = .class_not_closed,
            .start = 0,
            .end = 3,
        },
        .{
            .pattern = "[[:alpha",
            .tag = .class_not_closed,
            .start = 0,
            .end = 8,
        },
        .{
            .pattern = ")",
            .tag = .unexpected_group_close,
            .start = 0,
            .end = 1,
        },
        .{
            .pattern = "(",
            .tag = .group_not_closed,
            .start = 0,
            .end = 1,
        },
        .{
            .pattern = "(ab",
            .tag = .group_not_closed,
            .start = 0,
            .end = 1,
        },
        .{
            .pattern = "[z-a]",
            .tag = .invalid_class_range,
            .start = 3,
            .end = 4,
            .aux_span = .{ .start = 1, .end = 2 },
        },
        .{
            .pattern = "[a-\\d]",
            .tag = .invalid_class_range,
            .start = 3,
            .end = 5,
        },
        .{
            .pattern = "[[:alpaca:]]",
            .tag = .invalid_ascii_class,
            .start = 1,
            .end = 11,
        },
        .{
            // compatibility decision: `\b` is assertion-only, not class item.
            .pattern = "[\\b]",
            .tag = .invalid_escape,
            .start = 2,
            .end = 3,
        },
    };

    for (test_cases) |tc| {
        try expectParseError(gpa, tc.pattern, .{
            .err = tc.tag,
            .span = .{ .start = tc.start, .end = tc.end },
            .aux_span = tc.aux_span,
        });
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
const errors = @import("../errors.zig");
const Diagnostics = errors.Diagnostics;
const Span = errors.Span;

const assert = std.debug.assert;
const panic = std.debug.panic;
