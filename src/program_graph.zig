//! Internal graph helpers for viewing and analyzing a compiled `Program`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Program = @import("Program.zig");

pub const Id = Program.StateId;
pub const Index = Program.Index;
pub const ByteRange = Program.ByteRange;
pub const Predicate = Program.State.Assertion.Predicate;
pub const AnyKind = Program.State.Any.Kind;

/// Canonical graph vertex used by Program introspection helpers.
///
/// Unlike `State`, every outgoing edge here points to a canonical vertex id
/// produced by `graphView` (dense labels starting at state 0). This keeps
/// test snapshots stable and independent from raw compiler state ids.
pub const Vertex = union(enum) {
    char: struct { byte: u8, out: Id },
    ranges: struct { items: []const ByteRange, negated: bool, out: Id },
    any: struct { kind: AnyKind, out: Id },
    empty: struct { out: Id },
    assert: struct { pred: Predicate, out: Id },
    capture: struct { slot: Index, out: Id },
    alt: struct { branches: []const Id },
    alt2: struct { left: Id, right: Id },
    fail,
    match,

    pub fn eql(self: Vertex, other: Vertex) bool {
        return switch (self) {
            .ranges => |w| {
                if (std.meta.activeTag(other) != .ranges) return false;
                const g = other.ranges;
                return w.negated == g.negated and
                    w.out == g.out and
                    eqlByteRanges(w.items, g.items);
            },
            .alt => |w| {
                if (std.meta.activeTag(other) != .alt) return false;
                return std.mem.eql(Id, w.branches, other.alt.branches);
            },
            inline else => |w, tag| {
                return tag == std.meta.activeTag(other) and
                    std.meta.eql(w, @field(other, @tagName(tag)));
            },
        };
    }
};

/// Owned canonical graph view rooted at program state 0.
///
/// `graphView` duplicates variable-size payloads (`ranges`, `branches`),
/// so callers must release this view with `deinit`.
pub const GraphView = struct {
    vertices: []Vertex,

    pub fn deinit(view: GraphView, gpa: Allocator) void {
        for (view.vertices) |v| {
            switch (v) {
                .ranges => |pl| gpa.free(pl.items),
                .alt => |pl| gpa.free(pl.branches),
                else => {},
            }
        }
        gpa.free(view.vertices);
    }
};

pub fn char(byte: u8, out: Id) Vertex {
    return .{ .char = .{ .byte = byte, .out = out } };
}

pub fn ranges(items: []const ByteRange, negated: bool, out: Id) Vertex {
    return .{ .ranges = .{ .items = items, .negated = negated, .out = out } };
}

pub fn r(from: u8, to: u8) ByteRange {
    return .{ .from = from, .to = to };
}

pub fn any(kind: AnyKind, out: Id) Vertex {
    return .{ .any = .{ .kind = kind, .out = out } };
}

pub fn empty(out: Id) Vertex {
    return .{ .empty = .{ .out = out } };
}

pub fn asrt(pred: Predicate, out: Id) Vertex {
    return .{ .assert = .{ .pred = pred, .out = out } };
}

pub fn capt(slot: Index, out: Id) Vertex {
    return .{ .capture = .{ .slot = slot, .out = out } };
}

pub fn alt(branches: []const Id) Vertex {
    return .{ .alt = .{ .branches = branches } };
}

pub fn alt2(left: Id, right: Id) Vertex {
    return .{ .alt2 = .{ .left = left, .right = right } };
}

pub fn fail() Vertex {
    return .fail;
}

pub fn match() Vertex {
    return .match;
}

/// Writes a text representation of canonical graph vertices.
pub fn dumpGraph(w: *std.Io.Writer, vertices: []const Vertex) !void {
    for (vertices, 0..) |state, id| {
        if (id > 0) try w.writeByte('\n');
        try w.print("s{d}: ", .{id});
        switch (state) {
            .char => |s| {
                try w.writeAll("byte(");
                try writeByteFmt(w, s.byte);
                try w.print(") -> s{d}", .{s.out});
            },
            .ranges => |s| {
                if (s.negated) try w.writeByte('!');
                try w.writeAll("ranges(");
                for (s.items, 0..) |range, r_idx| {
                    if (r_idx > 0) try w.writeAll(", ");
                    try writeByteFmt(w, range.from);
                    if (range.from != range.to) {
                        try w.writeAll("-");
                        try writeByteFmt(w, range.to);
                    }
                }
                try w.print(") -> s{d}", .{s.out});
            },
            .any => |s| try w.print("any({s}) -> s{d}", .{ @tagName(s.kind), s.out }),
            .empty => |s| try w.print("empty -> s{d}", .{s.out}),
            .assert => |s| try w.print("assert({s}) -> s{d}", .{ @tagName(s.pred), s.out }),
            .capture => |s| try w.print("capt({d}) -> s{d}", .{ s.slot, s.out }),
            .alt => |s| {
                try w.writeAll("alt(");
                for (s.branches, 0..) |out, out_idx| {
                    if (out_idx > 0) try w.writeAll(", ");
                    try w.print("s{d}", .{out});
                }
                try w.writeByte(')');
            },
            .alt2 => |s| try w.print("alt(s{d}, s{d})", .{ s.left, s.right }),
            .match => try w.writeAll("match"),
            .fail => try w.writeAll("fail"),
        }
    }
}

pub fn dumpGraphAlloc(gpa: Allocator, vertices: []const Vertex) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try dumpGraph(&aw.writer, vertices);
    return aw.toOwnedSlice();
}

/// Returns a canonical text representation of the NFA graph.
pub fn dumpProgramGraphAlloc(prog: *const Program, gpa: Allocator) ![]const u8 {
    const graph = try graphView(prog, gpa);
    defer graph.deinit(gpa);
    return dumpGraphAlloc(gpa, graph.vertices);
}

/// Returns canonical graph vertices by performing a DFS from state 0.
pub fn graphView(prog: *const Program, gpa: Allocator) !GraphView {
    const len = prog.states.len;
    if (len == 0) return .{ .vertices = try gpa.alloc(Vertex, 0) };

    const labels = try gpa.alloc(?Id, len);
    defer gpa.free(labels);
    @memset(labels, null);

    var stack = try gpa.alloc(Id, len);
    defer gpa.free(stack);
    var stack_top: usize = 0;

    var vertices: ArrayList(Vertex) = .empty;
    errdefer {
        for (vertices.items) |v| {
            switch (v) {
                .ranges => |pl| gpa.free(pl.items),
                .alt => |pl| gpa.free(pl.branches),
                else => {},
            }
        }
        vertices.deinit(gpa);
    }

    labels[0] = 0;
    var next_label: Id = 1;
    stack[0] = 0;
    stack_top += 1;
    while (stack_top > 0) {
        stack_top -= 1;
        var id = stack[stack_top];

        explore: while (true) {
            std.debug.assert(labels[id] != null);

            const label = labels[id].?;
            while (vertices.items.len <= label) {
                try vertices.append(gpa, .fail);
            }

            var next_id: ?Id = null;
            vertices.items[label] = vertex: switch (prog.states[id]) {
                .char => |s| {
                    const out = getOrAssignLabel(labels, &next_label, s.out);
                    if (out.is_new) {
                        next_id = s.out;
                    }
                    break :vertex .{ .char = .{ .byte = s.byte, .out = out.label } };
                },
                .ranges => |s| {
                    const out = getOrAssignLabel(labels, &next_label, s.out);
                    if (out.is_new) {
                        next_id = s.out;
                    }
                    const copied_ranges = try gpa.dupe(
                        ByteRange,
                        prog.ranges[s.start..][0..s.len],
                    );
                    break :vertex .{ .ranges = .{
                        .items = copied_ranges,
                        .negated = s.negated,
                        .out = out.label,
                    } };
                },
                .any => |s| {
                    const out = getOrAssignLabel(labels, &next_label, s.out);
                    if (out.is_new) {
                        next_id = s.out;
                    }
                    break :vertex .{ .any = .{ .kind = s.kind, .out = out.label } };
                },
                .empty => |s| {
                    const out = getOrAssignLabel(labels, &next_label, s.out);
                    if (out.is_new) {
                        next_id = s.out;
                    }
                    break :vertex .{ .empty = .{ .out = out.label } };
                },
                .assert => |s| {
                    const out = getOrAssignLabel(labels, &next_label, s.out);
                    if (out.is_new) {
                        next_id = s.out;
                    }
                    break :vertex .{ .assert = .{
                        .pred = s.pred,
                        .out = out.label,
                    } };
                },
                .capture => |s| {
                    const out = getOrAssignLabel(labels, &next_label, s.out);
                    if (out.is_new) {
                        next_id = s.out;
                    }
                    break :vertex .{ .capture = .{
                        .slot = s.slot,
                        .out = out.label,
                    } };
                },
                .alt => |s| {
                    const src = prog.branches[s.start..][0..s.len];
                    const branches = try gpa.alloc(Id, src.len);
                    const pushed_start = stack_top;
                    // Get label in order from source
                    for (src, 0..) |bid, i| {
                        const out = getOrAssignLabel(labels, &next_label, bid);
                        branches[i] = out.label;
                        if (!out.is_new) continue;
                        if (i == 0) {
                            next_id = bid;
                        } else {
                            std.debug.assert(stack_top < stack.len);
                            stack[stack_top] = bid;
                            stack_top += 1;
                        }
                    }
                    // Reverse pushed items to maintain left first explore order
                    std.mem.reverse(Id, stack[pushed_start..stack_top]);
                    break :vertex .{ .alt = .{ .branches = branches } };
                },
                .alt2 => |s| {
                    const left = getOrAssignLabel(labels, &next_label, s.left);
                    const right = getOrAssignLabel(labels, &next_label, s.right);
                    // Push right first, then left, so left is processed first.
                    if (right.is_new) {
                        std.debug.assert(stack_top < stack.len);
                        stack[stack_top] = s.right;
                        stack_top += 1;
                    }
                    if (left.is_new) {
                        next_id = s.left;
                    }
                    break :vertex .{ .alt2 = .{
                        .left = left.label,
                        .right = right.label,
                    } };
                },
                .match => break :vertex .match,
                .fail => break :vertex .fail,
            };
            id = next_id orelse break :explore;
        }
    }

    return .{ .vertices = try vertices.toOwnedSlice(gpa) };
}

fn eqlByteRanges(lhs: []const ByteRange, rhs: []const ByteRange) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |w, g| {
        if (w.from != g.from or w.to != g.to) return false;
    }
    return true;
}

fn getOrAssignLabel(
    labels: []?Id,
    next: *Id,
    id: Id,
) struct { label: Id, is_new: bool } {
    if (labels[id]) |l| return .{ .label = l, .is_new = false };
    const label = next.*;
    next.* += 1;
    labels[id] = label;
    return .{ .label = label, .is_new = true };
}

fn writeByteFmt(w: *std.Io.Writer, byte: u8) !void {
    try w.print("'{f}'", .{std.zig.fmtChar(byte)});
}
