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
///
/// Because epsilon states are never added to the set, `dense_size` can take the count
/// of matcher states to save a little bit of heap memory.
pub fn init(gpa: Allocator, sparse_size: u32, dense_size: u32) !SparseSet {
    return .{
        .sparse = try gpa.alloc(StateId, sparse_size),
        .dense = try gpa.alloc(StateId, dense_size),
        .len = 0,
    };
}

pub fn deinit(s: *SparseSet, gpa: Allocator) void {
    gpa.free(s.sparse);
    gpa.free(s.dense);
}

pub fn cap(s: *SparseSet) usize {
    return s.dense.len;
}

pub fn contains(s: *SparseSet, id: StateId) bool {
    const idx = s.sparse[id];
    return idx < s.len and s.dense[idx] == id;
}

pub fn add(s: *SparseSet, id: StateId) bool {
    if (s.contains(id)) return false;
    std.debug.assert(s.len < s.cap()); // add() dedups valid ids so s.len can never exceed s.cap()
    s.dense[s.len] = id;
    s.sparse[id] = s.len;
    s.len += 1;
    return true;
}

pub fn clear(s: *SparseSet) void {
    s.len = 0;
}

pub fn slice(s: *SparseSet) []StateId {
    return s.dense[0..s.len];
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

test "SparseSet add/remove basics" {
    var set = try SparseSet.init(testing.allocator, 8, 8);
    defer set.deinit(testing.allocator);

    try expect(set.add(1));
    try expect(set.add(2));
    try expect(set.add(3));
    try expectEqual(3, set.slice().len);
    try expectEqual(1, set.slice()[0]);
    try expectEqual(2, set.slice()[1]);
    try expectEqual(3, set.slice()[2]);
}

test "SparseSet clear and dedupe" {
    var set = try SparseSet.init(testing.allocator, 4, 4);
    defer set.deinit(testing.allocator);

    try expect(set.add(0));
    try expect(set.add(1));
    try expect(!set.add(1));
    try expectEqual(2, set.slice().len);

    _ = set.clear();
    try expectEqual(0, set.slice().len);

    try expect(set.add(3));
    try expect(!set.add(3));
    try expectEqual(1, set.slice().len);
    try expectEqual(3, set.slice()[0]);
}
