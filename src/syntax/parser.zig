const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;

const Ast = @import("ast.zig");
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

fn char(p: *Parser) u8 {
    return p.pattern[p.offset];
}

fn eat(p: *Parser) void {
    p.offset += 1;
}

fn peek(p: *Parser) ?u8 {
    if (p.offset + 1 >= p.pattern.len) return null;
    return p.pattern[p.offset + 1];
}

// parser funcs

pub fn parse(p: *Parser) !Ast.Node {
    var concat: Ast.Concat = .{ .data = .empty };
    const a = p.arena.allocator();

    while (!p.isEnd()) {
        switch (p.char()) {
            else => try concat.data.append(a, try p.parseAtom()),
        }
    }
    return .{ .concat = concat };
}

fn parseEscape(p: *Parser) !Ast.Node {
    assert(p.char() == '\\');
    p.eat();

    defer p.eat();
    return switch (p.char()) {
        'd' => .{ .class_perl = .{ .kind = .digit, .negated = false } },
        'D' => .{ .class_perl = .{ .kind = .digit, .negated = true } },
        'w' => .{ .class_perl = .{ .kind = .word, .negated = false } },
        'W' => .{ .class_perl = .{ .kind = .word, .negated = true } },
        's' => .{ .class_perl = .{ .kind = .space, .negated = false } },
        'S' => .{ .class_perl = .{ .kind = .space, .negated = true } },
        else => error.UnsupportedEscape,
    };
}

fn parseAtom(p: *Parser) Error!Ast.Node {
    switch (p.char()) {
        '\\' => return p.parseEscape(),
        else => |c| {
            p.eat();
            return .{ .literal = .{
                .kind = .verbatim,
                .c = c,
            } };
        },
    }
}

const testing = std.testing;

test "parser" {
    const gpa = testing.allocator;

    const pattern = "ab.\\d\\D\\w\\W\\s\\S";
    var parser = Parser.init(gpa, pattern);
    defer parser.deinit();
    const ast = try parser.parse();
    const out = try std.fmt.allocPrint(gpa, "{f}", .{ast});
    defer gpa.free(out);
    try testing.expectEqualStrings(out, pattern);
}
