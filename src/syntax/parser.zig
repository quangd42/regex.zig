const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;

const Ast = @import("ast.zig");
const Node = Ast.Node;
const NodeList = ArrayList(Node.Index);

const assert = std.debug.assert;

pub const Error = error{
    InvalidEscape,
    TrailingBackslash, // Escape at EOF
    UnexpectedParen, // Closing nonexistent group
    MissingParen, // Group not closed
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

// string iteration helper

fn atEnd(p: *Parser) bool {
    return p.offset >= p.pattern.len;
}

inline fn char(p: *Parser) u8 {
    return p.pattern[p.offset];
}

inline fn eat(p: *Parser) void {
    p.offset += 1;
}

fn peek(p: *Parser) ?u8 {
    if (p.offset + 1 >= p.pattern.len) return null;
    return p.pattern[p.offset + 1];
}

//
// parser funcs
//

/// Parser entry method
pub fn parse(p: *Parser) !Ast {
    var concat = try p.createNodeList();
    const a = p.arena.allocator();

    while (!p.atEnd()) {
        switch (p.char()) {
            '(' => concat = try p.pushGroup(concat),
            ')' => concat = try p.popGroup(concat),
            '|' => concat = try p.pushAlt(concat),
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
    const prev_group_state = p.group_stack.pop() orelse return error.UnexpectedParen;
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
            const prev_prev_group_state = p.group_stack.pop() orelse return error.UnexpectedParen;
            switch (prev_prev_group_state) {
                .concat => |prev_concat| {
                    const alt_index = try p.addNode(.{ .alternation = .{ .nodes = try alt.toOwnedSlice(a) } });
                    try prev_concat.append(a, try p.addNode(.{ .group = .{ .node = alt_index } }));
                    return prev_concat;
                },
                .alt => {
                    // we never push alternation builder twice
                    unreachable;
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
        return error.MissingParen;
    }
    const a = p.arena.allocator();

    // valid: nothing on the stack, return the final concat node
    const prev_group_state = p.group_stack.pop() orelse {
        _ = try p.addNode(.{ .concat = .{ .nodes = try cur_concat.toOwnedSlice(a) } });
        return;
    };

    switch (prev_group_state) {
        .concat => return error.MissingParen,
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

    if (p.atEnd()) return error.TrailingBackslash;
    const out: Node = switch (p.char()) {
        'd' => .{ .class_perl = .{ .kind = .digit, .negated = false } },
        'D' => .{ .class_perl = .{ .kind = .digit, .negated = true } },
        'w' => .{ .class_perl = .{ .kind = .word, .negated = false } },
        'W' => .{ .class_perl = .{ .kind = .word, .negated = true } },
        's' => .{ .class_perl = .{ .kind = .space, .negated = false } },
        'S' => .{ .class_perl = .{ .kind = .space, .negated = true } },
        else => return error.InvalidEscape,
    };
    p.eat();
    return p.addNode(out);
}

fn parseAtom(p: *Parser) Error!Node.Index {
    switch (p.char()) {
        '\\' => return p.parseEscape(),
        else => |c| {
            p.eat();
            return p.addNode(.{ .literal = .{ .c = c } });
        },
    }
}

const testing = std.testing;

fn expectParseOk(gpa: Allocator, pattern: []const u8) !void {
    var parser: Parser = .init(gpa, pattern);
    defer parser.deinit();
    const ast = try parser.parse();
    var buffer: [256]u8 = undefined;
    const actual = try std.fmt.bufPrint(&buffer, "{f}", .{ast});
    try testing.expectEqualStrings(pattern, actual);
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
        "ab.\\d\\D\\w\\W\\s\\S",
    };

    for (patterns) |pattern| {
        try expectParseOk(gpa, pattern);
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
            .expected = error.TrailingBackslash,
        },
    };

    for (test_cases) |tc| {
        try expectParseError(gpa, tc.pattern, tc.expected);
    }
}
