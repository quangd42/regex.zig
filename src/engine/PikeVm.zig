const std = @import("std");
const Allocator = std.mem.Allocator;

const Program = @import("../syntax/Program.zig");
const StateId = Program.StateId;

const Vm = @This();

prog: Program,
current_states: SparseSet,
next_states: SparseSet,
arena: std.heap.ArenaAllocator,

pub fn init(gpa: Allocator, prog: Program) !Vm {
    const nfa_size: u32 = @intCast(prog.states.len);
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    return .{
        .prog = prog,
        .current_states = try .init(a, nfa_size),
        .next_states = try .init(a, nfa_size),
        .arena = arena,
    };
}

pub fn deinit(vm: *Vm) void {
    vm.prog.arena.deinit();
    vm.arena.deinit();
}

pub fn match(vm: *Vm, haystack: []const u8) bool {
    // StateId 0 is reserved for .fail so we start with 1
    vm.epsilon_closure(&vm.current_states, 1);

    for (haystack) |c| {
        if (vm.current_states.count == 0) return false;
        vm.step(c);
    }

    // If there is .match in the final set of states, there is a match
    for (vm.current_states.slice()) |id| {
        switch (vm.prog.states[id]) {
            .match => return true,
            else => {},
        }
    }
    return false;
}

// TODO: use dfs instead of recursion
fn epsilon_closure(vm: *Vm, state_set: *SparseSet, id: StateId) void {
    switch (vm.prog.states[id]) {
        .char, .ranges, .match, .fail => {
            state_set.add(id);
        },
        .empty => |s| {
            vm.epsilon_closure(state_set, s.out);
        },
        .alt2 => |s| {
            vm.epsilon_closure(state_set, s.left);
            vm.epsilon_closure(state_set, s.right);
        },
        .alt => |s| {
            for (vm.prog.branches[s.start..][0..s.len]) |branch| {
                vm.epsilon_closure(state_set, branch);
            }
        },
    }
}

fn step(vm: *Vm, target: u8) void {
    vm.next_states.clear();
    for (vm.current_states.slice()) |state_id| {
        switch (vm.prog.states[state_id]) {
            .char => |s| {
                if (target == s.byte) {
                    vm.epsilon_closure(&vm.next_states, s.out);
                }
            },
            .ranges => |s| {
                for (vm.prog.ranges[s.start..][0..s.len]) |range| {
                    if (range.contains(target)) {
                        vm.epsilon_closure(&vm.next_states, s.out);
                    }
                }
            },
            .empty, .alt, .alt2 => {
                // current_states cannot hold states of these kinds because epsilon_closure()
                // makes sure to only capture `matchers` states.
                unreachable;
            },
            .match => {
                // TODO: what does this mean?
                // allow for longer match but cut off other states???
            },
            .fail => return,
        }
    }
    std.mem.swap(SparseSet, &vm.current_states, &vm.next_states);
}

const SparseSet = struct {
    sparse: []StateId,
    dense: []StateId,
    count: u32,
    max: u32,

    fn init(gpa: Allocator, size: u32) !SparseSet {
        return .{
            .sparse = try gpa.alloc(StateId, size),
            .dense = try gpa.alloc(StateId, size),
            .count = 0,
            .max = size,
        };
    }

    fn deinit(s: *SparseSet, gpa: Allocator) void {
        gpa.free(s.sparse);
        gpa.free(s.dense);
    }

    fn findIndex(s: *SparseSet, id: StateId) ?u32 {
        if (id >= s.max) return null;
        const idx = s.sparse[id];
        if (idx < s.count and s.dense[idx] == id) return idx;
        return null;
    }

    fn contains(s: *SparseSet, id: StateId) bool {
        return s.findIndex(id) != null;
    }

    fn add(s: *SparseSet, id: StateId) void {
        if (s.findIndex(id) != null) return; // StateId exists
        if (id >= s.max) return; // Invalid StateId
        std.debug.assert(s.count < s.max); // add() dedups valid ids so s.count can never exceed s.max
        s.dense[s.count] = id;
        s.sparse[id] = s.count;
        s.count += 1;
    }

    fn remove(s: *SparseSet, id: StateId) void {
        const idx = s.findIndex(id) orelse return; // Nothing to remove
        const moved = s.dense[s.count - 1];
        s.dense[idx] = moved;
        s.sparse[moved] = idx;
        s.count -= 1;
    }

    fn clear(s: *SparseSet) void {
        s.count = 0;
    }

    fn slice(s: *SparseSet) []StateId {
        return s.dense[0..s.count];
    }
};

const testing = std.testing;

test "SparseSet add/remove basics" {
    var set = try SparseSet.init(testing.allocator, 8);
    defer set.deinit(testing.allocator);

    set.add(1);
    set.add(2);
    set.add(3);
    try testing.expectEqual(@as(usize, 3), set.slice().len);
    try testing.expectEqual(@as(StateId, 1), set.slice()[0]);
    try testing.expectEqual(@as(StateId, 2), set.slice()[1]);
    try testing.expectEqual(@as(StateId, 3), set.slice()[2]);

    set.remove(2);
    try testing.expectEqual(@as(usize, 2), set.slice().len);
    try testing.expectEqual(@as(StateId, 1), set.slice()[0]);
    try testing.expectEqual(@as(StateId, 3), set.slice()[1]);
    try testing.expect(set.findIndex(2) == null);
}

test "SparseSet clear and dedupe" {
    var set = try SparseSet.init(testing.allocator, 4);
    defer set.deinit(testing.allocator);

    set.add(0);
    set.add(1);
    set.add(1);
    try testing.expectEqual(@as(usize, 2), set.slice().len);

    set.clear();
    try testing.expectEqual(@as(usize, 0), set.slice().len);

    set.add(3);
    set.add(3);
    try testing.expectEqual(@as(usize, 1), set.slice().len);
    try testing.expectEqual(@as(StateId, 3), set.slice()[0]);
}
