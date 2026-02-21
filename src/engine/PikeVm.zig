const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const SparseSet = @import("SparseSet.zig");
const types = @import("types.zig");
const Program = @import("../syntax/Program.zig");
const StateId = types.StateId;
const Match = types.Match;
const Captures = types.Captures;

const Vm = @This();

prog: Program,
current_states: ThreadList,
next_states: ThreadList,
stack: EpsilonStack,
scratch_slots: []Offset,
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

/// Performs unanchored matching on given haystack.
pub fn match(vm: *Vm, haystack: []const u8) bool {
    return vm.search(.none, haystack);
}

/// Returns the start and end indice of the left most match into haystack.
/// If there is no match, returns null.
pub fn find(vm: *Vm, haystack: []const u8) ?Match {
    const has_match = vm.search(.bounds, haystack);
    return if (has_match) vm.buildMatch(0) else null;
}

/// Searches for a match and writes capture groups into the supplied buffer.
/// Returns Captures wrapping the buffer on match, or null if no match is found.
/// Asserts that `buffer.len` is at least `capturesLen()`.
pub fn findCaptures(vm: *Vm, haystack: []const u8, buffer: []?Match) ?Captures {
    const has_match = vm.search(.full, haystack);
    return if (has_match) vm.buildCaptures(buffer) else null;
}

/// Convenient function that creates a buffer of the correct size on the heap,
/// and call `findCaptures()` with it. Caller owns the return buffer.
pub fn findCapturesAlloc(vm: *Vm, gpa: Allocator, haystack: []const u8) !?Captures {
    const buffer = try gpa.alloc(?Match, vm.capturesLen());
    if (vm.findCaptures(haystack, buffer)) |captures| {
        return captures;
    }
    gpa.free(buffer);
    return null;
}

/// Returns the number of capture groups (including group 0 for the full match).
/// Useful to determine the required minimum size of buffer for `findCaptures()`.
pub fn capturesLen(vm: *Vm) usize {
    return vm.prog.group_count;
}

/// Controls how much capture slot work is done during a search.
/// - `none`: no slot operations - for `match()`.
/// - `bounds`: track only slots 0-1, i.e. group 0 match - for `find()`.
/// - `full`: track all slots - for `findCaptures()`.
const CaptureMode = enum { none, bounds, full };

/// The bulk of the work. Is is specialized with comptime CaptureMode.
fn search(vm: *Vm, comptime mode: CaptureMode, haystack: []const u8) bool {
    vm.current_states.clear();
    vm.next_states.clear();

    const start = vm.literalPrefixOffset(haystack) orelse return false;
    vm.seedStartState(mode, start);

    var slots_for_match: ?[]Offset = null;
    for (haystack[start..], start..) |c, i| {
        const offset: u32 = @intCast(i);
        if (vm.next_states.len() == 0) break;
        if (vm.step(mode, c, offset)) |slots| {
            slots_for_match = slots;
            if (mode == .none) break;
        }
        // If there is no match yet, start the matching process from the top
        // with the next character in the input. This effectively rewrites
        // compiled `pattern` into `.*pattern`.
        if (slots_for_match == null) vm.seedStartState(mode, offset + 1);
    } else if (vm.hasMatch()) |slots| slots_for_match = slots;

    if (slots_for_match) |slots| vm.recordMatch(mode, slots);
    return slots_for_match != null;
}

/// Returns 0 if there is NOT a literal prefix in regex pattern.
/// Returns null if there IS a literal prefix, but the literal value does not
/// exist in the haystack (no match).
/// Returns the offset of the literal value in the haystack otherwise.
fn literalPrefixOffset(vm: *Vm, haystack: []const u8) ?Offset {
    if (vm.prog.literalPrefix()) |byte| {
        // TODO: use memchr with SIMD to find position of first byte.
        // indexOfScalar() is a linear search. Same for find().
        const i = std.mem.indexOfScalar(u8, haystack, byte) orelse return null;
        return @intCast(i);
    }
    return 0;
}

fn epsilonClosure(vm: *Vm, comptime mode: CaptureMode, start: StateId, at: Offset, slots: []Offset) void {
    vm.stack.push(.{ .explore = start });
    while (!vm.stack.isEmpty()) {
        const top = vm.stack.pop();
        switch (top) {
            .restore => |r| slots[r.slot] = r.offset,
            .explore => |e| {
                var id = e;
                explore: while (true) {
                    switch (vm.prog.states[id]) {
                        .char, .ranges, .match, .fail => {
                            vm.next_states.add(mode, id, slots);
                            break :explore;
                        },
                        .empty => |s| {
                            id = s.out;
                        },
                        .capture => |s| {
                            id = s.out;
                            switch (mode) {
                                .none => {},
                                .bounds, .full => {
                                    if (mode == .bounds and s.slot >= 2) continue :explore;
                                    vm.stack.push(.{ .restore = .{ .slot = s.slot, .offset = slots[s.slot] } });
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
            },
        }
    }
}

fn step(vm: *Vm, comptime mode: CaptureMode, target: u8, at: Offset) ?[]Offset {
    vm.current_states.clear();
    std.mem.swap(ThreadList, &vm.current_states, &vm.next_states);
    for (vm.current_states.slice()) |id| {
        const slots = vm.current_states.slotsFor(id);
        switch (vm.prog.states[id]) {
            .char => |s| {
                if (target == s.byte) vm.epsilonClosure(mode, s.out, at + 1, slots);
            },
            .ranges => |s| {
                const in_range = for (vm.prog.ranges[s.start..][0..s.len]) |range| {
                    if (range.contains(target)) break true;
                } else false;
                // !s.negated and in_range or s.negated and !in_range
                if (in_range != s.negated) vm.epsilonClosure(mode, s.out, at + 1, slots);
            },
            .empty, .capture, .alt, .alt2 => {
                // current_states cannot hold states of these kinds because epsilon_closure()
                // makes sure to only capture `matchers` states.
                unreachable;
            },
            .fail => {}, // Simply do not add this thread to next_states.
            .match => {
                // There is a match at the previous character. The other lower priority threads
                // in the list are discarded.
                //
                // If this occurs at the first character of the input, there is an empty match.
                return slots;
            },
        }
    }
    return null;
}

inline fn seedStartState(vm: *Vm, comptime mode: CaptureMode, at: Offset) void {
    vm.epsilonClosure(mode, 0, at, vm.scratch_slots);
}

fn hasMatch(vm: *Vm) ?[]Offset {
    for (vm.next_states.slice()) |id| {
        switch (vm.prog.states[id]) {
            .match => return vm.next_states.slotsFor(id),
            else => {},
        }
    }
    return null;
}

inline fn recordMatch(vm: *Vm, comptime mode: CaptureMode, slots: []Offset) void {
    switch (mode) {
        .none => {},
        .bounds => @memcpy(vm.scratch_slots[0..2], slots[0..2]),
        .full => @memcpy(vm.scratch_slots, slots),
    }
}

fn buildMatch(vm: *Vm, even_pos: u32) ?Match {
    assert(even_pos + 1 < vm.scratch_slots.len);
    const start = vm.scratch_slots[even_pos];
    const end = vm.scratch_slots[even_pos + 1];
    if (start == null_offset or end == null_offset) {
        return null;
    }
    return .{ .start = start, .end = end };
}

fn buildCaptures(vm: *Vm, buffer: []?Match) ?Captures {
    const group_count = vm.prog.group_count;
    assert(buffer.len >= group_count);
    assert(vm.buildMatch(0) != null);
    var pos: u32 = 0;
    while (pos < group_count) : (pos += 1) {
        buffer[pos] = vm.buildMatch(pos * 2);
    }
    return .{ .groups = buffer[0..group_count] };
}

const Offset = types.Offset;
const null_offset = types.null_offset;

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

    inline fn push(s: *EpsilonStack, frame: Frame) void {
        assert(s.top < s.value.len);
        s.value[s.top] = frame;
        s.top += 1;
    }

    inline fn pop(s: *EpsilonStack) Frame {
        assert(s.top > 0);
        s.top -= 1;
        return s.value[s.top];
    }

    inline fn isEmpty(s: *EpsilonStack) bool {
        return s.top == 0;
    }
};

/// A set of active NFA threads with associated capture slot data.
///
/// Internally, it wraps a SparseSet for O(1) membership checks and pairs each entry with a row
/// of `slot_count` InputOffset values.
///
/// The `slots` array is parallel to `set.dense` (and is also densely packed) - see `slotsFor(id)`.
const ThreadList = struct {
    set: SparseSet,
    slots: []Offset,
    slot_count: u32,

    fn init(gpa: Allocator, state_count: u32, matcher_count: u32, slot_count: u32) !ThreadList {
        return .{
            .set = try .init(gpa, state_count, matcher_count),
            .slots = try initSlots(gpa, matcher_count * slot_count),
            .slot_count = slot_count,
        };
    }

    fn add(l: *ThreadList, comptime mode: CaptureMode, id: StateId, slots: []Offset) void {
        if (!l.set.add(id)) return;
        switch (mode) {
            .none => {},
            .bounds => @memcpy(l.slotsFor(id)[0..2], slots[0..2]),
            .full => @memcpy(l.slotsFor(id), slots),
        }
    }

    fn slotsFor(l: *ThreadList, id: StateId) []Offset {
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
