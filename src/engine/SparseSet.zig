const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
pub const StateId = types.StateId;

const SparseSet = @This();

sparse: []StateId,
dense: []StateId,
len: u32,

/// The size of SparseSet must fit into a u32, which is the underlying type of StateId,
/// otherwise SparseSet operations will panic.
pub fn init(gpa: Allocator, size: u32) !SparseSet {
    return .{
        .sparse = try gpa.alloc(StateId, size),
        .dense = try gpa.alloc(StateId, size),
        .len = 0,
    };
}

pub fn deinit(s: *SparseSet, gpa: Allocator) void {
    gpa.free(s.sparse);
    gpa.free(s.dense);
}

pub inline fn cap(s: *SparseSet) usize {
    return s.dense.len;
}

pub inline fn contains(s: *SparseSet, id: StateId) bool {
    const idx = s.sparse[id];
    return idx < s.len and s.dense[idx] == id;
}

pub inline fn add(s: *SparseSet, id: StateId) void {
    if (s.contains(id)) return; // StateId exists, no-op
    std.debug.assert(s.len < s.cap()); // add() dedups valid ids so s.len can never exceed s.cap()
    s.dense[s.len] = id;
    s.sparse[id] = s.len;
    s.len += 1;
}

pub inline fn clear(s: *SparseSet) void {
    s.len = 0;
}

pub inline fn slice(s: *SparseSet) []StateId {
    return s.dense[0..s.len];
}

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
