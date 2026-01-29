const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;

const Ast = @import("ast.zig");
const Node = Ast.Node;
const Error = Ast.Error;

const assert = std.debug.assert;

const Parser = @This();
arena: ArenaAllocator,

pattern: []const u8,
offset: usize,

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

fn isEnd(p: *Parser) bool {
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
pub fn parse(p: *Parser) !Node {
    var concat: ArrayList(Node) = .empty;
    const a = p.arena.allocator();

    while (!p.isEnd()) {
        switch (p.char()) {
            else => try concat.append(a, try p.parseAtom()),
        }
    }
    return .{ .concat = .{ .nodes = try concat.toOwnedSlice(a) } };
}

fn parseEscape(p: *Parser) !Node {
    assert(p.char() == '\\');
    p.eat();

    const out: Node = switch (p.char()) {
        'd' => .{ .class_perl = .{ .kind = .digit, .negated = false } },
        'D' => .{ .class_perl = .{ .kind = .digit, .negated = true } },
        'w' => .{ .class_perl = .{ .kind = .word, .negated = false } },
        'W' => .{ .class_perl = .{ .kind = .word, .negated = true } },
        's' => .{ .class_perl = .{ .kind = .space, .negated = false } },
        'S' => .{ .class_perl = .{ .kind = .space, .negated = true } },
        else => return error.UnsupportedEscape,
    };
    p.eat();
    return out;
}

fn parseAtom(p: *Parser) Error!Node {
    switch (p.char()) {
        '\\' => return p.parseEscape(),
        else => |c| {
            p.eat();
            return .{ .literal = .{ .c = c } };
        },
    }
}

const testing = std.testing;

test "parse atom" {
    const gpa = testing.allocator;

    const pattern = "ab.\\d\\D\\w\\W\\s\\S";
    var parser: Parser = .init(gpa, pattern);
    defer parser.deinit();
    const ast = try parser.parse();
    const out = try std.fmt.allocPrint(gpa, "{f}", .{ast});
    defer gpa.free(out);
    try testing.expectEqualStrings(out, pattern);
}
