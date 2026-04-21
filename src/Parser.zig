const Parser = @This();
arena: ArenaAllocator,

// Not owned by parser
pattern: []const u8,
offset: usize,

nodes: ArrayList(Node) = .empty,
stack: ArrayList(Frame) = .empty,
capture_info: CaptureInfo.Builder,

options: Options,

pub const Error = error{Parse} || Allocator.Error;

const Frame = union(enum) {
    /// When a group is encountered, the in-progress concat is pushed to the stack as `prev`,
    /// and a new concat is created to parse the group. When the group concat is finished,
    /// this `prev` concat is popped and receives the group concat as child.
    concat: struct {
        /// The actual value of the prev concat.
        value: *NodeList,
        /// The kind of group being parsed
        group_kind: Ast.Group.Kind,
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
        .capture_info = .init(gpa),
        .options = options,
    };
}

/// Parser entry method. Returns an `Ast` which owns all allocated resources.
pub fn parse(p: *Parser) Error!Ast {
    errdefer {
        p.capture_info.deinit();
        p.arena.deinit();
    }
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
            else => try concat.append(a, try p.addNode(.{ .literal = .{ .verbatim = c } })),
        }
    } else try p.popGroupAtEnd(concat);

    return .{
        .nodes = try p.nodes.toOwnedSlice(a),
        .capture_info = try p.capture_info.finalize(),
        .arena = p.arena,
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
    const opener_span = p.prevSpan();
    const group_kind = try p.parseGroupKind(opener_span);
    switch (group_kind) {
        .flags_only => |flags| {
            // This is a SetFlags node, add it to cur_concat and continue
            const flags_index = try p.addNode(.{ .set_flags = flags });
            try cur_concat.append(a, flags_index);
            return cur_concat;
        },
        .group => |kind| {
            // shelf cur_concat and create new concat to parse group
            try p.stack.append(a, .{ .concat = .{
                .value = cur_concat,
                .opener_span = opener_span,
                .group_kind = kind,
            } });
            return p.createNodeList();
        },
    }
}

fn popGroup(p: *Parser, cur_concat: *NodeList) !*NodeList {
    assert(p.prev() == ')');
    const a = p.arena.allocator();
    const stack_top = p.stack.pop() orelse return p.err(.group_close_unexpected);
    switch (stack_top) {
        .concat => |concat| {
            // cur_concat contains the content of the Group node
            const concat_index = try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } });
            const group_index = try p.addNode(.{
                .group = .{ .node = concat_index, .kind = concat.group_kind },
            });
            try concat.value.append(a, group_index);
            return concat.value;
        },
        .alt => |alt| {
            // cur_concat is the else branch of last alternation, pop stack once more to find prev_concat
            try alt.append(a, try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } }));
            const next_top = p.stack.pop() orelse return p.err(.group_close_unexpected);
            switch (next_top) {
                .concat => |concat| {
                    const alt_index = try p.addNode(.{ .alternation = .{ .nodes = try alt.toOwnedSlice(a) } });
                    try concat.value.append(a, try p.addNode(.{
                        .group = .{ .node = alt_index, .kind = concat.group_kind },
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

const GroupKind = union(enum) {
    flags_only: Ast.Flags,
    group: Ast.Group.Kind,
};

fn parseGroupKind(p: *Parser, open_paren: Span) !GroupKind {
    assert(p.prev() == '(');
    if (!p.eatIf('?')) return .{ .group = .{
        .numbered = try p.capture_info.addUnnamedCapture(),
    } };

    const quest_span = p.prevSpan();

    if (p.atEnd()) return p.errAt(.group_not_closed, open_paren);
    switch (p.peek().?) {
        'P' => {
            _ = p.eat();
            const c = p.peek() orelse return p.errAt(.group_not_closed, open_paren);
            // unsupported:
            // (?P=name) named backreference
            // (?P>name) recursive call to named group
            if (c != '<') return p.errCurrent(.unsupported_feature);
            _ = p.eat();
            return p.parseNamedGroup(true);
        },
        '<' => {
            _ = p.eat();
            const c = p.peek() orelse return p.errAt(.group_not_closed, open_paren);
            // unsupported lookbehind:
            // (?<=re) after text matching re
            // (?<!re) after text not matching
            if (c == '=' or c == '!') return p.errCurrent(.unsupported_feature);
            return p.parseNamedGroup(false);
        },
        // unsupported (?'name') named capturing
        '\'' => return p.errCurrent(.unsupported_feature),
        // unsupported lookahead:
        // (?=re) before text matching re
        // (?!re) before text not matching
        '=', '!' => return p.errCurrent(.unsupported_feature),
        // and a bunch other
        '#', '|', '>', '&', '(', 'C', 'R', '0', '+' => return p.errCurrent(.unsupported_feature),
        else => {
            const flags = try p.parseFlags();
            const flag_suffix = p.eat() orelse return p.errAt(.group_not_closed, open_paren);
            if (flag_suffix == ':') return .{ .group = .{ .non_capturing = flags } };
            assert(flag_suffix == ')');
            if (flags.isEmpty()) {
                // We don't allow empty flags, e.g., `(?)`. We instead interpret
                // it as a repetition operator missing its argument like Rust.
                return p.errAt(.repeat_argument_missing, quest_span);
            }
            return .{ .flags_only = flags };
        },
    }
}

fn parseNamedGroup(p: *Parser, p_prefix: bool) !GroupKind {
    assert(p.prev() == '<');
    const name_start = p.offset;
    const name_end = b: while (p.eat()) |c| {
        switch (c) {
            '0'...'9', 'a'...'z', 'A'...'Z', '_' => continue,
            '>' => break :b p.offset - 1,
            else => return p.errAt(.group_name_invalid, p.spanFrom(name_start - 1)),
        }
    } else return p.errAt(.group_name_not_closed, p.spanFrom(name_start - 1));
    if ((name_end - name_start) == 0) {
        return p.errAt(.group_name_invalid, p.spanFrom(name_start - 1));
    }

    const capture_name = p.pattern[name_start..name_end];
    const name_span: Span = .{ .start = name_start, .end = name_end };
    const result = try p.capture_info.addNamedCapture(capture_name, name_span);
    switch (result) {
        .added => |index| {
            return .{ .group = .{ .named = .{
                .index = index,
                .p_prefix = p_prefix,
            } } };
        },
        .duplicate => |og_span| return p.errWithAuxAt(.group_name_duplicated, name_span, og_span),
    }
}

/// Parses inline flags after `(?`.
/// On success, the next byte must be `:` or `)`.
/// Duplicate flags are rejected, including across `-`.
fn parseFlags(p: *Parser) !Ast.Flags {
    assert(p.prev() == '?');
    var flags: Ast.Flags = .{};
    var flag_spans = [_]?Span{null} ** std.meta.fields(Ast.Flag).len;
    var disable_span: ?Span = null;
    var disable_op_last = false;

    while (p.peek()) |c| {
        switch (c) {
            '-' => {
                _ = p.eat();
                if (disable_span) |span| {
                    return p.errWithAuxAt(.flag_disable_op_duplicated, p.prevSpan(), span);
                }
                disable_span = p.prevSpan();
                flags.push(.disable_op);
                disable_op_last = true;
            },
            'i', 'm', 's', 'U' => {
                _ = p.eat();
                const flag = parseFlag(c);
                const i = @intFromEnum(flag);
                if (flag_spans[i]) |span| {
                    return p.errWithAuxAt(.flag_duplicated, p.prevSpan(), span);
                }
                flag_spans[i] = p.prevSpan();
                flags.push(.{ .flag = flag });
                disable_op_last = false;
            },
            ':', ')' => {
                if (disable_op_last) return p.err(.flag_disable_op_dangling);
                break;
            },
            else => return p.errCurrent(.flag_unsupported),
        }
    }
    return flags;
}

fn parseFlag(c: u8) Ast.Flag {
    return switch (c) {
        'i' => .case_insensitive,
        'm' => .multi_line,
        's' => .dot_matches_new_line,
        'U' => .swap_greed,
        else => unreachable,
    };
}

fn parseRepetition(
    p: *Parser,
    concat: *NodeList,
    kind: enum { star, plus, question, range },
) !void {
    assert(p.prev() == '*' or p.prev() == '+' or p.prev() == '?' or p.prev() == '{');

    if (concat.items.len == 0) return p.err(.repeat_argument_missing);
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
                if (!p.eatIf(',')) return p.errAt(.repeat_count_format_invalid, p.spanFrom(span_start));
                if (p.eatIf('}')) break :b .{ .at_least = min.value };
                if (p.atEnd()) return p.errAt(.repeat_count_not_closed, p.spanFrom(span_start));
                const max = try p.parseDecimal();
                if (max.value < min.value) return p.errWithAuxAt(.repeat_size_invalid, max.span, min.span);
                if (!p.eatIf('}')) return p.errAt(.repeat_count_not_closed, p.spanFrom(span_start));
                break :b .{ .between = .{ .min = min.value, .max = max.value } };
            },
        };
    const has_lazy_suffix = p.eatIf('?');
    const repeat_node = try p.addNode(.{
        .repetition = .{
            .kind = rep_kind,
            .lazy_suffix = has_lazy_suffix,
            .node = last_concat_node,
        },
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
        if (val > p.options.max_repeat) return p.errAt(.repeat_size_invalid, .{ .start = p.offset, .end = pos });
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
        else => p.errAt(.class_range_invalid, span),
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
                if (from_lit.char() > to_lit.char()) return p.errWithAuxAt(.class_range_invalid, to_item_span, last_item_span);
                item_span_start = last_item_span.start; // set `item_span_start` to start of `from_lit`
                break :item .{ .range = .{ .from = from_lit, .to = to_lit } };
            } else if (c == '[' and p.eatIf(':')) {
                // ASCII class (POSIX class) item
                const negated = p.eatIf('^');
                const start = p.offset;
                const end = while (p.eat()) |cur| {
                    if (cur == ':') break p.offset - 1;
                } else return p.errAt(.class_not_closed, p.spanFrom(cls_span_start));
                if (!p.eatIf(']')) return p.errAt(.class_ascii_invalid, p.spanFrom(item_span_start));
                const name = p.pattern[start..end];
                const kind = Class.Ascii.Kind.fromName(name) orelse
                    return p.errAt(.class_ascii_invalid, p.spanFrom(item_span_start));
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
    return p.err(.escape_invalid);
}

fn parseEscapeInClass(p: *Parser) !Class.Item {
    assert(p.prev() == '\\');
    const c = p.eat() orelse return p.err(.escape_at_eof);
    if (parseClassPerl(c)) |perl| return .{ .perl = perl };
    if (try p.parseEscapeLiteral(c)) |lit| return .{ .literal = lit };
    return p.err(.escape_invalid);
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
        return p.errAt(.escape_invalid, .{ .start = hex_span_start, .end = p.pattern.len });
    var byte: u8 = 0;
    for (p.pattern[p.offset..][0..2]) |c| {
        p.offset += 1;
        const d = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return p.errAt(.escape_invalid, p.spanFrom(hex_span_start)),
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
    var diagnostics: Diagnostics = undefined;
    var saw_parse_error = false;
    var actual: ?[]const u8 = null;
    errdefer {
        std.debug.print(
            "\npattern: {s}\nexpected: {any}\n",
            .{ pattern, expected },
        );
        if (actual) |value| {
            std.debug.print("actual:   {any}\n", .{value});
        }
        if (saw_parse_error) {
            std.debug.print("diagnostic: {any}\n", .{diagnostics});
        }
    }

    var parser: Parser = .init(gpa, pattern, .{ .diag = &diagnostics });
    var ast = parser.parse() catch |parse_err| {
        saw_parse_error = true;
        return parse_err;
    };
    defer ast.deinit();
    var buffer: [256]u8 = undefined;
    actual = try std.fmt.bufPrint(&buffer, "{f}", .{ast});
    try testing.expectEqualStrings(expected, actual.?);
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
    var saw_parse_error = false;
    errdefer {
        std.debug.print(
            "\npattern: {s}\nexpected: err={s} span={any} aux={any}\n",
            .{ pattern, @tagName(expected.err), expected.span, expected.aux_span },
        );
        if (saw_parse_error) {
            std.debug.print("actual:   {any}\n", .{diagnostics});
        } else {
            std.debug.print("actual:   parse did not return error.Parse\n", .{});
        }
    }

    var parser: Parser = .init(gpa, pattern, .{ .diag = &diagnostics });
    var mb_ast = parser.parse() catch |parse_err| switch (parse_err) {
        error.Parse => b: {
            saw_parse_error = true;
            break :b null;
        },
        error.OutOfMemory => |oom| return oom,
    };
    if (mb_ast) |*ast| {
        ast.deinit();
        return error.TestExpectedError;
    }
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
        "a(?:b|c)",
        "a(?iU-sm:b|c)",
        "a(bc(?U-sm)de)",
        "(?P<name>a)",
        "(?<name>a)",
        "a(?P<first>b|c)(?<second>\\d)",
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

test "group count" {
    const gpa = testing.allocator;

    var parser: Parser = .init(gpa, "(?:a)(b)(?P<c>d)(?<e>f)", .{});
    var ast = try parser.parse();
    defer ast.deinit();

    try testing.expectEqual(@as(u16, 4), ast.capture_info.count);
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
            .tag = .repeat_argument_missing,
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
            .tag = .repeat_count_format_invalid,
            .start = 1,
            .end = 3,
        },
        .{
            .pattern = "a{1001}",
            .tag = .repeat_size_invalid,
            .start = 2,
            .end = 6,
        },
        .{
            .pattern = "a{5,3}",
            .tag = .repeat_size_invalid,
            .start = 4,
            .end = 5,
            .aux_span = .{ .start = 2, .end = 3 },
        },
        .{
            .pattern = "\\Z0B",
            .tag = .escape_invalid,
            .start = 1,
            .end = 2,
        },
        .{
            .pattern = "\\x1",
            .tag = .escape_invalid,
            .start = 1,
            .end = 3,
        },
        .{
            .pattern = "\\xZZ",
            .tag = .escape_invalid,
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
            .tag = .group_close_unexpected,
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
            .pattern = "(?",
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
            .pattern = "a(b|c",
            .tag = .group_not_closed,
            .start = 1,
            .end = 2,
        },
        .{
            .pattern = "(?:",
            .tag = .group_not_closed,
            .start = 0,
            .end = 1,
        },
        .{
            .pattern = "(?:ab",
            .tag = .group_not_closed,
            .start = 0,
            .end = 1,
        },
        .{
            .pattern = "(?i",
            .tag = .group_not_closed,
            .start = 0,
            .end = 1,
        },
        .{
            .pattern = "(?<first>b|c)and(?P<first>\\d)",
            .tag = .group_name_duplicated,
            .start = 20,
            .end = 25,
            .aux_span = .{ .start = 3, .end = 8 },
        },
        .{
            .pattern = "(?-)",
            .tag = .flag_disable_op_dangling,
            .start = 2,
            .end = 3,
        },
        .{
            .pattern = "(?i-)",
            .tag = .flag_disable_op_dangling,
            .start = 3,
            .end = 4,
        },
        .{
            .pattern = "(?ii)",
            .tag = .flag_duplicated,
            .start = 3,
            .end = 4,
            .aux_span = .{ .start = 2, .end = 3 },
        },
        .{
            .pattern = "(?i-i)",
            .tag = .flag_duplicated,
            .start = 4,
            .end = 5,
            .aux_span = .{ .start = 2, .end = 3 },
        },
        .{
            .pattern = "(?imx)",
            .tag = .flag_unsupported,
            .start = 4,
            .end = 5,
        },
        .{
            .pattern = "(?-1)",
            .tag = .flag_unsupported,
            .start = 3,
            .end = 4,
        },
        .{
            .pattern = "(?<>)",
            .tag = .group_name_invalid,
            .start = 2,
            .end = 4,
        },
        .{
            .pattern = "(?P<>)",
            .tag = .group_name_invalid,
            .start = 3,
            .end = 5,
        },
        .{
            .pattern = "(?<na-me>)",
            .tag = .group_name_invalid,
            .start = 2,
            .end = 6,
        },
        .{
            .pattern = "(?P<na-me>)",
            .tag = .group_name_invalid,
            .start = 3,
            .end = 7,
        },
        .{
            .pattern = "(?<name",
            .tag = .group_name_not_closed,
            .start = 2,
            .end = 7,
        },
        .{
            .pattern = "(?P<name",
            .tag = .group_name_not_closed,
            .start = 3,
            .end = 8,
        },
        .{
            .pattern = "[z-a]",
            .tag = .class_range_invalid,
            .start = 3,
            .end = 4,
            .aux_span = .{ .start = 1, .end = 2 },
        },
        .{
            .pattern = "[a-\\d]",
            .tag = .class_range_invalid,
            .start = 3,
            .end = 5,
        },
        .{
            .pattern = "[[:alpaca:]]",
            .tag = .class_ascii_invalid,
            .start = 1,
            .end = 11,
        },
        .{
            // compatibility decision: `\b` is assertion-only, not class item.
            .pattern = "[\\b]",
            .tag = .escape_invalid,
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

test "parse errors for unsupported group syntax" {
    const gpa = testing.allocator;

    const test_cases = &[_]struct {
        pattern: []const u8,
        start: usize,
        end: usize,
    }{
        .{ .pattern = "(?=a)", .start = 2, .end = 3 },
        .{ .pattern = "(?!a)", .start = 2, .end = 3 },
        .{ .pattern = "(?<=a)", .start = 3, .end = 4 },
        .{ .pattern = "(?<!a)", .start = 3, .end = 4 },
        .{ .pattern = "(?'name'a)", .start = 2, .end = 3 },
        .{ .pattern = "(?#comment)", .start = 2, .end = 3 },
        .{ .pattern = "(?|a|b)", .start = 2, .end = 3 },
        .{ .pattern = "(?>a)", .start = 2, .end = 3 },
        .{ .pattern = "(?R)", .start = 2, .end = 3 },
        .{ .pattern = "(?0)", .start = 2, .end = 3 },
        .{ .pattern = "(?&name)", .start = 2, .end = 3 },
        .{ .pattern = "(?(cond)a|b)", .start = 2, .end = 3 },
        .{ .pattern = "(?C)", .start = 2, .end = 3 },
        .{ .pattern = "(?+1)", .start = 2, .end = 3 },
        .{ .pattern = "(?P=name)", .start = 3, .end = 4 },
        .{ .pattern = "(?P>name)", .start = 3, .end = 4 },
    };

    for (test_cases) |tc| {
        try expectParseError(gpa, tc.pattern, .{
            .err = .unsupported_feature,
            .span = .{ .start = tc.start, .end = tc.end },
        });
    }
}

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const hash_map = std.hash_map;

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const Class = Ast.Class;
const NodeList = ArrayList(Node.Index);
const CaptureInfo = @import("CaptureInfo.zig");
const errors = @import("errors.zig");
const Diagnostics = errors.Diagnostics;
const Span = errors.Span;

const assert = std.debug.assert;
const panic = std.debug.panic;
