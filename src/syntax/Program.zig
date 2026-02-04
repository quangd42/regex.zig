const std = @import("std");

/// Index into State pool
pub const StateId = u32;
/// Index into metadata pool, such as Program.ranges or .branches, typically
/// used as the 'start pointer' of a slice in the pool. For example, State.ranges
/// is stored as a slice of the Program.ranges pool.
pub const Index = u32;
/// Length is the size of a slice in metadata pool.
pub const Length = u16;
/// ByteRange is inclusive on both ends.
pub const ByteRange = struct {
    from: u8,
    to: u8,

    pub fn contains(self: ByteRange, byte: u8) bool {
        return self.from <= byte and byte <= self.to;
    }
};

pub const State = union(enum) {
    char: struct { byte: u8, out: StateId },
    ranges: struct { start: Index, len: Length, out: StateId },
    empty: struct { out: StateId },
    alt: struct { start: Index, len: Length },
    alt2: struct { left: StateId, right: StateId },
    match,
    fail,
};

const Program = @This();

/// State list split into tags and payloads.
states: []State,
/// Byte ranges referenced by State.ranges.
ranges: []ByteRange,
/// Alternation targets referenced by State.alt.
branches: []Index,
/// Arena that owns the backing memory for states/ranges/branches.
arena: std.heap.ArenaAllocator,

pub fn deinit(p: *Program) void {
    p.arena.deinit();
}

fn dumpDebug(prog: Program) void {
    std.debug.print("States\n", .{});
    for (prog.states, 0..) |state, i| {
        switch (state) {
            .char => |pl| std.debug.print(
                "{d:>3} {s:<8} byte={c}  out={d:<3}\n",
                .{ i, @tagName(state), pl.byte, pl.out },
            ),
            .ranges => |pl| {
                std.debug.print(
                    "{d:>3} {s:<8}         out={d:<3}  start={d:<3} len={d:<3}\n",
                    .{ i, @tagName(state), pl.out, pl.start, pl.len },
                );
            },
            .alt => |pl| {
                std.debug.print(
                    "{d:>3} {s:<8}                  start={d:<3} len={d:<3}",
                    .{ i, @tagName(state), pl.start, pl.len },
                );
                std.debug.print("  [ ", .{});
                for (prog.branches[pl.start..][0..pl.len]) |out_idx| {
                    std.debug.print("{d} ", .{out_idx});
                }
                std.debug.print("]\n", .{});
            },
            .alt2 => |pl| {
                std.debug.print(
                    "{d:>3} {s:<8}         left={d:<3} right={d:<3}\n",
                    .{ i, @tagName(state), pl.left, pl.right },
                );
            },
            .empty => |pl| std.debug.print("{d:>3} {s:<8}         out={d:<3}\n", .{ i, @tagName(state), pl.out }),
            .match => std.debug.print("{d:>3} {s:<8}\n", .{ i, @tagName(state) }),
            .fail => std.debug.print("{d:>3} {s:<8}\n", .{ i, @tagName(state) }),
        }
    }

    std.debug.print("\nRanges:\n", .{});
    for (prog.ranges, 0..) |range, i| {
        std.debug.print("{d:>3} {{ from = {c}, to = {c} }}\n", .{ i, range.from, range.to });
    }
}
