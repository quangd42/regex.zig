const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Ast = @import("Ast.zig");
const Program = @import("Program.zig");
const State = Program.State;
const ByteRange = Program.ByteRange;
const Index = u32;
// In the state list for execution, index 0 is already reserved for .fail state, so we
// use index maxInt(u32) during building as dangling (i.e. to be patched).
const dangling: Index = std.math.maxInt(u32);
const Length = u16;

const Compiler = @This();

states: std.MultiArrayList(State) = .empty,
ranges: ArrayList(ByteRange) = .empty,
alt_outs: ArrayList(Index) = .empty,
arena: std.heap.ArenaAllocator,

pub fn init(gpa: Allocator) Compiler {
    return .{ .arena = .init(gpa) };
}

pub fn compile(c: *Compiler, ast: Ast) !void {
    const a = c.arena.allocator();

    // preparing Compiler's state
    try c.states.append(a, .fail);
    try c.prepareCommonRanges();

    const frag = try c.compileNode(ast, @intCast(ast.nodes.len - 1));
    const match_index = c.nextIndex();
    try c.states.append(a, .match);
    c.patch(frag.outs, match_index);
}

fn compileNode(c: *Compiler, ast: Ast, node_index: Index) !Frag {
    const a = c.arena.allocator();
    const node = ast.nodes[node_index];
    switch (node) {
        .literal => |lit| {
            const outs = try a.alloc(Index, 1);
            outs[0] = start;
            return .{ .start = start, .outs = outs };
            const start = try c.emitState(.{ .char = .{ .byte = lit.char, .out = dangling } });
        },
        .class_perl => |cl| {
            // TODO: normalize ranges into (range_start, range_len)
            // if singleton => emitChar
            // else => emitMulti
            const state: State = switch (cl.kind) {
                .digit => .{ .ranges = .{
                    .start = @intFromEnum(CommonByteRange.digit),
                    .len = 1,
                    .out = dangling,
                } },
                .word => .{ .ranges = .{
                    .start = @intFromEnum(CommonByteRange.lower_alpha),
                    .len = 4,
                    .out = dangling,
                } },
                .space => .{ .ranges = .{
                    .start = @intFromEnum(CommonByteRange.literal_space),
                    .len = 2,
                    .out = dangling,
            const outs = try a.alloc(Index, 1);
            outs[0] = start;
            return .{ .start = start, .outs = outs };
                } },
            };
            const start = try c.emitState(state);
        },
        .group => |gr| return c.compileNode(ast, gr.node),
        .concat => |cat| {
            if (cat.nodes.len == 0) {
                // Empty alternation branch
                const outs = try a.alloc(Index, 1);
                outs[0] = start;
                return .{ .start = start, .outs = outs };
                const start = c.emitState(.{ .empty = .{ .out = dangling } });
            }
            var frag = try c.compileNode(ast, cat.nodes[0]);
            for (cat.nodes[1..]) |index| {
                const next = try c.compileNode(ast, index);
                c.patch(frag.outs, next.start);
                frag.outs = next.outs;
            }
            return frag;
        },
        .alternation => |alt| {
            // add alt state
            const alt_index = try c.emitState(.{ .alt = .{
                .start = @intCast(c.alt_outs.items.len),
                .len = @intCast(alt.nodes.len),
            } });

            // compile each subgraph and collect alt_outs (subgraph' start) and sub_outs
            try c.alt_outs.ensureTotalCapacity(a, alt.nodes.len);
            var sub_outs: ArrayList(Index) = .empty;
            for (alt.nodes) |index| {
                const frag = try c.compileNode(ast, index);
                c.alt_outs.appendAssumeCapacity(frag.start);
                try sub_outs.appendSlice(a, frag.outs);
                a.free(frag.outs); // TODO: maybe a separate allocator for frags?
            }
            return .{ .start = alt_index, .outs = try sub_outs.toOwnedSlice(a) };
        },
    }
}

fn patch(c: *Compiler, outs: []Index, target: Index) void {
    const tags = c.states.items(.tags);
    const payloads = c.states.items(.data);
    for (outs) |out_index| {
        switch (tags[out_index]) {
            .char => payloads[out_index].char.out = target,
            .ranges => payloads[out_index].ranges.out = target,
            .empty => payloads[out_index].empty.out = target,
            // If the compiler works correctly then states at outs must be matchers
            // e.g. states with .out
            else => unreachable,
        }
    }
}

fn nextIndex(c: *Compiler) Index {
    return @intCast(c.states.len);
}

const Frag = struct {
    start: Index,
    outs: []Index,
};

const CommonByteRange = enum(u4) {
    lower_alpha,
    upper_alpha,
    digit,
    under, // underscore '_'
    literal_space,
    other_whitespace, // \t...\r
};

const commonRanges = std.EnumArray(CommonByteRange, ByteRange).init(.{
    .lower_alpha = .{ .start = 'a', .end = 'z' },
    .upper_alpha = .{ .start = 'A', .end = 'Z' },
    .digit = .{ .start = '0', .end = '9' },
    .under = .{ .start = '_', .end = '_' },
    .literal_space = .{ .start = ' ', .end = ' ' },
    .other_whitespace = .{ .start = '\t', .end = '\r' },
});

/// Initializes the compiler's range pool with commonly used ranges, which can be used
/// to compile perl classes (to be updated).
fn prepareCommonRanges(c: *Compiler) !void {
    try c.ranges.ensureTotalCapacity(c.arena.allocator(), commonRanges.values.len);
    for (commonRanges.values) |value| { // Range.Index = CommonByteRange value
        c.ranges.appendAssumeCapacity(value);
    }
}

fn dumpCompilerStates(c: *Compiler) !void {
    std.debug.print("States\n", .{});
    const state_tags = c.states.items(.tags);
    const state_payloads = c.states.items(.data);
    for (state_tags, state_payloads, 0..) |tag, payload, i| {
        switch (tag) {
            .char => std.debug.print(
                "{d:>3} {s:<8} byte={c} out={d:<3}\n",
                .{ i, @tagName(tag), payload.char.byte, payload.char.out },
            ),
            .ranges => {
                std.debug.print(
                    "{d:>3} {s:<8}        out={d:<3}    start={d:<3} len={d:<3}\n",
                    .{ i, @tagName(tag), payload.ranges.out, payload.ranges.start, payload.ranges.len },
                );
            },
            .alt => {
                std.debug.print(
                    "{d:>3} {s:<8}                   start={d:<3} len={d:<3}",
                    .{ i, @tagName(tag), payload.alt.start, payload.alt.len },
                );
                std.debug.print("  [ ", .{});
                for (c.alt_outs.items[payload.alt.start..][0..payload.alt.len]) |out_idx| {
                    std.debug.print("{d} ", .{out_idx});
                }
                std.debug.print("]\n", .{});
            },
            .empty => std.debug.print("{d:>3} {s:<8}\n", .{ i, @tagName(tag) }),
            .match => std.debug.print("{d:>3} {s:<8}\n", .{ i, @tagName(tag) }),
            .fail => std.debug.print("{d:>3} {s:<8}\n", .{ i, @tagName(tag) }),
        }
    }

    std.debug.print("\nRanges:\n", .{});
    for (c.ranges.items, 0..) |range, i| {
        std.debug.print("{d:>3} {{ start = {c}, end = {c} }}\n", .{ i, range.start, range.end });
    }
}

const testing = std.testing;

test "compile and dump" {
    const a = testing.allocator;

    const pattern = "a(b|c|\\d|)";
    const Parser = @import("Parser.zig");
    const St = @import("Ast.zig");
    var parser: Parser = .init(a, pattern);
    defer parser.deinit();

    const ast: St = try parser.parse();

    var compiler: Compiler = .init(a);
    _ = try compiler.compile(ast);
    try dumpCompilerStates(&compiler);
    compiler.arena.deinit();
}
