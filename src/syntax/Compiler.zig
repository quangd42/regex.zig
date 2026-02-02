//! The Compiler compiles parsed Ast into a Thompson-style NFA: a linked collection of State
//! structures. This follows the algorithm presented in http://swtch.com/~rsc/regexp/

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Ast = @import("Ast.zig");

const StateId = u32;
const Compiler = @This();

states: std.MultiArrayList(State) = .empty,
ranges: ArrayList(ByteRange) = .empty,
branches: ArrayList(StateId) = .empty,
/// arena, states, ranges and branches are owned by Program after compilation is done.
arena: std.heap.ArenaAllocator,

pub fn init(gpa: Allocator) Compiler {
    return .{ .arena = .init(gpa) };
}

pub fn compile(c: *Compiler, ast: Ast) !Program {
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
        .states = c.states.slice(),
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
                .digit => try c.emitCommonRanges(.digit, 1),
                .word => try c.emitCommonRanges(.lower_alpha, 4),
                .space => try c.emitCommonRanges(.literal_space, 2),
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
                const payloads = c.states.items(.data);
                payloads[id] = .{ .alt2 = .{ .left = left.id, .right = right.id } };
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
    const state_id: StateId = @intCast(c.states.len);
    try c.states.append(c.arena.allocator(), state);
    return state_id;
}

fn emitCommonRanges(c: *Compiler, range_start: CommonByteRange, len: Length) !StateId {
    return c.emitState(.{ .ranges = .{ .start = @intFromEnum(range_start), .len = len, .out = 0 } });
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
            const states = c.states.slice();
            const tags = states.items(.tags);
            const payloads = states.items(.data);
            const pl = &payloads[self.id];
            switch (tags[self.id]) {
                .char => pl.char.out = value,
                .ranges => pl.ranges.out = value,
                .empty => pl.empty.out = value,
                .alt2 => switch (self.field) {
                    .left => pl.alt2.left = value,
                    .right => pl.alt2.right = value,
                },
                else => unreachable,
            }
        }

        /// Finds the value at the field encoded by Ptr. This value is assumed to be
        /// encoded and is turned into a new Ptr and returned.
        fn get(self: Ptr, c: *Compiler) Ptr {
            const states = c.states.slice();
            const tags = states.items(.tags);
            const payloads = states.items(.data);
            const pl = &payloads[self.id];
            return .fromId(
                switch (tags[self.id]) {
                    .char => pl.char.out,
                    .ranges => pl.ranges.out,
                    .empty => pl.empty.out,
                    .alt2 => switch (self.field) {
                        .left => pl.alt2.left,
                        .right => pl.alt2.right,
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

/// State Opcode
const Op = enum(u8) {
    char,
    ranges,
    empty,
    alt,
    alt2,
    match,
    fail,
};

/// Index into metadata pool, such as Program.ranges or .branches, typically
/// used as the 'start pointer' of a slice in the pool. For example, State.ranges
/// is stored as a slice of the Program.ranges pool.
pub const Index = u32;
/// Length is the size of a slice in metadata pool.
pub const Length = u16;
/// ByteRange is inclusive on both ends.
pub const ByteRange = struct { from: u8, to: u8 };

pub const State = union(Op) {
    char: struct { byte: u8, out: StateId },
    ranges: struct { start: Index, len: Length, out: StateId },
    empty: struct { out: StateId },
    alt: struct { start: Index, len: Length },
    alt2: struct { left: StateId, right: StateId },
    match,
    fail,
};

pub const Program = struct {
    /// State list split into tags and payloads.
    states: std.MultiArrayList(State).Slice,
    /// Byte ranges referenced by State.ranges.
    ranges: []ByteRange,
    /// Alternation targets referenced by State.alt.
    branches: []Index,
    /// Arena that owns the backing memory for states/ranges/branches.
    arena: std.heap.ArenaAllocator,
};

fn dumpDebug(prog: Program) void {
    std.debug.print("States\n", .{});
    const state_tags = prog.states.items(.tags);
    const state_payloads = prog.states.items(.data);
    for (state_tags, state_payloads, 0..) |tag, payload, i| {
        switch (tag) {
            .char => std.debug.print(
                "{d:>3} {s:<8} byte={c}  out={d:<3}\n",
                .{ i, @tagName(tag), payload.char.byte, payload.char.out },
            ),
            .ranges => {
                std.debug.print(
                    "{d:>3} {s:<8}         out={d:<3}  start={d:<3} len={d:<3}\n",
                    .{ i, @tagName(tag), payload.ranges.out, payload.ranges.start, payload.ranges.len },
                );
            },
            .alt => {
                std.debug.print(
                    "{d:>3} {s:<8}                  start={d:<3} len={d:<3}",
                    .{ i, @tagName(tag), payload.alt.start, payload.alt.len },
                );
                std.debug.print("  [ ", .{});
                for (prog.branches[payload.alt.start..][0..payload.alt.len]) |out_idx| {
                    std.debug.print("{d} ", .{out_idx});
                }
                std.debug.print("]\n", .{});
            },
            .alt2 => {
                std.debug.print(
                    "{d:>3} {s:<8}         left={d:<3} right={d:<3}\n",
                    .{ i, @tagName(tag), payload.alt2.left, payload.alt2.right },
                );
            },
            .empty => std.debug.print("{d:>3} {s:<8}         out={d:<3}\n", .{ i, @tagName(tag), payload.empty.out }),
            .match => std.debug.print("{d:>3} {s:<8}\n", .{ i, @tagName(tag) }),
            .fail => std.debug.print("{d:>3} {s:<8}\n", .{ i, @tagName(tag) }),
        }
    }

    std.debug.print("\nRanges:\n", .{});
    for (prog.ranges, 0..) |range, i| {
        std.debug.print("{d:>3} {{ from = {c}, to = {c} }}\n", .{ i, range.from, range.to });
    }
}

const testing = std.testing;

test "compile and dump" {
    const a = testing.allocator;

    const pattern = "a((b|c)|\\d|)(x|y)z";
    const Parser = @import("Parser.zig");
    const St = @import("Ast.zig");
    var parser: Parser = .init(a, pattern);
    defer parser.deinit();

    const ast: St = try parser.parse();

    var compiler: Compiler = .init(a);
    const prog = try compiler.compile(ast);
    dumpDebug(prog);
    prog.arena.deinit();
}
