//! The Compiler compiles parsed Ast into a Thompson-style NFA: a linked collection of State
//! structures. This follows the algorithm presented in http://swtch.com/~rsc/regexp/

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");
const Program = @import("Program.zig");
const State = Program.State;
const StateId = Program.StateId;
const ByteRange = Program.ByteRange;
const Length = Program.Length;

const Compiler = @This();

states: ArrayList(State) = .empty,
ranges: ArrayList(ByteRange) = .empty,
branches: ArrayList(StateId) = .empty,
arena: std.heap.ArenaAllocator,

/// See `Program.group_count`.
group_count: u16 = 1,
/// See `Program.matcher_count`.
matcher_count: u32 = 0,

/// Resources allocated are owned by Program after compilation is done, and caller is expected
/// to call Program.deinit() to free them.
pub fn compile(gpa: Allocator, pattern: []const u8) !Program {
    var parser: Parser = .init(gpa, pattern);
    defer parser.deinit();
    const ast = try parser.parse();
    var compiler: Compiler = .{ .arena = .init(gpa) };
    return compiler.compileAst(ast);
}

fn compileAst(c: *Compiler, ast: Ast) !Program {
    const a = c.arena.allocator();

    // load commonly used ranges into ByteRange array
    try c.prepareCommonRanges();

    _ = try c.emitState(.{ .capture = .{ .slot = 0, .out = 1 } }); // capture_0
    // the root node is the last node in Ast.nodes
    const frag = try c.compileNode(ast, @intCast(ast.nodes.len - 1));
    const capture_1 = try c.emitState(.{
        .capture = .{ .slot = 1, .out = c.nextStateId() },
    });
    frag.outs.patch(c, capture_1);
    _ = try c.emitState(.match);
    return .{
        .states = try c.states.toOwnedSlice(a),
        .ranges = try c.ranges.toOwnedSlice(a),
        .branches = try c.branches.toOwnedSlice(a),
        .arena = c.arena,
        .group_count = c.group_count,
        .matcher_count = c.matcher_count,
    };
}

fn compileNode(c: *Compiler, ast: Ast, node_index: Ast.Node.Index) !Frag {
    const a = c.arena.allocator();
    const node = ast.nodes[node_index];
    switch (node) {
        .literal => |lit| {
            const id = try c.emitState(.{ .char = .{ .byte = lit.char(), .out = 0 } });
            return .{ .id = id, .outs = .fromOne(id) };
        },
        .dot => {
            const id = try c.emitState(.{ .any = .{ .out = 0 } });
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
        .group => |gr| {
            const slot_2k = c.group_count * 2;
            c.group_count += 1;
            const capture_left = try c.emitState(.{ .capture = .{
                .slot = slot_2k,
                .out = c.nextStateId(),
            } });
            const sub_frag = try c.compileNode(ast, gr.node);
            const capture_right = try c.emitState(.{ .capture = .{ .slot = slot_2k + 1, .out = 0 } });
            sub_frag.outs.patch(c, capture_right);
            return .{ .id = capture_left, .outs = .fromOne(capture_right) };
        },
        .concat => |cat| {
            if (cat.nodes.len == 0) {
                // Occurs in empty alternation branch
                return c.compileEmpty();
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
                const id = try c.emitAlt2();
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
        .repetition => |rep| {
            const Kind = Ast.Repetition.Kind;
            rep_kind: switch (rep.kind) {
                .zero_or_one => {
                    // alt: left -> node, right -> next
                    const alt = try c.emitAlt2();
                    var sub_frag = try c.compileNode(ast, rep.node);
                    const rep_outs = c.repetitionAlt(alt, sub_frag.id, rep.lazy);
                    sub_frag.outs = sub_frag.outs.append(c, rep_outs);
                    return .{ .id = alt, .outs = sub_frag.outs };
                },
                .zero_or_more => {
                    // (alt: left -> node, right -> next); node -> alt
                    const alt = try c.emitAlt2();
                    const sub_frag = try c.compileNode(ast, rep.node);
                    sub_frag.outs.patch(c, alt);
                    const outs = c.repetitionAlt(alt, sub_frag.id, rep.lazy);
                    return .{ .id = alt, .outs = outs };
                },
                .one_or_more => {
                    // node -> (alt: left -> node, right -> next)
                    const sub_frag = try c.compileNode(ast, rep.node);
                    const alt = try c.emitAlt2();
                    sub_frag.outs.patch(c, alt);
                    const outs = c.repetitionAlt(alt, sub_frag.id, rep.lazy);
                    return .{ .id = sub_frag.id, .outs = outs };
                },
                // TODO: Compilation for counted repetition perhaps will be cut once
                // the ast is simplified.
                .exactly => |min| {
                    if (min == 0) return c.compileEmpty();
                    var frag = try c.compileNode(ast, rep.node);
                    for (0..min - 1) |_| {
                        const next_frag = try c.compileNode(ast, rep.node);
                        frag.outs.patch(c, next_frag.id);
                        frag.outs = next_frag.outs;
                    }
                    return frag;
                },
                .at_least => |min| {
                    switch (min) {
                        0 => continue :rep_kind Kind.zero_or_more,
                        1 => continue :rep_kind Kind.one_or_more,
                        else => {
                            const result_id = c.nextStateId();
                            var frag: ?Frag = null;
                            for (0..min) |_| {
                                const next_frag = try c.compileNode(ast, rep.node);
                                if (frag) |f| f.outs.patch(c, next_frag.id);
                                frag = next_frag;
                            }
                            const alt = try c.emitAlt2();
                            const last_frag = frag.?; //  frag != null because `min` >= 2
                            last_frag.outs.patch(c, alt);
                            const outs = c.repetitionAlt(alt, last_frag.id, rep.lazy);
                            return .{ .id = result_id, .outs = outs };
                        },
                    }
                },
                .between => |b| {
                    if (b.max == 0) return c.compileEmpty();
                    if (b.max == 1 and b.min == 0) continue :rep_kind Kind.zero_or_one;
                    if (b.max == b.min) continue :rep_kind .{ .exactly = b.min };
                    const result_id = c.nextStateId();
                    // Compile repeat arg node min times (can be 0)
                    var frag: ?Frag = null;
                    for (0..b.min) |_| {
                        const next_frag = try c.compileNode(ast, rep.node);
                        if (frag) |f| f.outs.patch(c, next_frag.id);
                        frag = next_frag;
                    }

                    // For (max - min) times, create this shape (lazy = false):
                    // alt2: left  -> arg node (arg node: out -> the next alt2)
                    //       right -> dangling
                    // When lazy = true, left and right are reversed.
                    // This loop runs at least once because max < min case is handled
                    // in parsing phase, max == min case is sent to .exactly case.
                    assert(b.max > b.min);
                    var outs: PatchList = .empty;
                    for (0..b.max - b.min) |_| {
                        const alt = try c.emitAlt2();
                        const repeat_arg = try c.compileNode(ast, rep.node);
                        outs = outs.append(c, c.repetitionAlt(alt, repeat_arg.id, rep.lazy));
                        if (frag) |f| f.outs.patch(c, alt);
                        frag = .{ .id = alt, .outs = repeat_arg.outs };
                    }
                    // frag != null because the loop ran at least once
                    outs = outs.append(c, frag.?.outs);
                    return .{ .id = result_id, .outs = outs };
                },
            }
        },
    }
}

fn nextStateId(c: *Compiler) StateId {
    return @intCast(c.states.items.len + 1);
}

fn emitState(c: *Compiler, state: State) !StateId {
    const state_id: StateId = @intCast(c.states.items.len);
    try c.states.append(c.arena.allocator(), state);
    switch (state) {
        .char, .ranges, .any, .fail, .match => c.matcher_count += 1,
        .empty, .capture, .alt, .alt2 => {},
    }
    return state_id;
}

/// Emit State.alt2 with both ends dangling.
fn emitAlt2(c: *Compiler) !StateId {
    return c.emitState(.{ .alt2 = .{ .left = 0, .right = 0 } });
}

/// Helper to compile repetition. When `lazy` = false, creates the following shape:
/// ```
/// alt2: left  -> arg
///       right -> next (dangling)
/// ```
/// When `lazy` = true, `left` and `right` are reversed.
/// Returns the dangling patch list to `next`.
fn repetitionAlt(c: *Compiler, alt: StateId, arg: StateId, lazy: bool) PatchList {
    if (!lazy) {
        c.states.items[alt] = .{ .alt2 = .{ .left = arg, .right = 0 } };
        return .fromOneRight(alt);
    } else {
        c.states.items[alt] = .{ .alt2 = .{ .left = 0, .right = arg } };
        return .fromOne(alt);
    }
}

fn emitCommonRanges(c: *Compiler, range_start: CommonByteRange, len: Length, negated: bool) !StateId {
    return c.emitState(.{ .ranges = .{
        .start = @intFromEnum(range_start),
        .len = len,
        .out = 0,
        .negated = negated,
    } });
}

/// Creates a Frag that only contains a single State.empty.
fn compileEmpty(c: *Compiler) !Frag {
    const id = try c.emitState(.{ .empty = .{ .out = 0 } });
    return .{ .id = id, .outs = .fromOne(id) };
}

/// A compiled fragment returned by compileNode.
/// - id: the id of the entry state of the fragment
/// - outs: dangling out-edges that must be patched to the next fragment
const Frag = struct {
    id: StateId,
    outs: PatchList,
};

/// In the state list for execution, id 0 is reserved for .capture slot 0 state,
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
        assert(id < (1 << 31));
        const ptr: Ptr = .{ .id = @truncate(id), .field = .left };
        return .{ .head = ptr, .tail = ptr };
    }

    /// Like `fromOne`, but encode the patch target to .right.
    fn fromOneRight(id: StateId) PatchList {
        assert(id < (1 << 31));
        const ptr: Ptr = .{ .id = @truncate(id), .field = .right };
        return .{ .head = ptr, .tail = ptr };
    }

    /// Decode the head value for the index of State (and which field) to patch.
    /// If the decoded value is 0 (dangling), then patching is finished.
    fn patch(l1: PatchList, c: *Compiler, value: StateId) void {
        assert(value != 0);
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
                .fail, .match, .alt => unreachable,
                .alt2 => |*pl| switch (self.field) {
                    .left => pl.left = value,
                    .right => pl.right = value,
                },
                inline else => |*pl| pl.out = value,
            }
        }

        /// Finds the value at the field encoded by Ptr. This value is assumed to be
        /// encoded and is turned into a new Ptr and returned.
        fn get(self: Ptr, c: *Compiler) Ptr {
            return .fromId(
                switch (c.states.items[self.id]) {
                    .fail, .match, .alt => unreachable,
                    .alt2 => |pl| switch (self.field) {
                        .left => pl.left,
                        .right => pl.right,
                    },
                    inline else => |pl| pl.out,
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
    try expect(states.len == 20);

    try expect(states[1].char.byte == 'a');
    try expect(states[1].char.out == 2);

    try expect(states[3].alt.start == 0);
    try expect(states[3].alt.len == 3);
    try expect(prog.branches[0] == 4);
    try expect(prog.branches[1] == 9);
    try expect(prog.branches[2] == 10);

    try expect(states[5].alt2.left == 6);
    try expect(states[5].alt2.right == 7);
    try expect(states[6].char.byte == 'b');
    try expect(states[6].char.out == 8);
    try expect(states[7].char.byte == 'c');
    try expect(states[7].char.out == 8);
    try expect(states[9].ranges.out == 11);
    try expect(states[9].ranges.start == 2);
    try expect(states[9].ranges.len == 1);
    try expect(states[10].empty.out == 11);

    try expect(states[13].alt2.left == 14);
    try expect(states[13].alt2.right == 15);
    try expect(states[14].char.byte == 'x');
    try expect(states[14].char.out == 16);
    try expect(states[15].char.byte == 'y');
    try expect(states[15].char.out == 16);
    try expect(states[17].char.byte == 'z');
    try expect(states[17].char.out == 18);

    try expect(prog.ranges.len == 6);
    try expect(prog.ranges[2].from == '0');
    try expect(prog.ranges[2].to == '9');
}

test "basic repetition" {
    const a = testing.allocator;
    const expect = testing.expect;

    {
        var prog = try Compiler.compile(a, "a?");
        defer prog.deinit();

        const states = prog.states;
        try expect(states.len == 5);
        try expect(states[0].capture.out == 1);
        try expect(states[1].alt2.left == 2);
        try expect(states[1].alt2.right == 3);
        try expect(states[2].char.byte == 'a');
        try expect(states[2].char.out == 3);
        try expect(states[3].capture.out == 4);
    }

    {
        var prog = try Compiler.compile(a, "a*");
        defer prog.deinit();

        const states = prog.states;
        try expect(states.len == 5);
        try expect(states[0].capture.out == 1);
        try expect(states[1].alt2.left == 2);
        try expect(states[1].alt2.right == 3);
        try expect(states[2].char.byte == 'a');
        try expect(states[2].char.out == 1);
        try expect(states[3].capture.out == 4);
    }

    {
        var prog = try Compiler.compile(a, "a+");
        defer prog.deinit();

        const states = prog.states;
        try expect(states.len == 5);
        try expect(states[0].capture.out == 1);
        try expect(states[1].char.byte == 'a');
        try expect(states[1].char.out == 2);
        try expect(states[2].alt2.left == 1);
        try expect(states[2].alt2.right == 3);
        try expect(states[3].capture.out == 4);
    }

    {
        var prog = try Compiler.compile(a, "a??");
        defer prog.deinit();

        const states = prog.states;
        try expect(states.len == 5);
        try expect(states[0].capture.out == 1);
        try expect(states[1].alt2.left == 3);
        try expect(states[1].alt2.right == 2);
        try expect(states[2].char.byte == 'a');
        try expect(states[2].char.out == 3);
        try expect(states[3].capture.out == 4);
    }

    {
        var prog = try Compiler.compile(a, "a*?");
        defer prog.deinit();

        const states = prog.states;
        try expect(states.len == 5);
        try expect(states[0].capture.out == 1);
        try expect(states[1].alt2.left == 3);
        try expect(states[1].alt2.right == 2);
        try expect(states[2].char.byte == 'a');
        try expect(states[2].char.out == 1);
        try expect(states[3].capture.out == 4);
    }

    {
        var prog = try Compiler.compile(a, "a+?");
        defer prog.deinit();

        const states = prog.states;
        try expect(states.len == 5);
        try expect(states[0].capture.out == 1);
        try expect(states[1].char.byte == 'a');
        try expect(states[1].char.out == 2);
        try expect(states[2].alt2.left == 3);
        try expect(states[2].alt2.right == 1);
        try expect(states[3].capture.out == 4);
    }
}
test "counted repetition" {
    const a = testing.allocator;
    const expect = testing.expect;
    {
        var prog = try Compiler.compile(a, "a{3}");
        defer prog.deinit();
        const states = prog.states;
        try expect(states.len == 6);
        try expect(states[0].capture.out == 1);
        try expect(states[1].char.byte == 'a');
        try expect(states[1].char.out == 2);
        try expect(states[2].char.byte == 'a');
        try expect(states[2].char.out == 3);
        try expect(states[3].char.byte == 'a');
        try expect(states[3].char.out == 4);
        try expect(states[4].capture.out == 5);
    }
    {
        var prog = try Compiler.compile(a, "a{2,}");
        defer prog.deinit();
        const states = prog.states;
        try expect(states.len == 6);
        try expect(states[0].capture.out == 1);
        try expect(states[1].char.byte == 'a');
        try expect(states[1].char.out == 2);
        try expect(states[2].char.byte == 'a');
        try expect(states[2].char.out == 3);
        try expect(states[3].alt2.left == 2);
        try expect(states[3].alt2.right == 4);
        try expect(states[4].capture.out == 5);
    }
    {
        var prog = try Compiler.compile(a, "a{2,}?");
        defer prog.deinit();
        const states = prog.states;
        try expect(states.len == 6);
        try expect(states[0].capture.out == 1);
        try expect(states[1].char.byte == 'a');
        try expect(states[1].char.out == 2);
        try expect(states[2].char.byte == 'a');
        try expect(states[2].char.out == 3);
        try expect(states[3].alt2.left == 4);
        try expect(states[3].alt2.right == 2);
        try expect(states[4].capture.out == 5);
    }
    {
        var prog = try Compiler.compile(a, "a{2,4}");
        defer prog.deinit();
        const states = prog.states;
        try expect(states.len == 9);
        try expect(states[0].capture.out == 1);
        try expect(states[1].char.byte == 'a');
        try expect(states[1].char.out == 2);
        try expect(states[2].char.byte == 'a');
        try expect(states[2].char.out == 3);
        try expect(states[3].alt2.left == 4);
        try expect(states[3].alt2.right == 7);
        try expect(states[4].char.byte == 'a');
        try expect(states[4].char.out == 5);
        try expect(states[5].alt2.left == 6);
        try expect(states[5].alt2.right == 7);
        try expect(states[6].char.byte == 'a');
        try expect(states[6].char.out == 7);
        try expect(states[7].capture.out == 8);
    }

    {
        var prog = try Compiler.compile(a, "a{2,4}?");
        defer prog.deinit();

        const states = prog.states;
        try expect(states.len == 9);
        try expect(states[0].capture.out == 1);
        try expect(states[1].char.byte == 'a');
        try expect(states[1].char.out == 2);
        try expect(states[2].char.byte == 'a');
        try expect(states[2].char.out == 3);
        try expect(states[3].alt2.left == 7);
        try expect(states[3].alt2.right == 4);
        try expect(states[4].char.byte == 'a');
        try expect(states[4].char.out == 5);
        try expect(states[5].alt2.left == 7);
        try expect(states[5].alt2.right == 6);
        try expect(states[6].char.byte == 'a');
        try expect(states[6].char.out == 7);
        try expect(states[7].capture.out == 8);
    }
}
