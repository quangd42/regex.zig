const std = @import("std");
const Allocator = std.mem.Allocator;

const SparseSet = @import("SparseSet.zig");
const types = @import("types.zig");
const Program = types.Program;
const StateId = types.StateId;
const Match = types.Match;

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

/// Performs unanchored matching on given haystack.
pub fn match(vm: *Vm, haystack: []const u8) bool {
    vm.current_states.clear();
    vm.next_states.clear();
    vm.seedStartState();

    var start: usize = 0;
    if (vm.hasLiteralPrefix()) |byte| {
        // TODO: use memchr with SIMD to find position of first byte.
        // indexOfScalar() is a linear search. Same for find().
        start = std.mem.indexOfScalar(u8, haystack, byte) orelse return false;
    }
    for (haystack[start..]) |c| {
        if (vm.next_states.len == 0) return false;
        if (vm.step(c)) return true;
        // Start the matching process again at this position in the haystack
        // effectively rewriting compiled `pattern` into `.*pattern`.
        vm.seedStartState();
    }
    if (vm.hasMatch()) return true;
    return false;
}

/// Returns the start and end indice of the left most match into haystack. If there is no
/// match, returns null.
// TODO: currently O(n^2), refactor once captures is implemented
pub fn find(vm: *Vm, haystack: []const u8) ?Match {
    vm.current_states.clear();
    vm.next_states.clear();

    var start: usize = 0;
    if (vm.hasLiteralPrefix()) |byte| {
        start = std.mem.indexOfScalar(u8, haystack, byte) orelse return null;
    }

    for (start..haystack.len) |i| {
        if (vm.findAt(i, haystack)) |found| return found;
    }
    return null;
}

fn findAt(vm: *Vm, start: usize, haystack: []const u8) ?Match {
    vm.current_states.clear();
    vm.next_states.clear();
    vm.seedStartState();

    var best_match: ?Match = null;
    for (haystack[start..], 0..) |c, i| {
        if (vm.next_states.len == 0) return best_match;
        // The .match state is found when processing the char after the matched text.
        // So this position is incidentally also the right bound of the Match result.
        if (vm.step(c)) best_match = .{ .start = start, .end = start + i };
    }
    if (vm.hasMatch()) best_match = .{ .start = start, .end = haystack.len };
    return best_match;
}

fn hasLiteralPrefix(vm: *Vm) ?u8 {
    if (vm.prog.states.len < 2) return null;
    return switch (vm.prog.states[1]) {
        .char => |s| s.byte,
        else => null,
    };
}

fn epsilonClosure(vm: *Vm, id: StateId) void {
    var top: usize = 0;
    std.debug.assert(vm.stack.len > 0);
    vm.stack[top] = id;
    top += 1;

    const state_set = &vm.next_states;
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
                vm.stack[top] = s.right;
                vm.stack[top + 1] = s.left;
                top += 2;
            },
            .alt => |s| {
                // Alternation is added in reversed order so branches are processed in
                // left-first order in a stack.
                std.debug.assert(top + s.len <= vm.stack.len);
                var i: usize = 0;
                while (i < s.len) : (i += 1) {
                    const idx = s.start + s.len - i - 1;
                    vm.stack[top] = vm.prog.branches[idx];
                    top += 1;
                }
            },
        }
    }
}

fn step(vm: *Vm, target: u8) bool {
    vm.current_states.clear();
    std.mem.swap(SparseSet, &vm.current_states, &vm.next_states);
    return for (vm.current_states.slice()) |state_id| {
        switch (vm.prog.states[state_id]) {
            .char => |s| {
                if (target == s.byte) vm.epsilonClosure(s.out);
            },
            .ranges => |s| {
                const in_range = for (vm.prog.ranges[s.start..][0..s.len]) |range| {
                    if (range.contains(target)) break true;
                } else false;
                if (!s.negated and in_range or s.negated and !in_range) {
                    vm.epsilonClosure(s.out);
                }
            },
            .empty, .alt, .alt2 => {
                // current_states cannot hold states of these kinds because epsilon_closure()
                // makes sure to only capture `matchers` states.
                unreachable;
            },
            .match => {
                // There is a match at the previous character. We discard the other lower priority
                // threads in the list.
                //
                // If this occurs at the first character of the input, there is an empty match.
                break true;
            },
            .fail => {}, // Simply do not add this thread to next_states.
        }
    } else false;
}

// StateId 0 is reserved for .fail so we start with 1
fn seedStartState(vm: *Vm) void {
    vm.epsilonClosure(1);
}

/// Reports if there is a .match state in next_states. As the search for .match state is typically done
/// during the processing of the next character, this function is typically only called when there is
/// no more input to process.
fn hasMatch(vm: *Vm) bool {
    for (vm.next_states.slice()) |id| {
        switch (vm.prog.states[id]) {
            .match => return true,
            else => {},
        }
    }
    return false;
}
