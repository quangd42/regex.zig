//! PikeVm engine implementation for Thompson-style NFA programs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Program = @import("../Program.zig");
const StateId = Program.StateId;
const Offset = Program.Offset;
const types = @import("../types.zig");
const assertion = @import("assertion.zig");
const GenerationSet = @import("generation_set.zig").GenerationSet;
const SearchMode = @import("../Engine.zig").SearchMode;
const Input = types.Input;
const SparseSet = @import("SparseSet.zig");

const Vm = @This();

prog: *const Program,
current_states: ThreadList,
next_states: ThreadList,
visited_epsilons: GenerationSet(u32),
scratch_slots: []?Offset,
stack: EpsilonStack,
arena: std.heap.ArenaAllocator,

pub fn init(gpa: Allocator, prog: *const Program) !Vm {
    const state_count: u32 = @intCast(prog.states.len);
    const slot_count: u32 = @as(u32, prog.capture_info.count) * 2;
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    return .{
        .prog = prog,
        .current_states = try .init(a, state_count, prog.matcher_count, slot_count),
        .next_states = try .init(a, state_count, prog.matcher_count, slot_count),
        .visited_epsilons = try .init(a, state_count),
        .stack = try .init(a, state_count),
        .scratch_slots = try initSlots(a, slot_count),
        .arena = arena,
    };
}

pub fn deinit(vm: *Vm) void {
    vm.arena.deinit();
}

/// The main matching loop.
/// Performs capture slot work according to the given `mode` and returns the
/// according value for the left-most match.
pub fn search(vm: *Vm, comptime mode: SearchMode, input: Input) ?mode.Result() {
    vm.current_states.clear();
    vm.next_states.clear();
    @memset(vm.scratchSlots(mode), null);

    const start = vm.literalPrefixOffset(input) orelse return null;
    vm.seedStartState(mode, start, input);

    var match_result: ?mode.Result() = null;
    for (input.haystack[start..input.end], start..) |c, i| {
        const offset: Offset = @intCast(i);
        // vm.next_states are threads ready to consume input at offset
        if (vm.next_states.len() > 0) {
            if (vm.step(mode, c, offset, input)) |slots| {
                match_result = vm.matchValue(mode, input, slots);
                if (mode == .presence) break;
            }
        }
        // vm.next_states are now threads for input at offset + 1
        if (match_result == null and !input.anchored) {
            // In unanchored mode, if there is no match yet, we reseed at each byte,
            // to continue looking for a match later in input. This effectively
            // rewrites compiled `pattern` into `.*pattern`, and allows assertions
            // like `$` to match even when there is no thread left.
            vm.seedStartState(mode, offset + 1, input);
        } else if (vm.next_states.len() == 0) {
            // When in anchored mode or there is already a match, then the search is
            // finished as soon as all thread dies, no reseed.
            break;
        }
    } else if (vm.hasMatch(mode)) |slots| {
        match_result = vm.matchValue(mode, input, slots);
    }

    return match_result;
}

fn scratchSlots(vm: *Vm, comptime mode: SearchMode) []?Offset {
    return switch (mode) {
        .presence => vm.scratch_slots[0..0],
        .span => vm.scratch_slots[0..2],
        .captures => vm.scratch_slots,
    };
}

fn seedStartState(vm: *Vm, comptime mode: SearchMode, at: Offset, input: Input) void {
    vm.epsilonClosure(mode, 0, at, input, vm.scratchSlots(mode));
}

/// Returns the capture slot row for a match state already present in next_states.
fn hasMatch(vm: *Vm, comptime mode: SearchMode) ?[]const ?Offset {
    for (vm.next_states.slice()) |id| {
        switch (vm.prog.states[id]) {
            .match => return vm.next_states.slotsFor(mode, id),
            else => {},
        }
    }
    return null;
}

fn matchValue(vm: *Vm, comptime mode: SearchMode, input: Input, slots: []const ?Offset) mode.Result() {
    switch (mode) {
        .presence => return,
        .span => {
            assert(slots.len == 2);
            const start = slots[0].?;
            const end = slots[1].?;
            assert(start >= input.start and end <= input.end);
            return .{ .start = start, .end = end };
        },
        .captures => {
            assert(slots.len == vm.scratch_slots.len);
            // A candidate can be kept while higher-priority threads continue.
            // Snapshot it before thread-list slot storage is reused.
            @memcpy(vm.scratch_slots, slots);
            return .{ .slots = vm.scratch_slots, .info = &vm.prog.capture_info };
        },
    }
}

/// Returns 0 if there is no literal prefix in the regex pattern.
/// Returns null if there is a literal prefix but it is not found in the haystack.
/// Otherwise returns the offset of the literal value in the haystack.
fn literalPrefixOffset(vm: *Vm, input: Input) ?Offset {
    if (input.anchored) return @intCast(input.start);
    const i: usize = if (vm.prog.literalPrefix()) |byte|
        // NOTE: indexOfScalar() already uses simd?
        std.mem.indexOfScalar(u8, input.haystack[input.start..input.end], byte) orelse return null
    else
        0;
    return @intCast(input.start + i);
}

/// Explore epsilon transitions starting at `start`, updating capture slots and
/// adding matcher states into `next_states`.
fn epsilonClosure(
    vm: *Vm,
    comptime mode: SearchMode,
    start: StateId,
    at: Offset,
    input: Input,
    slots: []?Offset,
) void {
    vm.visited_epsilons.clear();
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
    comptime mode: SearchMode,
    start: StateId,
    at: Offset,
    input: Input,
    slots: []?Offset,
) void {
    var id = start;
    while (true) {
        // Within a single epsilon closure, only explore the first visit to a state.
        if (!vm.visited_epsilons.add(id)) return;
        switch (vm.prog.states[id]) {
            .byte_range, .sparse, .any, .match, .fail => {
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
                    .presence => {},
                    .span, .captures => {
                        if (mode == .span and s.slot >= 2) continue;
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
/// Returns the capture slot row when a match state is reached.
fn step(vm: *Vm, comptime mode: SearchMode, target: u8, at: Offset, input: Input) ?[]const ?Offset {
    vm.current_states.clear();
    std.mem.swap(ThreadList, &vm.current_states, &vm.next_states);
    for (vm.current_states.slice()) |id| {
        const slots = vm.current_states.slotsFor(mode, id);
        switch (vm.prog.states[id]) {
            .byte_range => |s| if (s.contains(target)) {
                vm.epsilonClosure(mode, s.out, at + 1, input, slots);
            },
            .sparse => |s| {
                const ranges = vm.prog.transitions[s.start..][0..s.len];
                for (ranges) |r| {
                    if (r.contains(target)) vm.epsilonClosure(mode, r.out, at + 1, input, slots);
                }
            },
            .any => |s| switch (s.kind) {
                .all => vm.epsilonClosure(mode, s.out, at + 1, input, slots),
                .not_lf => if (target != '\n') {
                    vm.epsilonClosure(mode, s.out, at + 1, input, slots);
                },
            },
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

const EpsilonStack = struct {
    value: []Frame,
    top: usize,

    const Frame = union(enum) {
        explore: StateId,
        restore: struct { slot: u32, offset: ?Offset },
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
/// `set.dense` is paired with a row of `slot_count` optional offsets in the parallel
/// `slots` array.
///
/// `slotsFor(id)` is used to retrieve data row for an entry.
const ThreadList = struct {
    set: SparseSet,
    slots: []?Offset,
    slot_count: Count,

    const Count = u32;

    fn init(gpa: Allocator, state: Count, matcher: Count, slot: Count) !ThreadList {
        return .{
            .set = try .init(gpa, state, matcher),
            .slots = try initSlots(gpa, matcher * slot),
            .slot_count = slot,
        };
    }

    fn add(l: *ThreadList, comptime mode: SearchMode, id: StateId, slots: []const ?Offset) void {
        if (!l.set.add(id)) return;
        @memcpy(l.slotsFor(mode, id), slots);
    }

    /// This function must only be called when iterating over the result of `slice()`,
    /// i.e. `id` is assumed to be a member of the set.
    ///
    /// Returns a mutable slice of optional offsets for caller to modify the capture slots of `id`.
    fn slotsFor(l: *ThreadList, comptime mode: SearchMode, id: StateId) []?Offset {
        assert(l.set.contains(id));
        const dense_id = l.set.sparse[id];
        const slot_count = switch (mode) {
            .presence => 0,
            .span => 2,
            .captures => l.slot_count,
        };
        return l.slots[dense_id * l.slot_count ..][0..slot_count];
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

fn initSlots(gpa: Allocator, size: u32) ![]?Offset {
    const slots = try gpa.alloc(?Offset, size);
    @memset(slots, null);
    return slots;
}
