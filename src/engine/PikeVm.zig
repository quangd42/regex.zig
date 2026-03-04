//! PikeVm engine implementation for Thompson-style NFA programs. Public API mirrors `src/Regex.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Program = @import("../syntax/Program.zig");
const regex = @import("../types.zig");
const Match = regex.Match;
const Captures = regex.Captures;
const engine = @import("types.zig");
const assertion = @import("assertion.zig");
const StateId = engine.StateId;
const Input = engine.Input;
const SparseSet = @import("SparseSet.zig");

const Vm = @This();

prog: Program,
current_states: ThreadList,
next_states: ThreadList,
scratch_slots: []Offset,
stack: EpsilonStack,
arena: std.heap.ArenaAllocator,

pub fn init(gpa: Allocator, prog: Program) !Vm {
    const state_count: u32 = @intCast(prog.states.len);
    const slot_count: u32 = @as(u32, @intCast(prog.group_count)) * 2;
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    return .{
        .prog = prog,
        .current_states = try .init(a, state_count, prog.matcher_count, slot_count),
        .next_states = try .init(a, state_count, prog.matcher_count, slot_count),
        .stack = try .init(a, state_count),
        .scratch_slots = try initSlots(a, slot_count),
        .arena = arena,
    };
}

pub fn deinit(vm: *Vm) void {
    vm.prog.arena.deinit();
    vm.arena.deinit();
}

pub fn match(vm: *Vm, haystack: []const u8) bool {
    return vm.search(.none, .init(haystack)) != null;
}

pub fn find(vm: *Vm, haystack: []const u8) ?Match {
    const slots = vm.search(.bounds, .init(haystack)) orelse return null;
    return buildMatch(slots);
}

pub fn findCaptures(vm: *Vm, haystack: []const u8, buffer: []?Match) ?Captures {
    const slots = vm.search(.full, .init(haystack)) orelse return null;
    return vm.buildCaptures(slots, buffer);
}

pub fn findCapturesAlloc(vm: *Vm, gpa: Allocator, haystack: []const u8) !?Captures {
    const buffer = try gpa.alloc(?Match, vm.capturesLen());
    if (vm.findCaptures(haystack, buffer)) |captures| {
        return captures;
    }
    gpa.free(buffer);
    return null;
}

pub fn capturesLen(vm: *Vm) usize {
    return vm.prog.group_count;
}

/// Controls how much capture slot work is done during a search.
/// - `none`: no slot operations - for `match()`.
/// - `bounds`: track only slots 0-1, i.e. group 0 match - for `find()`.
/// - `full`: track all slots - for `findCaptures()`.
const Mode = enum { none, bounds, full };

/// The main matching loop.
/// Performs capture slot work according to the given `mode` and returns whether
/// a left-most match was found.
fn search(vm: *Vm, comptime mode: Mode, input: Input) ?[]const Offset {
    vm.current_states.clear();
    vm.next_states.clear();

    const start = vm.literalPrefixOffset(input) orelse return null;
    vm.seedStartState(mode, start, input);

    var slots_for_match: ?[]const Offset = null;
    for (input.haystack[start..], start..) |c, i| {
        const offset: u32 = @intCast(i);
        if (vm.next_states.len() == 0) break;
        if (vm.step(mode, c, offset, input)) |slots| {
            slots_for_match = slots;
            if (mode == .none) break;
        }
        // If there is no match yet, start the matching process from the top
        // with the next character in the input. This effectively rewrites
        // compiled `pattern` into `.*pattern`.
        if (slots_for_match == null and !input.anchored) {
            vm.seedStartState(mode, offset + 1, input);
        }
    } else if (vm.hasMatch()) |slots| slots_for_match = slots;

    return slots_for_match;
}

/// Returns 0 if there is no literal prefix in the regex pattern.
/// Returns null if there is a literal prefix but it is not found in the haystack.
/// Otherwise returns the offset of the literal value in the haystack.
fn literalPrefixOffset(vm: *Vm, input: Input) ?Offset {
    if (input.anchored) return 0;
    if (vm.prog.literalPrefix()) |byte| {
        // NOTE: indexOfScalar() already uses simd if possible under the hood,
        // but perhaps it can be tuned specifically for this use case.
        const i = std.mem.indexOfScalar(u8, input.haystack, byte) orelse return null;
        return @intCast(i);
    }
    return 0;
}

/// Explore epsilon transitions starting at `start`, updating capture slots and
/// adding matcher states into `next_states`.
fn epsilonClosure(
    vm: *Vm,
    comptime mode: Mode,
    start: StateId,
    at: Offset,
    input: Input,
    slots: []Offset,
) void {
    vm.stack.push(.{ .explore = start });
    while (!vm.stack.isEmpty()) {
        const top = vm.stack.pop();
        switch (top) {
            .restore => |r| slots[r.slot] = r.offset,
            .explore => |e| vm.explore(mode, e, at, input, slots),
        }
    }
}

/// Depth-first traversal for a single epsilon path. Handles captures and
/// alternation ordering before queuing matcher states.
fn explore(
    vm: *Vm,
    comptime mode: Mode,
    start: StateId,
    at: Offset,
    input: Input,
    slots: []Offset,
) void {
    var id = start;
    while (true) {
        switch (vm.prog.states[id]) {
            .char, .ranges, .any, .match, .fail => {
                vm.next_states.add(mode, id, slots);
                break;
            },
            .empty => |s| {
                id = s.out;
            },
            .assert => |s| {
                const success = assertion.assert(s.pred, input.haystack, at);
                if (success) id = s.out else break;
            },
            .capture => |s| {
                id = s.out;
                switch (mode) {
                    .none => {},
                    .bounds, .full => {
                        if (mode == .bounds and s.slot >= 2) continue;
                        vm.stack.push(.{
                            .restore = .{ .slot = s.slot, .offset = slots[s.slot] },
                        });
                        slots[s.slot] = at;
                    },
                }
            },
            .alt2 => |s| {
                // Push right branch (lower priority), continue with left.
                vm.stack.push(.{ .explore = s.right });
                id = s.left;
            },
            .alt => |s| {
                // Branches (except the first) are pushed in reversed order.
                const branches = vm.prog.branches[s.start..][0..s.len];
                assert(branches.len > 2);
                var i = branches.len;
                while (i > 1) {
                    i -= 1;
                    vm.stack.push(.{ .explore = branches[i] });
                }
                // Continue with first branch.
                id = branches[0];
            },
        }
    }
}

/// Advances all active threads by one byte.
/// Returns the winning slot snapshot when a match state is reached.
fn step(vm: *Vm, comptime mode: Mode, target: u8, at: Offset, input: Input) ?[]const Offset {
    vm.current_states.clear();
    std.mem.swap(ThreadList, &vm.current_states, &vm.next_states);
    for (vm.current_states.slice()) |id| {
        const slots = vm.current_states.slotsFor(id);
        switch (vm.prog.states[id]) {
            .char => |s| if (target == s.byte) {
                vm.epsilonClosure(mode, s.out, at + 1, input, slots);
            },
            .ranges => |s| {
                const ranges = vm.prog.ranges[s.start..][0..s.len];
                const in_range = for (ranges) |range| {
                    if (range.contains(target)) break true;
                } else false;
                // !s.negated and in_range or s.negated and !in_range
                if (in_range != s.negated) vm.epsilonClosure(mode, s.out, at + 1, input, slots);
            },
            .any => |s| vm.epsilonClosure(mode, s.out, at + 1, input, slots),
            .empty, .capture, .assert, .alt, .alt2 => {
                // current_states cannot hold these states because epsilon_closure()
                // makes sure to only capture `matchers` states.
                unreachable;
            },
            .fail => {}, // Simply do not add this thread to next_states.
            .match => {
                // There is a match at the previous character. The other lower
                // priority threads in the list are discarded.
                //
                // If this occurs at the first character of the input, there is
                // an empty match.
                return slots;
            },
        }
    }
    return null;
}

fn seedStartState(vm: *Vm, comptime mode: Mode, at: Offset, input: Input) void {
    vm.epsilonClosure(mode, 0, at, input, vm.scratch_slots);
}

/// Returns the slot snapshot for a match state already present in next_states.
fn hasMatch(vm: *Vm) ?[]const Offset {
    for (vm.next_states.slice()) |id| {
        switch (vm.prog.states[id]) {
            .match => return vm.next_states.slotsFor(id),
            else => {},
        }
    }
    return null;
}

/// Builds a Match from the first pair of the given slots.
/// Returns null if either is unset.
fn buildMatch(slots: []const Offset) ?Match {
    assert(slots.len >= 2);
    const even = slots[0];
    const odd = slots[1];
    if (even == null_offset or odd == null_offset) {
        return null;
    }
    return .{ .start = even, .end = odd };
}

/// Fills the buffer with given capture slots and wraps it as Captures.
/// Asserts that the buffer is big enough to contain matched slots.
fn buildCaptures(vm: *Vm, slots: []const Offset, buffer: []?Match) ?Captures {
    const group_count = vm.prog.group_count;
    assert(buffer.len >= group_count);
    assert(slots.len >= group_count * 2);
    assert(buildMatch(slots) != null);
    for (0..group_count) |i| {
        buffer[i] = buildMatch(slots[i * 2 ..]);
    }
    return .{ .groups = buffer[0..group_count] };
}

const Offset = engine.Offset;
/// Sentinel value for null offset. There is no check for null because in practice an input of anything
/// close to this size might already cause other problems before it gets here.
const null_offset = std.math.maxInt(Offset);

const EpsilonStack = struct {
    value: []Frame,
    top: usize,

    const Frame = union(enum) {
        explore: StateId,
        restore: struct { slot: u32, offset: Offset },
    };

    fn init(gpa: Allocator, state_count: u32) !EpsilonStack {
        return .{ .value = try gpa.alloc(Frame, state_count), .top = 0 };
    }

    fn push(s: *EpsilonStack, frame: Frame) void {
        assert(s.top < s.value.len);
        s.value[s.top] = frame;
        s.top += 1;
    }

    fn pop(s: *EpsilonStack) Frame {
        assert(s.top > 0);
        s.top -= 1;
        return s.value[s.top];
    }

    fn isEmpty(s: *EpsilonStack) bool {
        return s.top == 0;
    }
};

/// A set of active NFA threads with associated capture slot data.
///
/// Internally, it wraps a SparseSet for O(1) membership checks. Each entry in
/// `set.dense` is paired with a row of `slot_count` Offset values in the parallel
/// `slots` array.
///
/// `slotsFor(id)` is used to retrieve data row for an entry.
const ThreadList = struct {
    set: SparseSet,
    slots: []Offset,
    slot_count: Count,

    const Count = u32;

    fn init(gpa: Allocator, state: Count, matcher: Count, slot: Count) !ThreadList {
        return .{
            .set = try .init(gpa, state, matcher),
            .slots = try initSlots(gpa, matcher * slot),
            .slot_count = slot,
        };
    }

    fn add(l: *ThreadList, comptime mode: Mode, id: StateId, slots: []const Offset) void {
        if (!l.set.add(id)) return;
        switch (mode) {
            .none => {},
            .bounds => @memcpy(l.slotsFor(id)[0..2], slots[0..2]),
            .full => @memcpy(l.slotsFor(id), slots),
        }
    }

    /// This function must only be called when iterating over the result of `slice()`,
    /// i.e. `id` is assumed to be a member of the set.
    ///
    /// Returns a mutable slice of Offset for caller to modify the capture slots of `id`.
    fn slotsFor(l: *ThreadList, id: StateId) []Offset {
        assert(l.set.contains(id));
        const dense_id = l.set.sparse[id];
        return l.slots[dense_id * l.slot_count ..][0..l.slot_count];
    }

    fn len(l: *ThreadList) usize {
        return l.set.len;
    }

    fn slice(l: *ThreadList) []StateId {
        return l.set.slice();
    }

    fn clear(l: *ThreadList) void {
        l.set.clear();
    }
};

fn initSlots(gpa: Allocator, size: u32) ![]Offset {
    const slots = try gpa.alloc(Offset, size);
    @memset(slots, null_offset);
    return slots;
}
