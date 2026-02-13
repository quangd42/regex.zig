//! The Compiler compiles parsed Ast into a Thompson-style NFA: a linked collection of State
//! structures. This follows the algorithm presented in http://swtch.com/~rsc/regexp/

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");
const Program = @import("Program.zig");
const State = Program.State;
const StateId = Program.StateId;
const ByteRange = Program.ByteRange;
const Index = Program.Index;
const Length = Program.Length;

const Compiler = @This();

states: ArrayList(State) = .empty,
ranges: ArrayList(ByteRange) = .empty,
branches: ArrayList(StateId) = .empty,
arena: std.heap.ArenaAllocator,

/// Resources allocated are owned by Program after compilation is done, and caller is expected
/// to call Program.deinit() to free them.
pub fn compile(gpa: Allocator, pattern: []const u8) !Program {
    var parser: Parser = .init(gpa, pattern);
    defer parser.deinit();
    const ast = try parser.parse();
    var compiler: Compiler = .{ .arena = .init(gpa) };
    return compiler.internalCompile(ast);
}

fn internalCompile(c: *Compiler, ast: Ast) !Program {
    const a = c.arena.allocator();

    // preparing Compiler's state:
    // reserving id 0 for .fail state; and load commonly used ranges into ByteRange pool
    try c.states.append(a, .fail);
    try c.prepareCommonRanges();

    // the root node is the last node in Ast.nodes
    const frag = try c.compileNode(ast, @intCast(ast.nodes.len - 1));
    const match_id = try c.emitState(.match);
    frag.outs.patch(c, match_id);
    return .{
        .states = try c.states.toOwnedSlice(a),
        .ranges = try c.ranges.toOwnedSlice(a),
        .branches = try c.branches.toOwnedSlice(a),
        .arena = c.arena,
    };
}

fn compileNode(c: *Compiler, ast: Ast, node_index: StateId) !Frag {
    const a = c.arena.allocator();
    const node = ast.nodes[node_index];
    switch (node) {
        .literal => |lit| {
            const id = try c.emitState(.{ .char = .{ .byte = lit.char, .out = 0 } });
            return .{ .id = id, .outs = .fromOne(id) };
        },
        .class_perl => |cl| {
            // TODO: normalize ranges into (range_start, range_len)
            // if singleton => emitChar
            // else => emitMulti
            const id = switch (cl.kind) {
                .digit => try c.emitCommonRanges(.digit, 1, cl.negated),
                .word => try c.emitCommonRanges(.lower_alpha, 4, cl.negated),
                .space => try c.emitCommonRanges(.literal_space, 2, cl.negated),
            };
            return .{ .id = id, .outs = .fromOne(id) };
        },
        .group => |gr| return c.compileNode(ast, gr.node),
        .concat => |cat| {
            if (cat.nodes.len == 0) {
                // empty alternation branch
                const id = try c.emitState(.{ .empty = .{ .out = 0 } });
                return .{ .id = id, .outs = .fromOne(id) };
            }
            var frag = try c.compileNode(ast, cat.nodes[0]);
            for (cat.nodes[1..]) |index| {
                const next = try c.compileNode(ast, index);
                frag.outs.patch(c, next.id);
                frag.outs = next.outs;
            }
            return frag;
        },
        .alternation => |alt| {
            if (alt.nodes.len == 2) {
                const id = try c.emitState(.{ .alt2 = .{ .left = 0, .right = 0 } });
                const left = try c.compileNode(ast, alt.nodes[0]);
                const right = try c.compileNode(ast, alt.nodes[1]);
                c.states.items[id] = .{ .alt2 = .{ .left = left.id, .right = right.id } };
                return .{ .id = id, .outs = left.outs.append(c, right.outs) };
            }

            const id = try c.emitState(.{
                .alt = .{ .start = @intCast(c.branches.items.len), .len = @intCast(alt.nodes.len) },
            });
            // branches order preserves leftmost-first semantics.
            try c.branches.ensureTotalCapacity(a, alt.nodes.len);
            var frag: Frag = .{ .id = id, .outs = .empty };
            for (alt.nodes) |index| {
                const sub_frag = try c.compileNode(ast, index);
                c.branches.appendAssumeCapacity(sub_frag.id);
                frag.outs = frag.outs.append(c, sub_frag.outs);
            }
            return frag;
        },
    }
}

fn emitState(c: *Compiler, state: State) !StateId {
    const state_id: StateId = @intCast(c.states.items.len);
    try c.states.append(c.arena.allocator(), state);
    return state_id;
}

fn emitCommonRanges(c: *Compiler, range_start: CommonByteRange, len: Length, negated: bool) !StateId {
    return c.emitState(.{ .ranges = .{
        .start = @intFromEnum(range_start),
        .len = len,
        .out = 0,
        .negated = negated,
    } });
}

/// A compiled fragment returned by compileNode.
/// - id: the id of the entry state of the fragment
/// - outs: dangling out-edges that must be patched to the next fragment
const Frag = struct {
    id: StateId,
    outs: PatchList,
};

/// In the state list for execution, id 0 is reserved for .fail state,
/// so it's safe to repurpose it during building as dangling (i.e. to be patched).
///
/// All `Id` value referenced by PatchList are encoded into Ptr.
///
/// Reference: https://github.com/golang/go/blob/master/src/regexp/syntax/compile.go
const PatchList = struct {
    head: Ptr,
    tail: Ptr,

    const empty: PatchList = .{ .head = .zero, .tail = .zero };

    fn fromOne(id: StateId) PatchList {
        std.debug.assert(id < (1 << 31));
        const ptr: Ptr = .{ .id = @truncate(id), .field = .left };
        return .{ .head = ptr, .tail = ptr };
    }

    /// Decode the head value for the index of State (and which field) to patch.
    /// If the decoded value is 0 (dangling), then patching is finished.
    fn patch(l1: PatchList, c: *Compiler, value: StateId) void {
        std.debug.assert(value != 0);
        var head = l1.head;
        while (head.toId() != 0) {
            const next = head.get(c);
            head.set(c, value);
            head = next;
        }
    }

    fn append(l1: PatchList, c: *Compiler, l2: PatchList) PatchList {
        if (l1.head.toId() == 0) return l2;
        if (l2.head.toId() == 0) return l1;
        l1.tail.set(c, l2.head.toId());
        return .{ .head = l1.head, .tail = l2.tail };
    }

    const Ptr = packed struct {
        id: u31,
        field: Field,

        const zero: Ptr = .{ .id = 0, .field = .left };

        /// Indicates which 'out' field to patched in State.
        /// The field bit is ignored unless the State is alt2.
        const Field = enum(u1) { left = 0, right = 1 };

        fn toId(self: Ptr) StateId {
            return (@as(StateId, self.id) << 1) | @intFromEnum(self.field);
        }

        fn fromId(id: StateId) Ptr {
            return .{ .id = @truncate(id >> 1), .field = @enumFromInt(id & 1) };
        }

        /// Sets the field of State encoded by Ptr to `value`.
        /// The field set is usually .out, except for when State is alt2,
        /// in which case Ptr.field determines alt2.left or .right.
        fn set(self: Ptr, c: *Compiler, value: StateId) void {
            switch (c.states.items[self.id]) {
                .char => |*pl| pl.out = value,
                .ranges => |*pl| pl.out = value,
                .empty => |*pl| pl.out = value,
                .alt2 => |*pl| switch (self.field) {
                    .left => pl.left = value,
                    .right => pl.right = value,
                },
                else => unreachable,
            }
        }

        /// Finds the value at the field encoded by Ptr. This value is assumed to be
        /// encoded and is turned into a new Ptr and returned.
        fn get(self: Ptr, c: *Compiler) Ptr {
            return .fromId(
                switch (c.states.items[self.id]) {
                    .char => |pl| pl.out,
                    .ranges => |pl| pl.out,
                    .empty => |pl| pl.out,
                    .alt2 => |pl| switch (self.field) {
                        .left => pl.left,
                        .right => pl.right,
                    },
                    else => unreachable,
                },
            );
        }
    };
};

const CommonByteRange = enum(u4) {
    lower_alpha,
    upper_alpha,
    digit,
    under, // underscore '_'
    literal_space,
    other_whitespace, // \t...\r
};

/// ByteRange is inclusive.
const commonRanges = std.EnumArray(CommonByteRange, ByteRange).init(.{
    .lower_alpha = .{ .from = 'a', .to = 'z' },
    .upper_alpha = .{ .from = 'A', .to = 'Z' },
    .digit = .{ .from = '0', .to = '9' },
    .under = .{ .from = '_', .to = '_' },
    .literal_space = .{ .from = ' ', .to = ' ' },
    .other_whitespace = .{ .from = '\t', .to = '\r' },
});

/// Initializes the compiler's range pool with commonly used ranges, which can be used
/// to compile perl classes (to be updated).
fn prepareCommonRanges(c: *Compiler) !void {
    try c.ranges.ensureTotalCapacity(c.arena.allocator(), commonRanges.values.len);
    for (commonRanges.values) |value| { // Range.Index = CommonByteRange value
        c.ranges.appendAssumeCapacity(value);
    }
}

const testing = std.testing;

test "basic compile" {
    const a = testing.allocator;
    const expect = testing.expect;

    const pattern = "a((b|c)|\\d|)(x|y)z";
    var prog = try Compiler.compile(a, pattern);
    defer prog.deinit();

    const states = prog.states;
    try expect(states.len == 13);

    try expect(states[1].char.byte == 'a');
    try expect(states[1].char.out == 2);

    try expect(states[2].alt.start == 0);
    try expect(states[2].alt.len == 3);
    try expect(prog.branches[0] == 3);
    try expect(prog.branches[1] == 6);
    try expect(prog.branches[2] == 7);

    try expect(states[3].alt2.left == 4);
    try expect(states[3].alt2.right == 5);
    try expect(states[4].char.byte == 'b');
    try expect(states[4].char.out == 8);
    try expect(states[5].char.byte == 'c');
    try expect(states[5].char.out == 8);
    try expect(states[6].ranges.out == 8);
    try expect(states[6].ranges.start == 2);
    try expect(states[6].ranges.len == 1);
    try expect(states[7].empty.out == 8);

    try expect(states[8].alt2.left == 9);
    try expect(states[8].alt2.right == 10);
    try expect(states[9].char.byte == 'x');
    try expect(states[9].char.out == 11);
    try expect(states[10].char.byte == 'y');
    try expect(states[10].char.out == 11);
    try expect(states[11].char.byte == 'z');
    try expect(states[11].char.out == 12);

    try expect(prog.ranges.len == 6);
    try expect(prog.ranges[2].from == '0');
    try expect(prog.ranges[2].to == '9');
}
