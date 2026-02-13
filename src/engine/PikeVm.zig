const std = @import("std");
const Allocator = std.mem.Allocator;

const Program = @import("../syntax/Program.zig");
const StateId = Program.StateId;

const Vm = @This();

prog: Program,
current_states: SparseSet,
next_states: SparseSet,
stack: []StateId,
arena: std.heap.ArenaAllocator,

pub fn init(gpa: Allocator, prog: Program) !Vm {
    const nfa_size: u32 = @intCast(prog.states.len);
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    return .{
        .prog = prog,
        .current_states = try .init(a, nfa_size),
        .next_states = try .init(a, nfa_size),
        .stack = try a.alloc(StateId, nfa_size),
        .arena = arena,
    };
}

pub fn deinit(vm: *Vm) void {
    vm.prog.arena.deinit();
    vm.arena.deinit();
}

pub fn match(vm: *Vm, haystack: []const u8) bool {
    vm.current_states.clear();
    vm.next_states.clear();
    // StateId 0 is reserved for .fail so we start with 1
    vm.epsilon_closure_to(&vm.current_states, 1);

    // Empty match e.g. `(a|)`
    if (vm.has_match()) return true;

    var start: usize = 0;
    if (vm.has_literal_prefix()) |byte| {
        // TODO: use memchr with SIMD to find position of first byte.
        // indexOfScalar() is a linear search. Same for find().
        start = std.mem.indexOfScalar(u8, haystack, byte) orelse return false;
    }

    for (haystack[start..]) |c| {
        if (vm.current_states.count == 0) return false;
        vm.step(c);
        if (vm.has_match()) return true;
        // Start the matching process again at this position in the haystack
        // effectively rewriting compiled `pattern` into `.*pattern`.
        vm.epsilon_closure_to(&vm.current_states, 1);
    }

    return false;
}

fn has_literal_prefix(vm: *Vm) ?u8 {
    if (vm.prog.states.len < 2) return null;
    return switch (vm.prog.states[1]) {
        .char => |s| s.byte,
        else => null,
    };
}

fn epsilon_closure(vm: *Vm, id: u32) void {
    return vm.epsilon_closure_to(&vm.next_states, id);
}

fn epsilon_closure_to(vm: *Vm, state_set: *SparseSet, id: StateId) void {
    var top: usize = 0;
    std.debug.assert(vm.stack.len > 0);
    vm.stack[top] = id;
    top += 1;

    while (top > 0) {
        top -= 1;
        const state_id = vm.stack[top];
        switch (vm.prog.states[state_id]) {
            .char, .ranges, .match, .fail => {
                state_set.add(state_id);
            },
            .empty => |s| {
                std.debug.assert(top < vm.stack.len);
                vm.stack[top] = s.out;
                top += 1;
            },
            .alt2 => |s| {
                std.debug.assert(top + 1 < vm.stack.len);
                vm.stack[top] = s.left;
                vm.stack[top + 1] = s.right;
                top += 2;
            },
            .alt => |s| {
                const branches = vm.prog.branches[s.start..][0..s.len];
                std.debug.assert(top + branches.len <= vm.stack.len);
                for (branches) |branch| {
                    vm.stack[top] = branch;
                    top += 1;
                }
            },
        }
    }
}

fn step(vm: *Vm, target: u8) void {
    vm.next_states.clear();
    defer std.mem.swap(SparseSet, &vm.current_states, &vm.next_states);
    for (vm.current_states.slice()) |state_id| {
        switch (vm.prog.states[state_id]) {
            .char => |s| {
                if (target == s.byte) vm.epsilon_closure(s.out);
            },
            .ranges => |s| {
                const in_range = for (vm.prog.ranges[s.start..][0..s.len]) |range| {
                    if (range.contains(target)) break true;
                } else false;
                if (!s.negated and in_range or s.negated and !in_range) {
                    vm.epsilon_closure(s.out);
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
            .fail => {}, // simply do not add it to next_states
        }
    }
}

/// Reports if there is a .match state in current_states.
fn has_match(vm: *Vm) bool {
    for (vm.current_states.slice()) |id| {
        switch (vm.prog.states[id]) {
            .match => return true,
            else => {},
        }
    }
    return false;
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
